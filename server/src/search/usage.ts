// What the models cost, by day, model and conversation, for the app's Usage screen. Durable keeps each conversation's
// totals (`pi.usage`) but not when they were spent; this ledger keeps one row per answer, written with the search index
// (./service.ts) from the same commits, so it needs no pass of its own.
import type { DatabaseSync, StatementSync } from "node:sqlite";

export type UsageRow = {
	entryId: number;
	conversationId: number;
	time: number;
	/** `provider/modelId`. */
	model: string;
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
};

export type UsageTotals = { cost: number; input: number; output: number; cacheRead: number; cacheWrite: number; replies: number };

export type UsageReport = {
	/** Days from `since`, oldest first, in the client's time zone: each day's spend by model. */
	days: { day: string; models: Record<string, UsageTotals> }[];
	models: (UsageTotals & { model: string })[];
	conversations: (UsageTotals & { conversationId: number })[];
	total: UsageTotals & { conversations: number };
	/** The same span just before, for the change. */
	previous: UsageTotals;
};

const DAY = 86_400_000;

export class UsageLedger {
	readonly #db: DatabaseSync;
	readonly #insert: StatementSync;

	constructor(db: DatabaseSync) {
		this.#db = db;
		db.exec(`CREATE TABLE IF NOT EXISTS usage (
			entry INTEGER PRIMARY KEY, conv INTEGER NOT NULL, time INTEGER NOT NULL, model TEXT NOT NULL,
			input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost REAL NOT NULL)`);
		db.exec("CREATE INDEX IF NOT EXISTS usage_time ON usage (time)");
		this.#insert = db.prepare("INSERT OR IGNORE INTO usage (entry, conv, time, model, input, output, cache_read, cache_write, cost) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)");
	}

	/** Each answer once, however often it is offered. */
	add(rows: readonly UsageRow[]): void {
		if (rows.length === 0) return;
		this.#db.exec("BEGIN");
		try {
			for (const row of rows) this.#insert.run(row.entryId, row.conversationId, row.time, row.model, row.input, row.output, row.cacheRead, row.cacheWrite, row.cost);
			this.#db.exec("COMMIT");
		} catch (error) {
			this.#db.exec("ROLLBACK");
			throw error;
		}
	}

	/**
	 * The last `days` days up to now (0: all), days cut at the client's midnight: `tzOffset` is its minutes east of
	 * UTC, as JavaScript's `-getTimezoneOffset()`.
	 */
	report(days: number, tzOffset: number, now = Date.now()): UsageReport {
		const shift = tzOffset * 60_000;
		const today = Math.floor((now + shift) / DAY);
		const first = days > 0 ? today - days + 1 : Math.floor((((this.#db.prepare("SELECT min(time) AS t FROM usage").get() as { t: number | null }).t ?? now) + shift) / DAY);
		const since = first * DAY - shift;
		const span = (today - first + 1) * DAY;
		const sums = "sum(cost) AS cost, sum(input) AS input, sum(output) AS output, sum(cache_read) AS cacheRead, sum(cache_write) AS cacheWrite, count(*) AS replies";
		const byDay = this.#db
			.prepare(`SELECT CAST((time + ?) / ${DAY} AS INTEGER) AS day, model, ${sums} FROM usage WHERE time >= ? GROUP BY day, model`)
			.all(shift, since) as ({ day: number; model: string } & UsageTotals)[];
		const daysOut: UsageReport["days"] = [];
		for (let day = first; day <= today; day++) daysOut.push({ day: new Date(day * DAY).toISOString().slice(0, 10), models: {} });
		for (const row of byDay) {
			const slot = daysOut[row.day - first];
			if (slot !== undefined) slot.models[row.model] = totals(row);
		}
		const models = (this.#db.prepare(`SELECT model, ${sums} FROM usage WHERE time >= ? GROUP BY model ORDER BY cost DESC`).all(since) as ({ model: string } & UsageTotals)[]).map(
			(row) => ({ model: row.model, ...totals(row) }),
		);
		const conversations = (
			this.#db.prepare(`SELECT conv AS conversationId, ${sums} FROM usage WHERE time >= ? GROUP BY conv ORDER BY cost DESC LIMIT 20`).all(since) as ({
				conversationId: number;
			} & UsageTotals)[]
		).map((row) => ({ conversationId: row.conversationId, ...totals(row) }));
		const all = this.#db.prepare(`SELECT ${sums}, count(DISTINCT conv) AS conversations FROM usage WHERE time >= ?`).get(since) as UsageTotals & { conversations: number };
		const previous = this.#db.prepare(`SELECT ${sums} FROM usage WHERE time >= ? AND time < ?`).get(since - span, since) as UsageTotals;
		return { days: daysOut, models, conversations, total: { ...totals(all), conversations: all.conversations ?? 0 }, previous: totals(previous) };
	}
}

function totals(row: Partial<UsageTotals>): UsageTotals {
	return { cost: row.cost ?? 0, input: row.input ?? 0, output: row.output ?? 0, cacheRead: row.cacheRead ?? 0, cacheWrite: row.cacheWrite ?? 0, replies: row.replies ?? 0 };
}
