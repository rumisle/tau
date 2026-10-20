// Wire types of docs/protocol.md.
import type { JsonValue } from "@earendil-works/chord";
import type { ConversationRecord, EntryId } from "@earendil-works/pi-durable";

export const PROTOCOL_VERSION = 1;

export type Request = { id: number | string; method: string; params?: Record<string, unknown> };

export type ErrorCode = "bad_request" | "not_found" | "busy" | "unauthorized" | "internal";

export class ProtocolError extends Error {
	readonly code: ErrorCode;
	constructor(code: ErrorCode, message: string) {
		super(message);
		this.name = "ProtocolError";
		this.code = code;
	}
}

export type EntrySummary = { id: EntryId; kind: string; role?: string; text: string; timestamp?: number };

export type Dialog = {
	conversation: ConversationRecord;
	title?: string;
	createdAt?: number;
	last?: EntrySummary;
	/** Effective model and working directory. */
	agent: { model?: { provider: string; modelId: string }; cwd: string };
	busy: boolean;
	/** The last entry the user has seen. */
	read?: EntryId;
	/** Assistant messages after `read`, up to 99. */
	unreadCount: number;
	markedUnread?: true;
	archived?: true;
};

export type AgentPatch = {
	model?: { provider: string; modelId: string } | null;
	thinkingLevel?: string | null;
	instructions?: string | null;
	cwd?: string | null;
};

// Param readers: throw bad_request on malformed input.

export function int(params: Record<string, unknown>, key: string): number;
export function int(params: Record<string, unknown>, key: string, optional: true): number | undefined;
export function int(params: Record<string, unknown>, key: string, optional?: true): number | undefined {
	const value = params[key];
	if (value === undefined && optional) return undefined;
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
		throw new ProtocolError("bad_request", `${key} must be a non-negative integer`);
	}
	return value;
}

export function str(params: Record<string, unknown>, key: string): string;
export function str(params: Record<string, unknown>, key: string, optional: true): string | undefined;
export function str(params: Record<string, unknown>, key: string, optional?: true): string | undefined {
	const value = params[key];
	if (value === undefined && optional) return undefined;
	if (typeof value !== "string") throw new ProtocolError("bad_request", `${key} must be a string`);
	return value;
}

export function obj(params: Record<string, unknown>, key: string): Record<string, unknown> | undefined {
	const value = params[key];
	if (value === undefined) return undefined;
	if (typeof value !== "object" || value === null || Array.isArray(value)) {
		throw new ProtocolError("bad_request", `${key} must be an object`);
	}
	return value as Record<string, unknown>;
}

export function limit(params: Record<string, unknown>, fallback = 50): number {
	return Math.max(1, Math.min(500, int(params, "limit", true) ?? fallback));
}

export type Json = JsonValue;
