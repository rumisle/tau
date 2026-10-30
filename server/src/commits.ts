import type { CommitPublication, Harness } from "@earendil-works/pi-durable";

/**
 * Calls `listener` with every commit the Harness stores (durable's `observeCommits()`), until the returned function is
 * called or the Harness closes. Like a durable observer, the listener only records: no awaits, no Session calls.
 */
export function onCommit(harness: Harness, listener: (publication: CommitPublication) => void): () => void {
	const observation = harness.observeCommits({ advance: (publication) => listener(publication), end: () => {} });
	return () => observation.detach();
}

/** The value a document change wrote, or `null` when the commit retired the document. */
export function changedValue(change: { kind: "change"; value: unknown } | { kind: "retire" }): unknown {
	return change.kind === "change" ? change.value : null;
}
