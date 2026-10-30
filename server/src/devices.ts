// The phones that get this server's pushes (docs/notifications.md, docs/live-activity.md): each app registers its APNs
// device token, and the Live Activity it shows for this server's chats with that activity's own push token, so that
// while the app is away the server can tell it what it cannot see: a chat finished.
import { defineDoc } from "@earendil-works/pi-durable";
import type { ApnsEnvironment } from "./apns.ts";

/** A row of a Live Activity: a chat of this server the user waits on (TauActivityAttributes.Chat in the app). */
export type ActivityRow = {
	/** The app's own ID for the chat, which its links use. */
	appId: number;
	conversationId: number;
	title: string;
	state: "working" | "done" | "failed";
	/** Epoch ms its run began, and ended. */
	since: number;
	finishedAt?: number;
	/** The step, the answer's first line, or the error. */
	detail?: string;
	/** When the user started waiting on it: the newest first. */
	watchedAt: number;
};

export type ActivityRecord = {
	/** ActivityKit's ID, and the token its updates go to (none yet while one started by a push gets its own). */
	id?: string;
	token?: string;
	rows: ActivityRow[];
	/** The app's accent as 0xRRGGBB. */
	accent?: number;
	/** When the server last pushed to it, in epoch seconds: ActivityKit drops a push older than the last one. */
	pushedAt?: number;
};

export type DeviceRecord = {
	/** The APNs device token, hex; none until the user allows notifications. */
	token?: string;
	environment: ApnsEnvironment;
	/** The app's bundle ID: the topic of its pushes. */
	topic: string;
	/** Answers as notifications (Settings > Notifications). */
	alerts: boolean;
	/** The token that starts a Live Activity, from iOS 17.2. */
	pushToStart?: string;
	/** The app's key for what an answer's push says (src/seal.ts): 32 bytes, base64. */
	pushKey?: string;
	activity?: ActivityRecord;
	/** Epoch ms of the last registration. */
	at: number;
};

export const DevicesDoc = defineDoc<{ devices: Record<string, DeviceRecord> }>({
	kind: "tau.devices",
	version: 1,
	scope: "session",
	initial: () => ({ devices: {} }),
	checkpointWhen: () => false,
});

/** More than this many rows, and the rest are a count ("+2 more"), as in the app. */
export const VISIBLE_ROWS = 3;
