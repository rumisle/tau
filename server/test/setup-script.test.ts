// scripts/tau setup's edits of the user's files: the flags (only the options it manages) and tau-cmd.slice's MemoryMax=.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

const TAU = join(import.meta.dirname, "..", "..", "scripts", "tau");
const dir = mkdtempSync(join(tmpdir(), "tau-setup-"));
after(() => rmSync(dir, { recursive: true, force: true }));
const tau = (...args: string[]) => spawnSync("bash", [TAU, ...args], { encoding: "utf8", env: { ...process.env, TAU_LIB: join(dir, "lib"), TAU_CONFIG: join(dir, "config") } });
/** The words tau serve passes the server for a flags file. */
const words = (file: string) => spawnSync("bash", ["-c", `eval "flags=($(sed 's/#.*//' "$1" | tr '\\n' ' '))"; printf '%s\\n' "\${flags[@]}"`, "-", file], { encoding: "utf8" }).stdout.trim().split("\n");

const FLAGS = `# tau serve's options. Restart after a change:
--host 0.0.0.0 --token-file /x/token   # my token
--data /old/dir --model anthropic/claude
--data=/older "--command-scopes" --command-slice x.slice
--command-scopes
# --data /commented/out
--apns-key '/a b/key.p8'
`;

test("setup replaces only the options it manages in the flags, every occurrence, and keeps the other words, lines and comments", () => {
	const file = join(dir, "flags");
	writeFileSync(file, FLAGS);
	assert.equal(tau("_edit-flags", file, "-v", "--data", "--", "--data", "/var/tmp/me/my tau").status, 0);
	assert.equal(
		readFileSync(file, "utf8"),
		`# tau serve's options. Restart after a change:
--host 0.0.0.0 --token-file /x/token   # my token
--model anthropic/claude
"--command-scopes" --command-slice x.slice
--command-scopes
# --data /commented/out
--apns-key '/a b/key.p8'
--data '/var/tmp/me/my tau'
`,
	);
	tau("_edit-flags", file, "-b", "--command-scopes", "-v", "--command-slice", "--", "--command-scopes");
	// Again: the same file, not a second occurrence.
	tau("_edit-flags", file, "-b", "--command-scopes", "-v", "--command-slice", "--", "--command-scopes");
	assert.deepEqual(words(file), ["--host", "0.0.0.0", "--token-file", "/x/token", "--model", "anthropic/claude", "--apns-key", "/a b/key.p8", "--data", "/var/tmp/me/my tau", "--command-scopes"]);
	assert.match(readFileSync(file, "utf8"), /# my token\n.*\n# --data \/commented\/out\n/);
	// Taken out.
	tau("_edit-flags", file, "-b", "--command-scopes", "-v", "--command-slice");
	assert.ok(!words(file).includes("--command-scopes"));
});

test("--command-memory sets MemoryMax= in the slice, the rest of the file kept; sizes are checked", () => {
	const slice = join(dir, "tau-cmd.slice");
	const text = "# Comments.\n[Slice]\n# The pool.\nMemoryMax=27864M\n# Swap.\nMemorySwapMax=0\n";
	writeFileSync(slice, text);
	assert.equal(tau("_set-command-memory", slice, "32G").status, 0);
	assert.equal(readFileSync(slice, "utf8"), "# Comments.\n[Slice]\n# The pool.\n# Set by tau setup --command-memory 32G.\nMemoryMax=32G\n# Swap.\nMemorySwapMax=0\n");
	tau("_set-command-memory", slice, "80%");
	assert.equal(readFileSync(slice, "utf8"), "# Comments.\n[Slice]\n# The pool.\n# Set by tau setup --command-memory 80%.\nMemoryMax=80%\n# Swap.\nMemorySwapMax=0\n");
	for (const bad of ["12X", "0G", "-1G", "200%", "32 G", "1e9"]) assert.notEqual(tau("_set-command-memory", slice, bad).status, 0, bad);
	assert.match(readFileSync(slice, "utf8"), /^MemoryMax=80%$/m);
	for (const good of ["24000M", "1.5G", "infinity", "1073741824"]) assert.equal(tau("_set-command-memory", slice, good).status, 0, good);
});

test("setup's options: unknown ones and bad sizes refused before anything is done", () => {
	const unknown = tau("setup", "--frob");
	assert.notEqual(unknown.status, 0);
	assert.match(unknown.stderr, /unknown option --frob/);
	assert.match(unknown.stderr, /--command-memory SIZE/);
	assert.match(tau("setup", "--command-memory", "lots").stderr, /--command-memory lots: give bytes/);
	assert.match(tau("setup", "--help").stderr, /--data DIR/);
});
