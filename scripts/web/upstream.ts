// Telegram Web A in web/ (docs/web.md "Where the code lives"): imported at a commit, filtered; updated by a 3-way merge
// per file between the old and new commits and tau's tree; tau's edits shown, and checked for their `tau:` marks.
//
// Usage: node scripts/web/upstream.ts import <commit>
//        node scripts/web/upstream.ts update [commit]        (default: the tip of upstream's master)
//        node scripts/web/upstream.ts diff [--check] [--stat] [path...]
//
// web/UPSTREAM names the commit and the filter. Upstream's commits are fetched into vendor/telegram-tt (shallow, from
// TAU_WEB_UPSTREAM, by default GitHub). A file is upstream's when the commit in web/UPSTREAM has it after the filter;
// every other file in web/ is tau's.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "../..");
const WEB = join(ROOT, "web");
const MANIFEST = join(WEB, "UPSTREAM");
const CLONE = join(ROOT, "vendor", "telegram-tt");
const SOURCE = process.env.TAU_WEB_UPSTREAM ?? "https://github.com/Ajaxy/telegram-tt.git";
const MARK = "tau:";

type Manifest = { commit: string; exclude: string[] };

function git(args: string[], options: { cwd?: string; input?: string | Buffer } = {}): Buffer {
	return execFileSync("git", args, { cwd: options.cwd ?? CLONE, input: options.input, maxBuffer: 1 << 30 });
}

function readManifest(): Manifest {
	const manifest: Manifest = { commit: "", exclude: [] };
	for (const line of readFileSync(MANIFEST, "utf8").split("\n")) {
		const [key, value] = [line.slice(0, line.indexOf(" ")), line.slice(line.indexOf(" ") + 1).trim()];
		if (key === "commit") manifest.commit = value;
		if (key === "exclude") manifest.exclude.push(value);
	}
	return manifest;
}

function writeManifest(manifest: Manifest): void {
	const lines = [
		"# Telegram Web A (https://github.com/Ajaxy/telegram-tt, GPL-3.0-or-later), vendored by scripts/web/upstream.ts.",
		"# `commit`: the upstream commit web/ is at. `exclude`: what a build does not need (a path, or a directory with /).",
		`commit ${manifest.commit}`,
		...manifest.exclude.map((path) => `exclude ${path}`),
	];
	writeFileSync(MANIFEST, `${lines.join("\n")}\n`);
}

/** The upstream commit, fetched into the clone; returns its full hash. */
function fetchCommit(commit: string): string {
	if (!existsSync(join(CLONE, ".git"))) {
		mkdirSync(CLONE, { recursive: true });
		git(["init", "-q"]);
	}
	const known = spawnSync("git", ["rev-parse", "--verify", "-q", `${commit}^{commit}`], { cwd: CLONE, encoding: "utf8" });
	if (known.status === 0) return known.stdout.trim();
	console.log(`fetching ${commit} from ${SOURCE}`);
	git(["fetch", "-q", "--depth", "1", SOURCE, commit]);
	return git(["rev-parse", "FETCH_HEAD"]).toString().trim();
}

/** The commit's files after the filter, by path: their blob IDs. */
function files(commit: string, exclude: string[]): Map<string, string> {
	const result = new Map<string, string>();
	for (const line of git(["ls-tree", "-r", "-z", commit]).toString().split("\0")) {
		if (!line) continue;
		const [meta, path] = line.split("\t") as [string, string];
		const [mode, type, blob] = meta.split(" ") as [string, string, string];
		if (type !== "blob" || mode === "120000") continue;
		if (exclude.some((rule) => (rule.endsWith("/") ? path.startsWith(rule) : path === rule))) continue;
		result.set(path, blob);
	}
	return result;
}

function blob(id: string): Buffer {
	return git(["cat-file", "blob", id]);
}

/** The blob IDs tau's files in web/ would have, by path (one `git hash-object` for all); undefined when absent. */
function hashes(paths: string[]): Map<string, string | undefined> {
	const present = paths.filter((path) => existsSync(join(WEB, path)));
	const ids = present.length === 0 ? [] : git(["hash-object", "--no-filters", "--stdin-paths"], { input: present.map((path) => join(WEB, path)).join("\n") }).toString().trim().split("\n");
	const result = new Map<string, string | undefined>(paths.map((path) => [path, undefined]));
	present.forEach((path, index) => result.set(path, ids[index]));
	return result;
}

function write(path: string, content: Buffer): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, content);
}

function importCommit(commit: string): void {
	const exclude = existsSync(MANIFEST)
		? readManifest().exclude
		: ["dist/", "tauri/", "deploy/", ".github/", ".husky/", "public/build-stats.json", "public/statoscope-report.html"];
	const full = fetchCommit(commit);
	const tree = files(full, exclude);
	for (const [path, id] of tree) write(join(WEB, path), blob(id));
	writeManifest({ commit: full, exclude });
	console.log(`web/: ${tree.size} files of ${full}`);
}

function update(commit: string): void {
	const manifest = readManifest();
	const oldCommit = fetchCommit(manifest.commit);
	const newCommit = fetchCommit(commit);
	const before = files(oldCommit, manifest.exclude);
	const after = files(newCommit, manifest.exclude);
	const conflicts: string[] = [];
	let taken = 0;
	const changed = [...new Set([...before.keys(), ...after.keys()])].filter((path) => before.get(path) !== after.get(path));
	const current = hashes(changed);
	for (const path of changed) {
		const base = before.get(path);
		const theirs = after.get(path);
		const file = join(WEB, path);
		const ours = existsSync(file) ? readFileSync(file) : undefined;
		const untouched = current.get(path) === base;
		if (untouched) {
			// Not changed by tau: upstream's, added, changed or deleted.
			if (theirs === undefined) rmSync(file);
			else write(file, blob(theirs));
			taken++;
			continue;
		}
		if (base === undefined || theirs === undefined || ours === undefined) {
			conflicts.push(`${path}: ${ours === undefined ? "deleted by tau" : base === undefined ? "added by both" : "changed by tau"}, ${theirs === undefined ? "deleted" : base === undefined ? "added" : "changed"} upstream`);
			continue;
		}
		const scratch = join(CLONE, ".merge");
		mkdirSync(scratch, { recursive: true });
		writeFileSync(join(scratch, "base"), blob(base));
		writeFileSync(join(scratch, "theirs"), blob(theirs));
		const merged = spawnSync("git", ["merge-file", "-p", "-L", "tau", "-L", manifest.commit.slice(0, 7), "-L", newCommit.slice(0, 7), file, join(scratch, "base"), join(scratch, "theirs")], { maxBuffer: 1 << 30 });
		writeFileSync(file, merged.stdout);
		if (merged.status !== 0) conflicts.push(`${path}: conflict markers`);
		taken++;
	}
	writeManifest({ commit: newCommit, exclude: manifest.exclude });
	console.log(`web/: ${manifest.commit.slice(0, 12)} -> ${newCommit.slice(0, 12)}, ${taken} files changed`);
	if (conflicts.length > 0) {
		console.log(`${conflicts.length} to resolve:\n  ${conflicts.join("\n  ")}`);
		process.exitCode = 1;
	}
}

/** tau's edits to upstream's files: a diff per file against the commit in web/UPSTREAM. */
function diff(options: { check: boolean; stat: boolean; paths: string[] }): void {
	const manifest = readManifest();
	const commit = fetchCommit(manifest.commit);
	const tree = files(commit, manifest.exclude);
	const scratch = join(CLONE, ".diff");
	const changed: string[] = [];
	const unmarked: string[] = [];
	const paths = [...tree.keys()].filter((path) => options.paths.length === 0 || options.paths.some((each) => path.startsWith(each))).sort();
	const current = hashes(paths);
	for (const path of paths) {
		if (current.get(path) === tree.get(path)) continue;
		const file = join(WEB, path);
		const ours = existsSync(file) ? readFileSync(file) : undefined;
		const pristine = blob(tree.get(path)!);
		changed.push(path);
		write(join(scratch, "a", path), pristine);
		const result = spawnSync("git", ["diff", "--no-index", "--no-color", `--src-prefix=a/`, `--dst-prefix=b/`, join(scratch, "a", path), ours === undefined ? "/dev/null" : file], { encoding: "utf8", maxBuffer: 1 << 30 });
		const text = result.stdout.replaceAll(`a${join(scratch, "a")}/`, "a/").replaceAll(`b${WEB}/`, "b/");
		if (!options.check && !options.stat) process.stdout.write(text);
		// Each hunk says why it is there: a `tau:` mark among its added lines.
		for (const hunk of text.split(/^@@/m).slice(1)) {
			const added = hunk.split("\n").filter((line) => line.startsWith("+"));
			if (!added.some((line) => line.includes(MARK))) unmarked.push(`${path} @@${hunk.split("\n")[0]}`);
		}
	}
	rmSync(scratch, { recursive: true, force: true });
	if (options.stat || options.check) console.log(`${changed.length} of upstream's ${tree.size} files changed by tau${options.stat ? `:\n  ${changed.join("\n  ")}` : ""}`);
	if (options.check && unmarked.length > 0) {
		console.log(`${unmarked.length} hunks without a \`${MARK}\` mark:\n  ${unmarked.join("\n  ")}`);
		process.exitCode = 1;
	}
}

const [command, ...rest] = process.argv.slice(2);
if (command === "import" && rest[0]) importCommit(rest[0]);
else if (command === "update") update(rest[0] ?? "master");
else if (command === "diff") diff({ check: rest.includes("--check"), stat: rest.includes("--stat"), paths: rest.filter((each) => !each.startsWith("--")) });
else {
	console.error("usage: node scripts/web/upstream.ts import <commit> | update [commit] | diff [--check] [--stat] [path...]");
	process.exit(2);
}
