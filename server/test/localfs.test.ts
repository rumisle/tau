import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { networkFilesystem, storageRefusal } from "../src/localfs.ts";

const MAIN = join(import.meta.dirname, "..", "src", "main.ts");
const linux = { platform: "linux" as const };
const MOUNTS = [
	"22 1 0:21 / / rw,relatime shared:1 - btrfs /dev/nvme0n1p3 rw",
	"40 22 0:50 / /home/shared rw,relatime shared:20 - fuse.glusterfs gluster:/vol rw",
	"41 22 0:51 / /home/my\\040files rw,relatime shared:21 - fuse.gocryptfs /dev/fuse rw",
	"42 40 0:52 / /home/shared/local rw,relatime shared:22 - fuse.rclone remote: rw",
].join("\n");

test("network filesystems by statfs magic, FUSE ones by their subtype; local and other systems pass", () => {
	assert.equal(networkFilesystem("/home/u", { ...linux, statfsType: () => 0x6969 }), "nfs");
	assert.equal(networkFilesystem("/home/u", { ...linux, statfsType: () => 0xff534d42 }), "cifs");
	// node may hand a magic past 2^31 back negative.
	assert.equal(networkFilesystem("/home/u", { ...linux, statfsType: () => 0xff534d42 | 0 }), "cifs");
	assert.equal(networkFilesystem("/home/u", { ...linux, statfsType: () => 0x00c36400 }), "ceph");
	assert.equal(networkFilesystem("/home/u", { ...linux, statfsType: () => 0x9123683e }), undefined); // btrfs
	assert.equal(networkFilesystem("/tmp", { ...linux, statfsType: () => 0x01021994 }), undefined); // tmpfs
	const fuse = (path: string) => networkFilesystem(path, { ...linux, statfsType: () => 0x65735546, mountinfo: () => MOUNTS });
	assert.equal(fuse("/home/shared/tau"), "fuse.glusterfs");
	assert.equal(fuse("/home/shared/local/tau"), "fuse.rclone");
	assert.equal(fuse("/home/my files/tau"), undefined); // gocryptfs: local
	assert.equal(fuse("/home/sharedx"), undefined);
	// Not Linux: macOS's f_type is an index (26 for every APFS volume), nothing is checked.
	assert.equal(networkFilesystem("/Users/u", { platform: "darwin", statfsType: () => 0x6969 }), undefined);
});

test("a directory still to be made is judged by the nearest one that exists", () => {
	const seen: string[] = [];
	const statfsType = (path: string) => {
		seen.push(path);
		if (path !== "/home") throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
		return 0x6969;
	};
	assert.equal(networkFilesystem("/home/u/.local/share/tau", { ...linux, statfsType }), "nfs");
	assert.deepEqual(seen.slice(0, 4), ["/home/u/.local/share/tau", "/home/u/.local/share", "/home/u/.local", "/home/u"]);
});

test("the refusal says the facts and what to give", () => {
	const message = storageRefusal("/home/u/.local/share/tau", "--data", { ...linux, statfsType: () => 0x6969 });
	assert.match(message!, /^\/home\/u\/\.local\/share\/tau is on nfs\. SQLite's WAL needs every user of the database on one host, which a network filesystem does not give \(https:\/\/sqlite\.org\/wal\.html\)\. Give --data a local directory, such as \/var\/tmp\/[^/]+\/tau\.$/);
	assert.match(storageRefusal("/n", "--db", { ...linux, statfsType: () => 0x6969 })!, /Give --db a file in a local directory/);
	assert.equal(storageRefusal("/x", "--data", { ...linux, statfsType: () => 0xef53 }), undefined);
});

test("the server refuses to start on a network filesystem, before it makes anything; --check-data says the same", { skip: process.platform === "linux" ? false : "Linux only" }, () => {
	const dir = mkdtempSync(join(tmpdir(), "tau-localfs-"));
	try {
		const data = join(dir, "data");
		const env = { ...process.env, TAU_STATFS_TYPE: String(0x6969) };
		const started = spawnSync(process.execPath, ["--no-warnings", MAIN, "--data", data, "--port", "0"], { env, encoding: "utf8", timeout: 30_000 });
		assert.equal(started.status, 2);
		assert.match(started.stderr, new RegExp(`^${data} is on nfs\\. SQLite's WAL`));
		assert.equal(existsSync(data), false);
		const db = spawnSync(process.execPath, ["--no-warnings", MAIN, "--db", join(dir, "x", "t.db"), "--check-data"], { env, encoding: "utf8", timeout: 30_000 });
		assert.equal(db.status, 2);
		assert.equal(db.stdout.trim(), join(dir, "x", "t.db"));
		assert.match(db.stderr, /x is on nfs\..*Give --db a file/);
		// Local: the path, nothing made.
		const local = spawnSync(process.execPath, ["--no-warnings", MAIN, "--data", data, "--check-data"], { encoding: "utf8", timeout: 30_000 });
		assert.equal(local.status, 0);
		assert.equal(local.stdout.trim(), join(data, "tau.db"));
		assert.equal(existsSync(data), false);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
