import assert from "node:assert/strict";
import { test } from "node:test";
import { withoutQuotes } from "../src/quotes.ts";

test("a preview leaves blocks out and keeps a few quoted words", () => {
	const text = "<tau:quote>\nbecause users may type it\n</tau:quote>\n\nhhahaha, and <tau:quote>not Markdown's</tau:quote>?";
	assert.equal(withoutQuotes(text).trim(), "hhahaha, and not Markdown's?");
	assert.equal(withoutQuotes("<tau:quote>\nonly this\n</tau:quote>"), "only this");
	// Code is code, and a tag never closed is text.
	const code = "```\n<tau:quote>\nx\n</tau:quote>\n```";
	assert.equal(withoutQuotes(code), code);
	assert.equal(withoutQuotes("see `<tau:quote>x</tau:quote>`"), "see `<tau:quote>x</tau:quote>`");
	assert.equal(withoutQuotes("<tau:quote>\nopen"), "<tau:quote>\nopen");
});
