// Per-key FIFO execution: what changes one conversation runs one at a time, in the order its requests arrived.

export class Serial {
	readonly #tails = new Map<string, Promise<unknown>>();

	/**
	 * Run `task` after every task queued before it under `key`. The queue position is taken synchronously, so
	 * requests read from one socket in order run in that order even when each awaits before it starts its work.
	 */
	run<T>(key: string, task: () => Promise<T>): Promise<T> {
		const previous = this.#tails.get(key) ?? Promise.resolve();
		const result = previous.then(task, task);
		const tail = result.then(
			() => undefined,
			() => undefined,
		);
		this.#tails.set(key, tail);
		void tail.then(() => {
			if (this.#tails.get(key) === tail) this.#tails.delete(key);
		});
		return result;
	}
}
