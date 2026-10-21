// One tokenizer for the index, the query and the highlighter, so a highlight is always exactly what matched. After
// rumisle/recall's (MIT): a token is a run of letters and digits, lowercased with diacritics removed; CJK characters,
// which have no spaces between words, are one token each, and a CJK word in a query is a phrase of its characters, so
// it matches as an exact substring; identifiers also yield their parts ("CommandPalette" -> command, palette).

export type Token = {
	/** Normalized form. */
	text: string;
	/** Offsets in the original string (UTF-16). */
	start: number;
	end: number;
	/** A part of an identifier, indexed besides the whole. */
	part?: true;
};

/** Longer runs (base64, minified code) are not indexed. */
export const MAX_TOKEN = 64;

const WORD = /[\p{L}\p{N}\p{M}]+/gu;
const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
const CJK_RUN = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]+/gu;
const MARKS = /\p{M}/gu;
// Boundaries inside an identifier: aB, ABc (before the B), a1, 1a.
const PART = /\p{Lu}?\p{Ll}+|\p{Lu}+(?!\p{Ll})|\p{N}+|[\p{L}\p{M}]+/gu;
const ASCII_TEXT = /^[\x00-\x7f]*$/;
// ASCII words and their identifier boundaries, for the fast path most text takes.
const ASCII_WORD = /[A-Za-z0-9]+/g;
const ASCII_PART = /[A-Z]?[a-z]+|[A-Z]+(?![a-z])|[0-9]+/g;
// Words that are one piece: all lower, all upper, capitalized, or all digits.
const PLAIN = /^(?:[a-z]+|[A-Z]?[a-z]*|[A-Z]+|[0-9]+)$/;

export function normalize(text: string): string {
	return text.normalize("NFKD").replace(MARKS, "").toLowerCase();
}

export function isCjk(token: string): boolean {
	return CJK.test(token);
}

export function tokenize(text: string): Token[] {
	const out: Token[] = [];
	// Most of a transcript is ASCII: plain regexes, no normalization.
	if (ASCII_TEXT.test(text)) {
		for (const word of text.matchAll(ASCII_WORD)) pushAscii(out, word[0], word.index);
		return out;
	}
	for (const word of text.matchAll(WORD)) {
		const start = word.index;
		if (CJK.test(word[0])) {
			// CJK characters (one token each) and the other runs between them.
			let last = 0;
			for (const run of word[0].matchAll(CJK_RUN)) {
				if (run.index > last) pushWord(out, word[0].slice(last, run.index), start + last);
				for (let i = 0; i < run[0].length; i++) {
					const code = run[0].codePointAt(i)!;
					const char = String.fromCodePoint(code);
					out.push({ text: normalize(char), start: start + run.index + i, end: start + run.index + i + char.length });
					if (char.length === 2) i++;
				}
				last = run.index + run[0].length;
			}
			if (last < word[0].length) pushWord(out, word[0].slice(last), start + last);
			continue;
		}
		pushWord(out, word[0], start);
	}
	return out;
}

function pushAscii(out: Token[], word: string, start: number): void {
	if (word.length > MAX_TOKEN) return;
	out.push({ text: word.toLowerCase(), start, end: start + word.length });
	if (PLAIN.test(word)) return;
	let count = 0;
	const parts: Token[] = [];
	for (const part of word.matchAll(ASCII_PART)) {
		count++;
		parts.push({ text: part[0].toLowerCase(), start: start + part.index, end: start + part.index + part[0].length, part: true });
	}
	if (count >= 2) out.push(...parts);
}

function pushWord(out: Token[], word: string, start: number): void {
	if (word.length > MAX_TOKEN) return;
	if (ASCII_TEXT.test(word)) {
		for (const piece of word.matchAll(ASCII_WORD)) pushAscii(out, piece[0], start + piece.index);
		return;
	}
	const text = normalize(word);
	if (!text) return;
	out.push({ text, start, end: start + word.length });
	const parts = [...word.matchAll(PART)];
	if (parts.length < 2) return;
	for (const part of parts) {
		const normalized = normalize(part[0]);
		if (normalized) out.push({ text: normalized, start: start + part.index, end: start + part.index + part[0].length, part: true });
	}
}
