// The `subagent` tool: the model hands a self-contained task to a child conversation and gets its answer back.
// From durable's test/examples/22-subagent-foreground.ts. The child is owned by the tool call, so aborting the call
// aborts it; its ID goes out in the call's details, which the app shows as a link into the child's own transcript.
import type { Context } from "@earendil-works/chord";
import { type AssistantMessage, Type } from "@earendil-works/pi-ai";
import {
	AssistantEntry,
	configure,
	defineExtension,
	defineTool,
	type EntryId,
	type Extension,
	type ToolExecutionApi,
} from "@earendil-works/pi-durable";

async function answerText(api: ToolExecutionApi, answer: EntryId, context: Context): Promise<string> {
	const entry = await api.commit((tx) => tx.entry(AssistantEntry, answer), context);
	const message = entry?.model?.[0] as AssistantMessage | undefined;
	return message?.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("") ?? "";
}

export const Subagent: Extension = defineExtension({
	name: "subagent",
	tools: [
		defineTool({
			name: "subagent",
			description:
				"Delegate a self-contained task to a subagent with the same tools and working directory, and get its final answer back. Use it for independent investigations that would otherwise fill this conversation with tool output. Several calls in one turn run in parallel.",
			parameters: Type.Object({ task: Type.String({ description: "What the subagent should do and report back" }) }),
			// A rerun after a crash finds the child it created and the submission it made.
			replay: "safe",
			execute: async (args, api, context) => {
				const child = await api.commit(async (tx) => {
					const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
					if (existing !== undefined) return existing.id;
					// A copy of this conversation's agent, without subagents of its own.
					const created = await tx.createConversation({ ownership: { kind: "task", taskId: api.taskId } });
					await configure(tx, created.id, { extensions: { remove: [Subagent] } });
					return created.id;
				}, context);
				await api.details({ conversationId: child }, context);
				const handle = (await api.conversation(child, context))!;
				const request = { type: "input", content: args.task, requestId: `subagent:${api.taskId}` } as const;
				const settled = await (await handle.submit(request, context)).wait(context);
				if (settled.status !== "done" || settled.type !== "input") throw new Error(`Subagent ended: ${settled.status}`);
				const text = await answerText(api, settled.answer, context);
				return { output: [{ type: "text", text }], details: { conversationId: child } };
			},
		}),
	],
});
