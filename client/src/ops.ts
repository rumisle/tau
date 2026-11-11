// The protocol's doc ops (docs/protocol.md "Ops"), applied immutably. A standalone implementation rather than Chord's,
// to keep the spec honest.
import type { Json, Op } from "./protocol.ts";

export function applyOps(value: Json, ops: readonly Op[]): Json {
	let root = structuredClone(value);
	for (const op of ops) {
		if (op[0] === "r") {
			root = structuredClone(op[1]);
			continue;
		}
		const path = op[1];
		if (op[0] === "p" || op[0] === "m") {
			const array = resolve(root, path) as Json[];
			if (op[0] === "p") array.splice(op[2], op[3], ...structuredClone(op[4]));
			else {
				const old = [...array];
				op[2].forEach((from, to) => {
					array[to] = old[from]!;
				});
			}
			continue;
		}
		const parent = resolve(root, path.slice(0, -1)) as Record<string | number, Json>;
		const key = path.at(-1)!;
		switch (op[0]) {
			case "s":
				parent[key] = structuredClone(op[2]);
				break;
			case "d":
				if (Array.isArray(parent)) parent.splice(key as number, 1);
				else delete parent[key];
				break;
			case "a":
				parent[key] = (parent[key] as string) + op[2];
				break;
			case "t":
				parent[key] = (parent[key] as string).slice(op[2]);
				break;
		}
	}
	return root;
}

function resolve(root: Json, path: readonly (string | number)[]): Json {
	let node = root;
	for (const key of path) node = (node as Record<string | number, Json>)[key]!;
	return node;
}
