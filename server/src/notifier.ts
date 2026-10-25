// Pushes (docs/notifications.md, docs/live-activity.md): while no app is in the foreground to see for itself, the
// server tells the user's phones what happened. A run that ends with an answer is a notification, through Apple's push
// service to each registered device; a chat the user waits on in a Live Activity
// changes that activity, through its own push token, and its finish is the activity's alert instead of a notification,
// so the phone does not ring twice.
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { type ConversationId, type EntryRecord, LiveDoc } from "@earendil-works/pi-durable";
import { type Apns, type ApnsPush, type ApnsResult, activityDate, isGone } from "./apns.ts";
import { type ActivityRecord, type ActivityRow, type DeviceRecord, DevicesDoc, VISIBLE_ROWS } from "./devices.ts";
import { type Host, MetaDoc } from "./host.ts";
import { withoutQuotes } from "./quotes.ts";

/** What sends to Apple: the APNs client, or a stand-in in tests. */
export type PushSender = Pick<Apns, "send">;

/** Done rows stay this long after the last chat finished, then the activity goes (as the app's doneLifetime). */
const DONE_LIFETIME_MS = 30 * 60_000;

function textOf(message: AssistantMessage | undefined): string {
	return (message?.content ?? []).flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

function firstLine(text: string): string {
	const line = text.split("\n").find((each) => each.trim() !== "") ?? text;
	const plain = line.replace(/[*_`#>]+/g, "").trim();
	return plain.length > 120 ? `${plain.slice(0, 119)}…` : plain;
}

function workedText(ms: number): string {
	const minutes = Math.floor(ms / 60_000);
	if (minutes < 1) return "under a minute";
	if (minutes < 60) return `${minutes} min`;
	return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

/** The activity as ActivityKit decodes TauActivityAttributes.ContentState. */
export function contentState(record: ActivityRecord, serverId: string, now: number): Record<string, unknown> {
	const rows = [...record.rows].sort((a, b) => b.watchedAt - a.watchedAt);
	return {
		chats: rows.slice(0, VISIBLE_ROWS).map((row) => ({
			id: row.appId,
			serverId,
			localId: row.conversationId,
			title: row.title,
			state: row.state,
			since: activityDate(row.since),
			...(row.finishedAt === undefined ? {} : { finishedAt: activityDate(row.finishedAt) }),
			minutes: Math.max(0, Math.floor(((row.finishedAt ?? now) - row.since) / 60_000)),
			...(row.detail === undefined ? {} : { detail: row.detail }),
		})),
		more: Math.max(0, rows.length - VISIBLE_ROWS),
		...(record.accent === undefined ? {} : { accent: record.accent }),
	};
}

export class Notifier {
	readonly #host: Host;
	readonly #apns: PushSender | undefined;
	readonly #unsubscribe: () => void;
	/** Connections whose app is in the foreground: they show banners, so nothing is pushed. */
	#activeClients = 0;
	#closed = false;
	/** Whether each conversation's run goes, as last seen, and the subagents of each. */
	readonly #busy = new Map<ConversationId, boolean>();
	readonly #children = new Map<ConversationId, Set<ConversationId>>();
	readonly #parents = new Map<ConversationId, ConversationId | null>();
	/** Changes of `tau.devices`, in order. */
	#writes: Promise<void> = Promise.resolve();
	/** Finishes a device's activity said, with its alert (`deviceId:conversation` to when): no notification for them. */
	readonly #activityAlerts = new Map<string, number>();
	/** Activities whose chats are all done: each ends when its last row would have in the app. */
	readonly #endTimers = new Map<string, ReturnType<typeof setTimeout>>();
	/** For tests: what went to Apple. */
	readonly pushed: { deviceId: string; push: ApnsPush; result?: ApnsResult }[] = [];

	readonly #doneLifetime: number;

	constructor(host: Host, options: { apns?: PushSender; doneLifetimeMs?: number } = {}) {
		this.#host = host;
		this.#apns = options.apns;
		this.#doneLifetime = options.doneLifetimeMs ?? DONE_LIFETIME_MS;
		this.#unsubscribe = host.harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type === "entry" && change.value.kind === "pi.assistant") {
					const message = change.value.model?.[0] as AssistantMessage | undefined;
					// The end of a run: a final answer, or one that failed. A tool round goes on.
					if (message === undefined || message.stopReason === "toolUse") continue;
					const entry = change.value;
					// Commit listeners must not call Session APIs.
					setTimeout(() => {
						if (this.#closed) return;
						this.#answered(entry, message).catch((error) => console.error("[tau] push failed:", error));
					}, 0);
				} else if (change.type === "document" && change.conversationId !== undefined && change.record.kind === LiveDoc.definition.kind) {
					const id = change.conversationId;
					const busy = change.value !== null && (change.value as { run?: unknown }).run !== undefined;
					if (this.#busy.get(id) === busy) continue;
					this.#busy.set(id, busy);
					setTimeout(() => {
						if (this.#closed) return;
						this.#runChanged(id).catch((error) => console.error("[tau] live activity push failed:", error));
					}, 0);
				}
			}
		});
	}

	/** A connection's app came to the foreground (+1) or left it (-1). */
	presence(delta: number): void {
		this.#activeClients = Math.max(0, this.#activeClients + delta);
	}

	/** Whether it has the APNs key to send Apple's pushes. */
	get canPush(): boolean {
		return this.#apns !== undefined;
	}

	get activeClients(): number {
		return this.#activeClients;
	}

	close(): void {
		this.#closed = true;
		this.#unsubscribe();
		for (const timer of this.#endTimers.values()) clearTimeout(timer);
		this.#endTimers.clear();
	}

	// MARK: - Devices

	/** A phone's registration: its device token, whether it wants answers, its push-to-start token. */
	async register(
		deviceId: string,
		update: { environment: DeviceRecord["environment"]; topic: string; alerts?: boolean; token?: string | null; pushToStart?: string | null },
	): Promise<void> {
		await this.#change((devices) => {
			const current = devices[deviceId];
			const next: DeviceRecord = { alerts: true, ...current, environment: update.environment, topic: update.topic, at: Date.now() };
			if (update.alerts !== undefined) next.alerts = update.alerts;
			// Given: set, or with null cleared; not given: as it was.
			for (const key of ["token", "pushToStart"] as const) {
				const value = update[key];
				if (value === null || value === "") delete next[key];
				else if (value !== undefined) next[key] = value;
			}
			devices[deviceId] = next;
			console.log(`[tau] device ${deviceId.slice(0, 8)}: ${next.token === undefined ? "no token" : "token"}, ${next.alerts ? "answers" : "no answers"}, ${next.pushToStart === undefined ? "no push-to-start" : "push-to-start"} (${next.environment})`);
			// Another device's old registration of the same token (a reinstall makes a new device ID): only one gets it.
			for (const [other, record] of Object.entries(devices)) if (other !== deviceId && record.token !== undefined && record.token === next.token) delete devices[other];
		});
	}

	async unregister(deviceId: string): Promise<void> {
		await this.#change((devices) => {
			delete devices[deviceId];
		});
	}

	/** The app's activity for this server's chats as it shows it; null: it ended. */
	async updateActivity(deviceId: string, activity: Omit<ActivityRecord, "pushedAt"> | null): Promise<void> {
		await this.#change((devices) => {
			const device = devices[deviceId];
			if (device === undefined) return;
			if (activity === null) delete device.activity;
			else device.activity = { ...activity, ...(device.activity?.pushedAt === undefined ? {} : { pushedAt: device.activity.pushedAt }) };
		});
	}

	/**
	 * The app, away, sent a message (a notification's reply) and cannot start an activity itself: the server updates
	 * the one it has, or starts one with the device's push-to-start token.
	 */
	async startActivity(deviceId: string, rows: ActivityRow[], accent: number | undefined): Promise<"updated" | "started" | "none"> {
		const devices = (await this.#host.harness.snapshot(DevicesDoc, BACKGROUND_CONTEXT))?.devices ?? {};
		const device = devices[deviceId];
		if (device === undefined || this.#apns === undefined) return "none";
		const now = Date.now();
		if (device.activity?.token !== undefined) {
			const record: ActivityRecord = { ...device.activity, rows, ...(accent === undefined ? {} : { accent }) };
			await this.#pushActivity(deviceId, device, record, "update", now);
			return "updated";
		}
		if (device.pushToStart === undefined || rows.length === 0) return "none";
		const record: ActivityRecord = { rows, ...(accent === undefined ? {} : { accent }) };
		const first = [...rows].sort((a, b) => b.watchedAt - a.watchedAt)[0]!;
		const timestamp = Math.floor(now / 1000);
		const result = await this.#send(deviceId, { token: device.pushToStart, environment: device.environment }, {
			type: "liveactivity",
			topic: `${device.topic}.push-type.liveactivity`,
			priority: 10,
			payload: {
				aps: {
					timestamp,
					event: "start",
					"content-state": contentState(record, this.#host.serverId, now),
					"attributes-type": "TauActivityAttributes",
					attributes: { serverId: this.#host.serverId },
					alert: { title: first.title, body: "Working" },
				},
			},
		});
		if (isGone(result)) {
			await this.#change((all) => {
				if (all[deviceId] !== undefined) delete all[deviceId].pushToStart;
			});
			return "none";
		}
		await this.#change((all) => {
			if (all[deviceId] !== undefined) all[deviceId].activity = { ...record, pushedAt: timestamp };
		});
		return result.status === 200 ? "started" : "none";
	}

	// MARK: - Answers

	async #answered(entry: EntryRecord, message: AssistantMessage): Promise<void> {
		const context = BACKGROUND_CONTEXT;
		const { harness, storage } = this.#host;
		if (this.#activeClients > 0) return;
		const id = entry.conversationId;
		// A subagent's answer goes to the conversation that started it, which reports it in its own answer.
		const record = await storage.conversation(id, context);
		if (record === undefined || record.owner !== undefined) return;
		const meta = await harness.snapshot(MetaDoc, id, context);
		const title = meta?.title ?? "tau";
		const failed = message.stopReason === "error" || message.stopReason === "aborted";
		const text = failed ? `Failed: ${message.errorMessage ?? "the model stopped"}` : textOf(message);
		const body = withoutQuotes(text).replace(/\s+/g, " ").trim().slice(0, 400) || "Answered.";
		// The chat's link, as the app copies one (docs/links.md): the server by the start of its ID.
		const url = `tau://${this.#host.serverId.slice(0, 8).toLowerCase()}/${id}`;
		if (this.#apns === undefined) return;
		const devices = (await harness.snapshot(DevicesDoc, context))?.devices ?? {};
		// A chat in a device's activity with nothing more to wait for: the activity's update says it, with its alert,
		// before this or after.
		const finishes = !this.#workingChildren(id).length;
		const now = Date.now();
		await Promise.all(
			Object.entries(devices).map(async ([deviceId, device]) => {
				if (!device.alerts || device.token === undefined) return;
				if (now - (this.#activityAlerts.get(`${deviceId}:${id}`) ?? 0) < 60_000) return;
				if (finishes && device.activity?.token !== undefined && device.activity.rows.some((row) => row.conversationId === id && row.state === "working")) return;
				await this.#send(deviceId, { token: device.token, environment: device.environment }, {
					type: "alert",
					topic: device.topic,
					priority: 10,
					payload: {
						aps: {
							alert: { title, body },
							sound: "default",
							// One thread per chat; the app's notification service extension shows it as the chat's message.
							"thread-id": `${this.#host.serverId}:${id}`,
							"mutable-content": 1,
							category: "chat",
						},
						tau: { server: this.#host.serverId, id, url, title, failed },
					},
				});
			}),
		);
	}

	// MARK: - Live Activities

	/** The subagents of a conversation that work now. */
	#workingChildren(id: ConversationId): ConversationId[] {
		return [...(this.#children.get(id) ?? [])].filter((child) => this.#busy.get(child) === true);
	}

	async #parent(id: ConversationId): Promise<ConversationId | undefined> {
		if (!this.#parents.has(id)) {
			const record = await this.#host.storage.conversation(id, BACKGROUND_CONTEXT);
			const parent = (record?.owner as { conversationId?: ConversationId } | undefined)?.conversationId ?? null;
			this.#parents.set(id, parent);
			if (parent !== null) {
				const children = this.#children.get(parent) ?? new Set();
				children.add(id);
				this.#children.set(parent, children);
			}
		}
		return this.#parents.get(id) ?? undefined;
	}

	/** A run started or ended in `id`: the rows of the chat it belongs to, in each device's activity, may change. */
	async #runChanged(id: ConversationId): Promise<void> {
		const parent = await this.#parent(id);
		const chat = parent ?? id;
		if (this.#activeClients > 0 || this.#apns === undefined) return;
		const devices = (await this.#host.harness.snapshot(DevicesDoc, BACKGROUND_CONTEXT))?.devices ?? {};
		const now = Date.now();
		const working = this.#busy.get(chat) === true || this.#workingChildren(chat).length > 0;
		const children = this.#workingChildren(chat).length;
		let last: { failed: boolean; text: string } | undefined;
		for (const [deviceId, device] of Object.entries(devices)) {
			const record = device.activity;
			if (record?.token === undefined) continue;
			const rows = record.rows.map((row) => ({ ...row }));
			const row = rows.find((each) => each.conversationId === chat);
			if (row === undefined) continue;
			let finished: ActivityRow | undefined;
			if (working) {
				const detail = children > 0 ? `${children} subagent${children === 1 ? "" : "s"} working` : "Working";
				if (row.state === "working" && row.detail === detail) continue;
				row.state = "working";
				delete row.finishedAt;
				row.detail = detail;
			} else {
				if (row.state !== "working") continue;
				last ??= await this.#lastAnswer(chat);
				row.state = last?.failed === true ? "failed" : "done";
				row.finishedAt = now;
				const detail = last === undefined ? undefined : firstLine(last.text);
				if (detail === undefined || detail === "") delete row.detail;
				else row.detail = detail;
				finished = row;
			}
			const next: ActivityRecord = { ...record, rows };
			if (finished !== undefined) this.#activityAlerts.set(`${deviceId}:${chat}`, now);
			const pushedAt = await this.#pushActivity(deviceId, device, next, "update", now, finished);
			// Nothing left working: the activity goes when the last done row would have in the app.
			if (pushedAt !== undefined && !rows.some((each) => each.state === "working")) this.#scheduleEnd(deviceId, record.token, now + this.#doneLifetime);
		}
	}

	/** Ends a device's activity at `at`, unless it changed by then: a chat working again, or another activity. */
	#scheduleEnd(deviceId: string, token: string, at: number): void {
		clearTimeout(this.#endTimers.get(deviceId));
		const timer = setTimeout(() => {
			this.#endTimers.delete(deviceId);
			void (async () => {
				const device = (await this.#host.harness.snapshot(DevicesDoc, BACKGROUND_CONTEXT))?.devices[deviceId];
				const record = device?.activity;
				if (device === undefined || record?.token !== token || record.rows.some((row) => row.state === "working")) return;
				await this.#pushActivity(deviceId, device, record, "end", Date.now());
			})().catch((error) => console.error("[tau] live activity end failed:", error));
		}, Math.max(0, at - Date.now()));
		timer.unref?.();
		this.#endTimers.set(deviceId, timer);
	}

	async #lastAnswer(id: ConversationId): Promise<{ failed: boolean; text: string } | undefined> {
		const handle = await this.#host.harness.conversation(id, BACKGROUND_CONTEXT);
		const page = await handle?.entries({}, 16, undefined, BACKGROUND_CONTEXT);
		const entry = page?.items.find((each) => each.kind === "pi.assistant");
		const message = entry?.model?.[0] as AssistantMessage | undefined;
		if (message === undefined) return undefined;
		const failed = message.stopReason === "error" || message.stopReason === "aborted";
		return { failed, text: failed ? (message.errorMessage ?? "The model stopped") : textOf(message) };
	}

	/** Pushes the activity's rows; the push's timestamp, unless it could not go. */
	async #pushActivity(deviceId: string, device: DeviceRecord, record: ActivityRecord, event: "update" | "end", now: number, finished?: ActivityRow): Promise<number | undefined> {
		const token = record.token;
		if (token === undefined) return undefined;
		// Later than the last push, which ActivityKit keeps, even within one second.
		const timestamp = Math.max(Math.floor(now / 1000), (record.pushedAt ?? 0) + 1);
		const ended = event === "end";
		const alert =
			finished === undefined
				? undefined
				: {
						title: finished.title,
						body: `${finished.state === "failed" ? "Failed" : "Done"} · worked ${workedText((finished.finishedAt ?? now) - finished.since)}${finished.detail === undefined ? "" : ` · ${finished.detail}`}`,
						sound: "default",
					};
		const result = await this.#send(deviceId, { token, environment: device.environment }, {
			type: "liveactivity",
			topic: `${device.topic}.push-type.liveactivity`,
			// A finish at once; a step when it suits the phone, which its budget then allows more of.
			priority: finished !== undefined ? 10 : 5,
			payload: {
				aps: {
					timestamp,
					event,
					"content-state": contentState(record, this.#host.serverId, now),
					...(alert === undefined ? {} : { alert }),
					// Its done rows have stayed their time already: gone at once.
					...(ended ? { "dismissal-date": Math.floor(now / 1000) } : {}),
				},
			},
		});
		await this.#change((devices) => {
			const current = devices[deviceId];
			if (current?.activity?.token !== token) return;
			if (isGone(result) || ended) delete current.activity;
			else current.activity = { ...record, pushedAt: timestamp };
		});
		return result.status === 200 ? timestamp : undefined;
	}

	async #send(deviceId: string, device: { token: string; environment: DeviceRecord["environment"] }, push: ApnsPush): Promise<ApnsResult> {
		const entry: (typeof this.pushed)[number] = { deviceId, push };
		this.pushed.push(entry);
		let result: ApnsResult;
		try {
			result = await this.#apns!.send(device, push);
		} catch (error) {
			console.error("[tau] APNs request failed:", error);
			return { status: 0, reason: String(error) };
		}
		entry.result = result;
		if (result.status !== 200) console.error(`[tau] APNs ${push.type} push to ${deviceId.slice(0, 8)} refused: ${result.status} ${result.reason ?? ""}`);
		else console.log(`[tau] APNs ${push.type} push to ${deviceId.slice(0, 8)}`);
		if (isGone(result) && push.type === "alert") {
			await this.#change((devices) => {
				if (devices[deviceId]?.token === device.token) delete devices[deviceId]!.token;
			});
		}
		return result;
	}

	/** Changes `tau.devices`, one change at a time. */
	#change(update: (devices: Record<string, DeviceRecord>) => void): Promise<void> {
		const next = this.#writes.then(() =>
			this.#host.harness.commit(async (tx) => {
				update((await tx.doc(DevicesDoc)).devices);
				return undefined;
			}, BACKGROUND_CONTEXT),
		);
		this.#writes = next.then(
			() => undefined,
			() => undefined,
		);
		return next;
	}
}
