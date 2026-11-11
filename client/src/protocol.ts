// The wire types a client reads (docs/protocol.md). The server's own, with its request validation, are in
// server/src/protocol.ts.

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export type EntryId = number;

/** An immutable record of a conversation; `kind` names its shape (`pi.user`, `pi.assistant`, `pi.tool-result`, ...). */
export type Entry = { id: EntryId; kind: string; conversationId: number; head?: number; [key: string]: unknown };

export type Op =
	| ["r", Json]
	| ["s", (string | number)[], Json]
	| ["d", (string | number)[]]
	| ["a", (string | number)[], string]
	| ["t", (string | number)[], number]
	| ["p", (string | number)[], number, number, Json[]]
	| ["m", (string | number)[], number[]];

/** A frame the server sends without a request: `conv.commit`, `dialog`, `submission`. */
export type Push = { event: string; [key: string]: unknown };

export type EntrySummary = { id: EntryId; kind: string; role?: string; text: string; timestamp?: number };

export type ConversationRecord = {
	id: number;
	parent?: { conversationId: number; at: EntryId };
	owner?: { conversationId: number; taskId: number };
};

export type Dialog = {
	conversation: ConversationRecord;
	title?: string;
	createdAt?: number;
	last?: EntrySummary;
	agent: { model?: { provider: string; modelId: string } };
	busy: boolean;
	read?: EntryId;
	unreadCount: number;
	markedUnread?: true;
	archived?: true;
	hidden?: true;
	pinned?: number;
	cache?: JsonObject;
};

export type SubscribeResult = {
	conversation: ConversationRecord;
	docs: JsonObject;
	entries: Entry[];
	head?: EntryId;
	hasOlder: boolean;
	gap?: { after: EntryId; before: EntryId };
	submissions: JsonObject[];
};

export type HistoryResult = { entries: Entry[]; hasOlder: boolean };

export type DialogsResult = { dialogs: Dialog[]; version: string; full: boolean };
