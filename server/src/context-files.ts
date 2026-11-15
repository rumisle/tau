// Host-owned context-file discovery, installed through durable's section extension API.
import { readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { defineExtension, section } from "@earendil-works/pi-durable";

const CANDIDATES = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"];
type ContextFile = { path: string; content: string };

function missing(error: unknown): boolean {
	return ["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "");
}

function fromDirectory(directory: string): ContextFile | undefined {
	for (const name of CANDIDATES) {
		const path = join(directory, name);
		try {
			if (statSync(path).isFile()) return { path, content: readFileSync(path, "utf8").replace(/^\uFEFF/, "") };
		} catch (error) {
			if (!missing(error)) throw error; // Let durable report it and retain the previous section.
		}
	}
	return undefined;
}

function within(parent: string, child: string): boolean {
	const path = relative(parent, child);
	return path === "" || (!isAbsolute(path) && path !== ".." && !path.startsWith(`..${sep}`));
}

// Like Pi: a nested linked worktree's context shadows the main worktree's
// context at the same logical repository scope, not unrelated ancestor rules.
function shadowedContextFile(cwd: string): string | undefined {
	for (let directory = cwd; ; directory = dirname(directory)) {
		try {
			const dotgit = join(directory, ".git");
			if (statSync(dotgit).isDirectory()) return undefined;
			const match = /^gitdir:\s*(.+)\s*$/m.exec(readFileSync(dotgit, "utf8"));
			if (match === null) return undefined;
			const gitdir = resolve(directory, match[1]!.trim());
			let common: string;
			try {
				common = realpathSync(resolve(gitdir, readFileSync(join(gitdir, "commondir"), "utf8").trim()));
			} catch (error) {
				if (missing(error)) return undefined; // e.g. a submodule, not a linked worktree.
				throw error;
			}
			const main = dirname(common);
			const worktree = realpathSync(directory);
			const own = fromDirectory(directory);
			if (main === worktree || !within(main, worktree) || own === undefined) return undefined;
			return realpathSync(join(main, ".git")) === common ? join(main, basename(own.path)) : undefined;
		} catch (error) {
			if (!missing(error)) throw error;
		}
		if (dirname(directory) === directory) return undefined;
	}
}

export function loadContextFiles(cwd: string, agentDir = join(homedir(), ".agents")): ContextFile[] {
	const global = fromDirectory(resolve(agentDir));
	const ancestors: ContextFile[] = [];
	const shadowed = shadowedContextFile(resolve(cwd));
	for (let directory = resolve(cwd); ; directory = dirname(directory)) {
		const file = fromDirectory(directory);
		if (file && (shadowed === undefined || join(realpathSync(directory), basename(file.path)) !== shadowed)) ancestors.unshift(file);
		if (dirname(directory) === directory) break;
	}
	const seen = new Set<string>();
	return [...(global ? [global] : []), ...ancestors].filter((file) => {
		const path = realpathSync(file.path);
		if (seen.has(path)) return false;
		seen.add(path);
		return true;
	});
}

export function contextFilesExtension(agentDir?: string) {
	return defineExtension({
		name: "context-files",
		sections: [section("agents-md", ({ env }) => {
			if (env === undefined) throw new Error("Cannot load context files without a conversation environment");
			const files = loadContextFiles(env.cwd, agentDir);
			if (files.length === 0) return undefined;
			return ["Project-specific instructions and guidelines:", ...files.map(({ path, content }) =>
				`<project_instructions path=${JSON.stringify(path)}>\n${content}\n</project_instructions>`,
			)].join("\n\n");
		})],
	});
}
