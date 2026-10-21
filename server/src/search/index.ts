// Full-text search over every conversation, after rumisle/recall (MIT), indexed as entries are written.
//
// One SQLite file beside the database. Each searchable part of an entry (a prompt, an answer, reasoning) and each
// conversation's title is one document of a contentless FTS5 table, the text pre-tokenized (./tokenize.ts) so the index,
// the query and the highlighter agree. The rowid encodes the conversation and the kind, so a search groups and filters on
// the full-text table alone:  rowid = conversation * 2^25 + seq * 8 + kind,  seq 0 being the title. The text itself is
// not copied: excerpts are read from the entries, for the few hits shown.
import { DatabaseSync, type StatementSync } from "node:sqlite";
import { type Compiled, compile, excerpt, ftsExpression, highlight, parseQuery, type Range, type Vocabulary } from "./match.ts";
import { tokenize } from "./tokenize.ts";

export const SCHEMA_VERSION = 2;

export const Kind = { user: 0, assistant: 1, reasoning: 2, title: 3 } as const;
export type KindName = keyof typeof Kind;
const KIND_NAMES: readonly KindName[] = ["user", "assistant", "reasoning", "title"];

const CONV_BITS = 25;
const CONV_SHIFT = 2 ** CONV_BITS;
const MAX_SEQ = 2 ** 22 - 1;
/** Text past this is not indexed: a part this long is a pasted file or a log. */
const MAX_PART = 100_000;

export const conversationOf = (rowid: number): number => Math.floor(rowid / CONV_SHIFT);
export const kindOf = (rowid: number): number => rowid % 8;
const range = (conversation: number): [number, number] => [conversation * CONV_SHIFT, (conversation + 1) * CONV_SHIFT - 1];

export type IndexPart = { kind: number; text: string; idx: number };
export type IndexEntry = { conversationId: number; entryId: number; time: number; parts: IndexPart[] };

export type ConversationInfo = {
	/** Fork source and the last entry it shares. */
	parent?: { conversationId: number; at: number };
};

/** A part's text, for excerpts: read from the entries, which the index does not copy. */
export type TextLoader = (conversationId: number, entryId: number, idx: number) => Promise<string | undefined>;

export type SearchHit = {
	kind: KindName;
	/** Absent for the title. */
	entryId?: number;
	time: number;
	/** Excerpt around the matches; `before` / `after` say whether text was cut there. */
	text: string;
	before: boolean;
	after: boolean;
	/** Highlights within `text`, [start, end) in UTF-16. */
	ranges: [number, number][];
};

export type SearchResult = {
	conversationId: number;
	score: number;
	/** Parts matching every term. */
	matches: number;
	/** The terms only match spread over several parts. */
	spread: boolean;
	hits: SearchHit[];
};

export type SearchOptions = {
	limit?: number;
	offset?: number;
	/** Hits per conversation. */
	hits?: number;
	/** Characters of context in a hit. */
	context?: number;
	kinds?: KindName[];
	/** The last word is still being typed: it matches as a prefix from two letters. */
	typing?: boolean;
	now?: number;
};

export type SearchResponse = {
	results: SearchResult[];
	/** Conversations matching in all. */
	total: number;
	/** The compiled terms, for highlighting elsewhere: tokens, the last one a prefix or not, and typo variants. */
	terms: { tokens: string[]; prefix: boolean; variants: string[] }[];
	ms: number;
};

type ConvRow = { id: number; counter: number; cursor: number; updated: number; parent: number | null; parent_at: number | null; archived: number };

type Candidate = {
	conversation: number;
	matches: number;
	best: number;
	title: boolean;
	exact: boolean;
	spread: boolean;
	picks: number[];
};

const DAY = 86_400_000;
// Above this many matching parts bm25 (most of the cost) is skipped and parts are only counted.
const HEAVY = 10_000;
/**
 * A search reads at most this many matching parts, the newest conversations' first: a word in most of them (or the
 * two letters being typed) then costs the same in a large index as in a small one, and ranks by recency, which is all
 * that can tell such matches apart.
 */
const MAX_MATCHES = 50_000;
/** Word counts are read again after this many parts were written, or this long. */
const COUNTS_STALE_PARTS = 2_000;
const COUNTS_STALE_MS = 60_000;
// By kind: title and prompts and answers first, then reasoning.
const PRIORITY = [1, 1, 2, 0];

export class SearchIndex {
	readonly db: DatabaseSync;
	readonly #statements = new Map<string, StatementSync>();
	readonly #conversations = new Map<number, ConvRow>();
	/** Words already in `vocab`, so writes skip them. */
	readonly #vocab = new Set<string>();
	/** Parts containing each word, as queries read them: a heuristic, so a little stale is fine. */
	#counts = new Map<string, number>();
	#countsWritten = 0;
	#countsAt = 0;
	/** Conversations with forks: only their matches can belong to another conversation too. */
	readonly #forked = new Set<number>();

	constructor(path: string) {
		this.db = new DatabaseSync(path);
		this.db.exec("PRAGMA journal_mode = WAL");
		this.db.exec("PRAGMA synchronous = NORMAL");
		this.db.exec("PRAGMA cache_size = -65536");
		this.db.exec("PRAGMA temp_store = MEMORY");
		this.#migrate();
		for (const row of this.db.prepare("SELECT * FROM conv").all() as ConvRow[]) {
			this.#conversations.set(row.id, { ...row });
			if (row.parent !== null) this.#forked.add(row.parent);
		}
	}

	close(): void {
		this.db.close();
	}

	#migrate(): void {
		const version = (this.db.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
		if (version === SCHEMA_VERSION) return;
		this.db.exec("BEGIN");
		for (const table of ["conv", "part", "vocab", "fts", "usage"]) this.db.exec(`DROP TABLE IF EXISTS ${table}`);
		this.db.exec(`CREATE TABLE conv (
			id INTEGER PRIMARY KEY, counter INTEGER NOT NULL, cursor INTEGER NOT NULL, updated INTEGER NOT NULL,
			parent INTEGER, parent_at INTEGER, archived INTEGER NOT NULL DEFAULT 0)`);
		this.db.exec("CREATE INDEX conv_parent ON conv (parent)");
		// Where each document came from: its entry and content block, and when.
		this.db.exec("CREATE TABLE part (rowid INTEGER PRIMARY KEY, entry INTEGER NOT NULL, idx INTEGER NOT NULL, time INTEGER NOT NULL)");
		// Words for typo matching: alphabetic terms of 4 to 24 letters, by first letter and length.
		this.db.exec("CREATE TABLE vocab (term TEXT PRIMARY KEY, head TEXT NOT NULL, len INTEGER NOT NULL) WITHOUT ROWID");
		this.db.exec("CREATE INDEX vocab_head ON vocab (head, len)");
		// body: the tokens; parts: identifier parts. Pre-tokenized and lowercased, so the ascii tokenizer only splits on
		// spaces; prefix indexes make the word being typed cheap to match.
		this.db.exec(`CREATE VIRTUAL TABLE fts USING fts5(body, parts, content='', contentless_delete=1, tokenize='ascii', prefix='2 3')`);
		this.db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
		this.db.exec("COMMIT");
	}

	#statement(sql: string): StatementSync {
		let statement = this.#statements.get(sql);
		if (statement === undefined) {
			statement = this.db.prepare(sql);
			this.#statements.set(sql, statement);
		}
		return statement;
	}

	#conversation(id: number): ConvRow {
		let row = this.#conversations.get(id);
		if (row === undefined) {
			row = { id, counter: 0, cursor: 0, updated: 0, parent: null, parent_at: null, archived: 0 };
			this.#statement("INSERT OR IGNORE INTO conv (id, counter, cursor, updated) VALUES (?, 0, 0, 0)").run(id);
			this.#conversations.set(id, row);
		}
		return row;
	}

	/** The newest entry of the conversation indexed so far. */
	cursor(conversationId: number): number {
		return this.#conversations.get(conversationId)?.cursor ?? 0;
	}

	/** Index entries, each once: one past a conversation's cursor is new. One transaction for all. */
	add(entries: readonly IndexEntry[]): void {
		if (entries.length === 0) return;
		const insertFts = this.#statement("INSERT INTO fts (rowid, body, parts) VALUES (?, ?, ?)");
		const insertPart = this.#statement("INSERT INTO part (rowid, entry, idx, time) VALUES (?, ?, ?, ?)");
		const insertVocab = this.#statement("INSERT OR IGNORE INTO vocab (term, head, len) VALUES (?, ?, ?)");
		const updateConv = this.#statement("UPDATE conv SET counter = ?, cursor = ?, updated = ? WHERE id = ?");
		const touched = new Set<ConvRow>();
		this.db.exec("BEGIN");
		try {
			for (const entry of entries) {
				const conv = this.#conversation(entry.conversationId);
				if (entry.entryId <= conv.cursor) continue;
				conv.cursor = entry.entryId;
				conv.updated = Math.max(conv.updated, entry.time);
				touched.add(conv);
				for (const part of entry.parts) {
					if (conv.counter >= MAX_SEQ) break;
					const tokens = tokenize(part.text.length > MAX_PART ? part.text.slice(0, MAX_PART) : part.text);
					if (tokens.length === 0) continue;
					conv.counter += 1;
					const rowid = conv.id * CONV_SHIFT + conv.counter * 8 + part.kind;
					const body: string[] = [];
					const parts: string[] = [];
					for (const token of tokens) {
						if (token.part === true) parts.push(token.text);
						else {
							body.push(token.text);
							const text = token.text;
							if (text.length >= 4 && text.length <= 24 && !this.#vocab.has(text) && /^\p{L}+$/u.test(text)) {
								this.#vocab.add(text);
								insertVocab.run(text, text[0]!, text.length);
							}
						}
					}
					insertFts.run(rowid, body.join(" "), parts.join(" "));
					insertPart.run(rowid, entry.entryId, part.idx, entry.time);
					this.#countsWritten += 1;
				}
			}
			for (const conv of touched) updateConv.run(conv.counter, conv.cursor, conv.updated, conv.id);
			this.db.exec("COMMIT");
		} catch (error) {
			this.db.exec("ROLLBACK");
			// The rows in memory may be ahead of the file: read them again.
			this.#conversations.clear();
			for (const row of this.db.prepare("SELECT * FROM conv").all() as ConvRow[]) this.#conversations.set(row.id, { ...row });
			throw error;
		}
	}

	/** A conversation's title, replacing the one indexed before. */
	setTitle(conversationId: number, title: string): void {
		const conv = this.#conversation(conversationId);
		const rowid = conv.id * CONV_SHIFT + Kind.title;
		this.#statement("DELETE FROM fts WHERE rowid = ?").run(rowid);
		const tokens = tokenize(title);
		if (tokens.length === 0) return;
		this.#statement("INSERT INTO fts (rowid, body, parts) VALUES (?, ?, ?)").run(
			rowid,
			tokens.filter((token) => token.part !== true).map((token) => token.text).join(" "),
			tokens.filter((token) => token.part === true).map((token) => token.text).join(" "),
		);
	}

	/** Where a conversation was forked from. */
	setConversation(conversationId: number, info: ConversationInfo): void {
		const conv = this.#conversation(conversationId);
		const parent = info.parent?.conversationId ?? null;
		const at = info.parent?.at ?? null;
		if (conv.parent === parent && conv.parent_at === at) return;
		conv.parent = parent;
		conv.parent_at = at;
		if (parent !== null) this.#forked.add(parent);
		this.#statement("UPDATE conv SET parent = ?, parent_at = ? WHERE id = ?").run(parent, at, conv.id);
	}

	/** Archived conversations rank lower. */
	setArchived(conversationId: number, archived: boolean): void {
		const conv = this.#conversation(conversationId);
		const value = archived ? 1 : 0;
		if (conv.archived === value) return;
		conv.archived = value;
		this.#statement("UPDATE conv SET archived = ? WHERE id = ?").run(value, conv.id);
	}

	#vocabulary(): Vocabulary {
		this.db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS temp.fts_vocab USING fts5vocab(main, fts, 'row')");
		const count = this.#statement("SELECT doc FROM temp.fts_vocab WHERE term = ?");
		const words = this.#statement("SELECT term FROM vocab WHERE head = ? AND len BETWEEN ? AND ?");
		if (this.#countsWritten > COUNTS_STALE_PARTS || Date.now() - this.#countsAt > COUNTS_STALE_MS) {
			this.#counts = new Map();
			this.#countsWritten = 0;
			this.#countsAt = Date.now();
		}
		const cache = this.#counts;
		return {
			documents(token) {
				let value = cache.get(token);
				if (value === undefined) {
					value = (count.get(token) as { doc: number } | undefined)?.doc ?? 0;
					cache.set(token, value);
				}
				return value;
			},
			words(head, min, max) {
				return (words.all(head, min, max) as { term: string }[]).map((row) => row.term);
			},
		};
	}

	/**
	 * Conversations matching `input`, best first, with their best hits. Strict tiers whatever the age (every word
	 * exactly in one part; then with prefixes or typos; then spread over several parts), then bm25 and the number of
	 * matches, times a recency boost. A fork shows a match it shares with its origin once, as the one active last.
	 */
	async search(input: string, load: TextLoader, options: SearchOptions = {}): Promise<SearchResponse> {
		const started = performance.now();
		const now = options.now ?? Date.now();
		const query = parseQuery(input);
		const vocabulary = this.#vocabulary();
		const typing = options.typing === true && !/\s$/.test(input);
		const terms = query.terms.flatMap((term, index) => compile(vocabulary, term, { fuzzy: true, typing: typing && index === query.terms.length - 1 }) ?? []);
		const excluded = query.excluded.flatMap((term) => compile(vocabulary, term, { fuzzy: false }) ?? []);
		const kinds = options.kinds?.map((kind) => Kind[kind]);
		const limit = options.limit ?? 20;
		const offset = options.offset ?? 0;
		const compiled = terms.map((term) => ({ tokens: term.tokens, prefix: term.prefix, variants: term.variants }));
		if (terms.length === 0) return { results: [], total: 0, terms: compiled, ms: performance.now() - started };

		// One pass over every match, prefixes and typos included; which conversations match exactly is a cheaper set.
		const candidates = new Map<number, Candidate>();
		const fuzzy = terms.some((term) => term.prefix || term.variants.length > 0);
		const exactSet = fuzzy ? this.#conversationSet(terms.map((term) => ftsExpression(term, true)).join(" AND "), kinds) : undefined;
		for (const row of this.#grouped(terms.map((term) => ftsExpression(term)).join(" AND "), kinds)) {
			const exact = exactSet === undefined || exactSet.has(row.s);
			candidates.set(row.s, { conversation: row.s, matches: row.n, best: row.best, title: row.title, exact, spread: false, picks: row.picks });
		}
		// Terms spread over different parts of one conversation still find it, ranked below every other match: needed only
		// when those do not fill the page.
		if (terms.length > 1 && candidates.size < offset + limit) {
			const perTerm = terms.map((term) => this.#conversationSet(ftsExpression(term), kinds));
			const [first, ...others] = perTerm;
			for (const conversation of first!) {
				if (candidates.has(conversation) || !others.every((set) => set.has(conversation))) continue;
				candidates.set(conversation, { conversation, matches: 0, best: 0, title: false, exact: false, spread: true, picks: [] });
			}
		}
		const skip = excluded.length === 0 ? new Set<number>() : this.#conversationSet(excluded.map((term) => ftsExpression(term, true)).join(" OR "), kinds);

		// A fork's match in what it shares with its origin goes to whichever of them was active last.
		const ranked: { candidate: Candidate; conv: ConvRow; score: number }[] = [];
		const merged = new Map<number, { candidate: Candidate; conv: ConvRow; score: number }>();
		for (const candidate of candidates.values()) {
			if (skip.has(candidate.conversation)) continue;
			let conv = this.#conversations.get(candidate.conversation);
			if (conv === undefined) continue;
			const newest = this.#newestFork(conv, candidate.picks[0]);
			if (newest !== conv) {
				conv = newest;
			}
			const existing = merged.get(conv.id);
			if (existing !== undefined) {
				// The fork's own match and the shared one: one result, the better tier, all the matches.
				if (tier(candidate) > tier(existing.candidate)) existing.candidate = { ...candidate, conversation: conv.id, picks: [...candidate.picks, ...existing.candidate.picks] };
				else existing.candidate.picks.push(...candidate.picks);
				existing.candidate.matches += candidate.matches;
				continue;
			}
			const item = { candidate, conv, score: 0 };
			merged.set(conv.id, item);
			ranked.push(item);
		}
		for (const item of ranked) item.score = rank(item.conv, relevance(item.candidate), now);
		ranked.sort((a, b) => tier(b.candidate) - tier(a.candidate) || b.score - a.score || b.conv.updated - a.conv.updated);

		const page = ranked.slice(offset, offset + limit);
		const want = Math.max(1, options.hits ?? 1);
		const context = options.context ?? 80;
		const exactTerms = terms.map((term) => ({ ...term, prefix: false, variants: [] }));
		const results: SearchResult[] = [];
		const partRow = this.#statement("SELECT entry, idx, time FROM part WHERE rowid = ?");
		for (const item of page) {
			let picks = [...new Set(item.candidate.picks)];
			if (item.candidate.spread) picks = this.#spreadPicks(item.candidate.conversation, terms, kinds);
			picks.sort((x, y) => PRIORITY[kindOf(x)]! - PRIORITY[kindOf(y)]! || y - x);
			const hits: SearchHit[] = [];
			for (const rowid of picks) {
				if (hits.length >= want) break;
				const kind = KIND_NAMES[kindOf(rowid)]!;
				const source = conversationOf(rowid);
				let text: string | undefined;
				let entryId: number | undefined;
				let time = item.conv.updated;
				if (kind === "title") {
					text = await load(source, 0, -1);
				} else {
					const part = partRow.get(rowid) as { entry: number; idx: number; time: number } | undefined;
					if (part === undefined) continue;
					entryId = part.entry;
					time = part.time;
					text = await load(source, part.entry, part.idx);
				}
				if (text === undefined) continue;
				const ranges = highlight(text, item.candidate.exact ? exactTerms : terms);
				const cut = excerpt(text, ranges, context);
				hits.push({
					kind,
					...(entryId === undefined ? {} : { entryId }),
					time,
					text: cut.text,
					before: cut.before,
					after: cut.after,
					ranges: cut.ranges.map((range: Range) => [range.start, range.end]),
				});
			}
			results.push({ conversationId: item.conv.id, score: item.score, matches: item.candidate.matches, spread: item.candidate.spread, hits });
		}
		return { results, total: ranked.length, terms: compiled, ms: performance.now() - started };
	}

	/**
	 * One conversation's matching entries, newest first, as a chat's own search steps through them: its parts and the
	 * ones it shares with the conversations it was forked from.
	 */
	searchConversation(conversationId: number, input: string, options: { kinds?: KindName[]; limit?: number; typing?: boolean } = {}): {
		hits: { entryId: number; kind: KindName; time: number }[];
		terms: SearchResponse["terms"];
	} {
		const query = parseQuery(input);
		const vocabulary = this.#vocabulary();
		const typing = options.typing === true && !/\s$/.test(input);
		const terms = query.terms.flatMap((term, index) => compile(vocabulary, term, { fuzzy: true, typing: typing && index === query.terms.length - 1 }) ?? []);
		const compiled = terms.map((term) => ({ tokens: term.tokens, prefix: term.prefix, variants: term.variants }));
		if (terms.length === 0) return { hits: [], terms: compiled };
		const kinds = (options.kinds ?? ["user", "assistant", "reasoning"]).map((kind) => Kind[kind]).filter((kind) => kind !== Kind.title);
		const limit = options.limit ?? 1000;
		const expression = terms.map((term) => ftsExpression(term)).join(" AND ");
		const hits: { entryId: number; kind: KindName; time: number }[] = [];
		const seen = new Set<number>();
		// The conversation, then each origin up to where it was forked.
		let conv = this.#conversations.get(conversationId);
		let upTo = Number.POSITIVE_INFINITY;
		while (conv !== undefined && hits.length < limit) {
			const [low, high] = range(conv.id);
			const rows = this.#statement(
				`SELECT f.rowid AS rowid, p.entry AS entry, p.time AS time FROM fts f JOIN part p ON p.rowid = f.rowid
				 WHERE fts MATCH ? AND f.rowid BETWEEN ? AND ? AND (f.rowid & 7) IN (${kinds.join(",")}) ORDER BY f.rowid DESC LIMIT ?`,
			).all(expression, low, high, limit) as { rowid: number; entry: number; time: number }[];
			for (const row of rows) {
				if (row.entry > upTo || seen.has(row.entry)) continue;
				seen.add(row.entry);
				hits.push({ entryId: row.entry, kind: KIND_NAMES[kindOf(row.rowid)]!, time: row.time });
			}
			if (conv.parent === null || conv.parent_at === null) break;
			upTo = Math.min(upTo, conv.parent_at);
			conv = this.#conversations.get(conv.parent);
		}
		hits.sort((a, b) => b.entryId - a.entryId);
		return { hits: hits.slice(0, limit), terms: compiled };
	}

	/** The most recently active fork of `conv` that still shares the entry of `rowid`, or `conv`. */
	#newestFork(conv: ConvRow, rowid: number | undefined): ConvRow {
		if (rowid === undefined || kindOf(rowid) === Kind.title || !this.#forked.has(conv.id)) return conv;
		const entry = (this.#statement("SELECT entry FROM part WHERE rowid = ?").get(rowid) as { entry: number } | undefined)?.entry;
		if (entry === undefined) return conv;
		let best = conv;
		const children = this.#statement("SELECT id FROM conv WHERE parent = ? AND parent_at >= ?");
		const visit = (id: number, depth: number): void => {
			if (depth > 8) return;
			for (const { id: child } of children.all(id, entry) as { id: number }[]) {
				const row = this.#conversations.get(child);
				if (row === undefined) continue;
				if (row.updated > best.updated) best = row;
				visit(child, depth + 1);
			}
		};
		visit(conv.id, 0);
		return best;
	}

	/**
	 * Matching conversations with their number of matching parts, the best bm25 when there are few enough matches to
	 * afford it, and parts to show: the newest prompt or answer or title, the best by bm25, the newest reasoning, the
	 * newest and the oldest. One pass collects them, so showing hits never runs the match again.
	 */
	#grouped(expression: string, kinds: number[] | undefined): { s: number; n: number; best: number; title: boolean; picks: number[] }[] {
		const filter = kinds === undefined ? "" : ` AND (rowid & 7) IN (${kinds.join(",")})`;
		// Bit operations, cheaper than division and modulo, as each aggregate costs per matching row.
		const counted = this.#statement(
			`SELECT rowid >> ${CONV_BITS} AS s, count(*) AS n,
				max(CASE WHEN (rowid & 7) != 2 THEN rowid END) AS said,
				max(CASE WHEN (rowid & 7) = 2 THEN rowid END) AS thought,
				max((rowid & 7) = 3) AS title
			 FROM (SELECT rowid FROM fts WHERE fts MATCH ?${filter} ORDER BY rowid DESC LIMIT ${MAX_MATCHES}) GROUP BY s`,
		).all(expression) as { s: number; n: number; said: number | null; thought: number | null; title: number }[];
		const total = counted.reduce((sum, row) => sum + row.n, 0);
		const scored =
			total > HEAVY
				? new Map<number, { best: number; top: number }>()
				: new Map(
						(
							this.#statement(
								`WITH m AS MATERIALIZED (SELECT rowid AS id, rowid >> ${CONV_BITS} AS s, bm25(fts) AS b FROM fts WHERE fts MATCH ?${filter})
								 SELECT s, min(b) AS best, id AS top FROM m GROUP BY s`,
							).all(expression) as { s: number; best: number; top: number }[]
						).map((row) => [row.s, row]),
					);
		return counted.map((row) => {
			const top = scored.get(row.s)?.top;
			const picks = [row.said, top, row.thought].filter((rowid): rowid is number => typeof rowid === "number");
			return { s: row.s, n: row.n, best: scored.get(row.s)?.best ?? 0, title: row.title === 1, picks: [...new Set(picks)] };
		});
	}

	#conversationSet(expression: string, kinds: number[] | undefined): Set<number> {
		const filter = kinds === undefined ? "" : ` AND (rowid & 7) IN (${kinds.join(",")})`;
		return new Set(
			(
				this.#statement(
					`SELECT DISTINCT rowid >> ${CONV_BITS} AS s FROM (SELECT rowid FROM fts WHERE fts MATCH ?${filter} ORDER BY rowid DESC LIMIT ${MAX_MATCHES})`,
				).all(expression) as { s: number }[]
			).map(
				(row) => row.s,
			),
		);
	}

	/** For a conversation whose terms match only in different parts: the newest parts with any of them. */
	#spreadPicks(conversation: number, terms: Compiled[], kinds: number[] | undefined): number[] {
		const [low, high] = range(conversation);
		const filter = kinds === undefined ? "" : ` AND (rowid & 7) IN (${kinds.join(",")})`;
		return (
			this.#statement(`SELECT rowid FROM fts WHERE fts MATCH ? AND rowid BETWEEN ? AND ?${filter} ORDER BY rowid DESC LIMIT 20`).all(
				terms.map((term) => ftsExpression(term)).join(" OR "),
				low,
				high,
			) as { rowid: number }[]
		).map((row) => row.rowid);
	}
}

function tier(candidate: Candidate): number {
	if (candidate.spread) return 0;
	return candidate.exact ? 2 : 1;
}

/** Within a tier: the best part's bm25 and how many parts match; a title match counts more. */
function relevance(candidate: Candidate): number {
	if (candidate.spread) return 1;
	return (Math.max(-candidate.best, 0.5) + 0.5 * Math.log2(1 + candidate.matches)) * (candidate.title ? 1.5 : 1);
}

/** Recent conversations first among similar matches: x2.5 today, x1.75 two weeks ago, toward x1. */
function rank(conv: ConvRow, relevance: number, now: number): number {
	const age = Math.max(0, now - conv.updated);
	const recency = 1 + 1.5 * 2 ** (-age / (14 * DAY));
	return relevance * recency * (conv.archived === 1 ? 0.5 : 1);
}
