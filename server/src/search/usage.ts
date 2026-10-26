// What the models cost, by day, model and conversation, for the app's Usage screen. Durable keeps each conversation's
// totals (`pi.usage`) but not when they were spent; this ledger keeps one row per answer, written with the search index
// (./service.ts) from the same commits, so it needs no pass of its own. Prompt cache refreshes (../cache.ts) are no
// answers: they have a table of their own, and count as the model `tau/cache-warming`. Compactions that follow the
// cached context (../compaction.ts) count as `tau/compaction`.
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

/** The model the Usage screen shows cache refreshes as. */
export const CACHE_WARMING_MODEL = "tau/cache-warming";

/** The model the Usage screen shows compaction summaries as. */
export const COMPACTION_MODEL = "tau/compaction";

export type WarmRow = { conversationId: number; time: number; input: number; output: number; cacheRead: number; cacheWrite: number; cost: number };

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
	readonly #insertWarm: StatementSync;
	readonly #insertCompaction: StatementSync;

	constructor(db: DatabaseSync) {
		this.#db = db;
		db.exec(`CREATE TABLE IF NOT EXISTS usage (
			entry INTEGER PRIMARY KEY, conv INTEGER NOT NULL, time INTEGER NOT NULL, model TEXT NOT NULL,
			input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost REAL NOT NULL)`);
		db.exec("CREATE INDEX IF NOT EXISTS usage_time ON usage (time)");
		db.exec(`CREATE TABLE IF NOT EXISTS warm (
			conv INTEGER NOT NULL, time INTEGER NOT NULL,
			input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost REAL NOT NULL)`);
		db.exec(`CREATE TABLE IF NOT EXISTS compaction (
			conv INTEGER NOT NULL, time INTEGER NOT NULL,
			input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost REAL NOT NULL)`);
		// A report sums a span of time at a time, from each table's time index.
		db.exec("CREATE INDEX IF NOT EXISTS warm_time ON warm (time)");
		db.exec("CREATE INDEX IF NOT EXISTS compaction_time ON compaction (time)");
		// Answers, refreshes and compactions as one; \`answer\` tells them apart. Made again at each start, so an older
		// database gets the tables added since.
		db.exec("DROP VIEW IF EXISTS spend");
		db.exec(`CREATE VIEW spend AS
			SELECT conv, time, model, input, output, cache_read, cache_write, cost, 1 AS answer FROM usage
			UNION ALL SELECT conv, time, '${CACHE_WARMING_MODEL}', input, output, cache_read, cache_write, cost, 0 FROM warm
			UNION ALL SELECT conv, time, '${COMPACTION_MODEL}', input, output, cache_read, cache_write, cost, 0 FROM compaction`);
		this.#insertCompaction = db.prepare("INSERT INTO compaction (conv, time, input, output, cache_read, cache_write, cost) VALUES (?, ?, ?, ?, ?, ?, ?)");
		this.#insertWarm = db.prepare("INSERT INTO warm (conv, time, input, output, cache_read, cache_write, cost) VALUES (?, ?, ?, ?, ?, ?, ?)");
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

	addWarm(row: WarmRow): void {
		this.#insertWarm.run(row.conversationId, row.time, row.input, row.output, row.cacheRead, row.cacheWrite, row.cost);
	}

	addCompaction(row: WarmRow): void {
		this.#insertCompaction.run(row.conversationId, row.time, row.input, row.output, row.cacheRead, row.cacheWrite, row.cost);
	}

	/**
	 * The last `days` days up to now (0: all), days cut at the client's midnight: `tzOffset` is its minutes east of
	 * UTC, as JavaScript's `-getTimezoneOffset()`. Summed a span of answers at a time, letting requests in between: all
	 * of a long history is hundreds of thousands of rows, too many to sum in one go on the server's only thread.
	 */
	async report(days: number, tzOffset: number, now = Date.now()): Promise<UsageReport> {
		const shift = tzOffset * 60_000;
		const today = Math.floor((now + shift) / DAY);
		const first = days > 0 ? today - days + 1 : Math.floor(((this.#earliest() ?? now) + shift) / DAY);
		const since = first * DAY - shift;
		const span = (today - first + 1) * DAY;
		const daysOut: UsageReport["days"] = [];
		for (let day = first; day <= today; day++) daysOut.push({ day: new Date(day * DAY).toISOString().slice(0, 10), models: {} });
		const models = new Map<string, UsageTotals>();
		const conversations = new Map<number, UsageTotals>();
		const total = zero();
		// By day, model and conversation; a model's replies count its rows (the refreshes' row counts the refreshes),
		// the others' only the answers.
		const grouped = this.#db.prepare(
			`SELECT CAST((time + ?) / ${DAY} AS INTEGER) AS day, model, conv, ${SUMS}, count(*) AS rows FROM spend WHERE time >= ? AND time < ? GROUP BY day, model, conv`,
		);
		for await (const [from, to] of this.#spans(since, Number.MAX_SAFE_INTEGER)) {
			for (const row of grouped.all(shift, from, to) as ({ day: number; model: string; conv: number; rows: number } & UsageTotals)[]) {
				const slot = daysOut[row.day - first];
				if (slot !== undefined) add((slot.models[row.model] ??= zero()), row, row.replies);
				add(models.get(row.model) ?? models.set(row.model, zero()).get(row.model)!, row, row.rows);
				add(conversations.get(row.conv) ?? conversations.set(row.conv, zero()).get(row.conv)!, row, row.replies);
				add(total, row, row.replies);
			}
		}
		const previous = zero();
		const summed = this.#db.prepare(`SELECT ${SUMS} FROM spend WHERE time >= ? AND time < ?`);
		for await (const [from, to] of this.#spans(since - span, since)) {
			const row = summed.get(from, to) as Partial<UsageTotals>;
			add(previous, row, row.replies ?? 0);
		}
		return {
			days: daysOut,
			// Costliest first; equal ones by name and ID, the same in every report.
			models: [...models].map(([model, totals]) => ({ model, ...totals })).sort((a, b) => b.cost - a.cost || (a.model < b.model ? -1 : a.model > b.model ? 1 : 0)),
			conversations: [...conversations]
				.map(([conversationId, totals]) => ({ conversationId, ...totals }))
				.sort((a, b) => b.cost - a.cost || a.conversationId - b.conversationId)
				.slice(0, 20),
			total: { ...total, conversations: conversations.size },
			previous,
		};
	}

	/** The time of the first spend, if any: each table's own, by its time index. */
	#earliest(): number | undefined {
		const times = ["usage", "warm", "compaction"].map((table) => (this.#db.prepare(`SELECT min(time) AS t FROM ${table}`).get() as { t: number | null }).t);
		const found = times.filter((time): time is number => time !== null);
		return found.length === 0 ? undefined : Math.min(...found);
	}

	/**
	 * [from, to) cut into spans of about SPAN_ROWS answers, each after the one before has been summed and requests have
	 * had their turn.
	 */
	async *#spans(from: number, to: number): AsyncGenerator<[number, number]> {
		const next = this.#db.prepare("SELECT time FROM usage WHERE time >= ? AND time < ? ORDER BY time LIMIT 1 OFFSET ?");
		let start = from;
		while (start < to) {
			const found = (next.get(start, to, SPAN_ROWS) as { time: number } | undefined)?.time;
			// Rows of one instant stay in one span.
			const end = found === undefined ? to : Math.max(found, start + 1);
			yield [start, end];
			start = end;
			if (start < to) await new Promise((resolve) => setImmediate(resolve));
		}
	}
}

/** Answers summed at a time by `report`. */
const SPAN_ROWS = 20_000;

const SUMS = "sum(cost) AS cost, sum(input) AS input, sum(output) AS output, sum(cache_read) AS cacheRead, sum(cache_write) AS cacheWrite, sum(answer) AS replies";

function zero(): UsageTotals {
	return { cost: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, replies: 0 };
}

/** Adds a row's sums, with `replies` as counted for the total it goes to. */
function add(to: UsageTotals, row: Partial<UsageTotals>, replies: number): void {
	to.cost += row.cost ?? 0;
	to.input += row.input ?? 0;
	to.output += row.output ?? 0;
	to.cacheRead += row.cacheRead ?? 0;
	to.cacheWrite += row.cacheWrite ?? 0;
	to.replies += replies;
}
