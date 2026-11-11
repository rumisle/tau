// The chat list by version (docs/protocol.md `dialogs.subscribe`, docs/network.md "The chat list by version"): the
// newest version applied is kept with the list, and the next connection asks only for what changed since.
import type { TauClient } from "./connection.ts";
import type { Dialog, DialogsResult, Push } from "./protocol.ts";

export class DialogList {
	readonly dialogs = new Map<number, Dialog>();
	version: string | undefined;
	#stop: (() => void) | undefined;
	readonly #changed = new Set<(changed: Dialog[]) => void>();

	/** A list restored from a cache: its dialogs and the version they are as of. */
	static restore(dialogs: Dialog[], version: string | undefined): DialogList {
		const list = new DialogList();
		for (const dialog of dialogs) list.dialogs.set(dialog.conversation.id, dialog);
		list.version = version;
		return list;
	}

	/** Subscribes on `client`: only the changes since `version` come, unless the server restarted (`full`). */
	async sync(client: TauClient): Promise<void> {
		this.#stop?.();
		const buffered: Push[] = [];
		let ready = false;
		this.#stop = client.on((push) => {
			if (push.event !== "dialog") return;
			if (ready) this.#apply([push.dialog as Dialog], push.version as string);
			else buffered.push(push);
		});
		const result = await client.request<DialogsResult>("dialogs.subscribe", this.version === undefined ? {} : { since: this.version });
		if (result.full) this.dialogs.clear();
		this.#apply(result.dialogs, result.version);
		ready = true;
		for (const push of buffered) this.#apply([push.dialog as Dialog], push.version as string);
	}

	/** Dialogs newest first, as the chat list sorts them (by their last entry). */
	ordered(): Dialog[] {
		return [...this.dialogs.values()].sort((a, b) => (b.last?.id ?? 0) - (a.last?.id ?? 0));
	}

	onChange(listener: (changed: Dialog[]) => void): () => void {
		this.#changed.add(listener);
		return () => this.#changed.delete(listener);
	}

	detach(): void {
		this.#stop?.();
		this.#stop = undefined;
	}

	#apply(dialogs: Dialog[], version: string): void {
		for (const dialog of dialogs) this.dialogs.set(dialog.conversation.id, dialog);
		this.version = version;
		for (const listener of this.#changed) listener(dialogs);
	}
}
