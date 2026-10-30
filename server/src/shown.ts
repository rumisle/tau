// What a nested call did that the user sees. A tool a code mode script calls (docs/codemode.md) gives its result to the
// script, not the transcript, so the apps never read its details: send_file's files and a subagent's start would not
// show. Called so, such a tool records what it did as a display-only entry, one with data and no model messages, which
// changes nothing the model reads, even between a tool call and its result (durable's spec, "display-only"). The apps
// show it where it is: after the script's card, as soon as it happens. A model's own call needs none: its result says.
import type { ConversationId, TaskId, Tx } from "@earendil-works/pi-durable";
import { defineDoc, defineEntry } from "@earendil-works/pi-durable";
import type { SentFile } from "./send-file.ts";

/** send_file's files: as its result's `details.files`. */
export const FilesEntry = defineEntry<{ callId: string; files: SentFile[] }>("tau.files");

/** A subagent started, sent to, or stopped: the call's arguments and what came of them, as its result's details. */
export type SubagentShown = {
	callId: string;
	action: "spawn" | "send" | "stop";
	name: string;
	message?: string;
	conversationId: ConversationId;
	model?: string;
	thinking?: string;
	fork?: true;
	/** When it went out: a display entry has no message to carry a timestamp. */
	at: number;
};
export const SubagentEntry = defineEntry<SubagentShown>("tau.subagent");

/** A nested call's ID is `<caller's call ID>/<key>`. */
export function isNested(callId: string): boolean {
	return callId.includes("/");
}

/** The call the model made: a nested call's outermost caller. */
export function modelCallId(callId: string): string {
	return callId.split("/")[0]!;
}

/** Whether a replay-safe call's entry was appended already: a rerun after a crash appends none again. */
const Shown = defineDoc<{ shown?: true }>({ kind: "tau.shown", version: 1, scope: "task", initial: () => ({}), checkpointWhen: () => false });

/** Runs `append` once per task, in the caller's transaction. */
export async function appendShownOnce(tx: Tx, taskId: TaskId, append: () => Promise<unknown>): Promise<void> {
	const state = await tx.doc(Shown, taskId);
	if (state.shown === true) return;
	await append();
	state.shown = true;
}
