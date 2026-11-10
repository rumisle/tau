// Whether the server's data is on a network filesystem, where it must not be: SQLite's WAL keeps its index in shared
// memory beside the database (`-shm`), so every connection to the database has to be on one host
// (https://sqlite.org/wal.html), which a network filesystem does not give, and its locks are not to be trusted there.
// Linux only: statfs's f_type is the filesystem's magic number there; macOS gives an index into its own table instead
// (26 for every APFS volume on nest), and `local` mounts are the rule on a Mac, so nothing is checked.
import { readFileSync, statfsSync } from "node:fs";
import { dirname, resolve } from "node:path";

/** Network and cluster filesystems by their statfs magic (linux/magic.h and the filesystems' own sources). */
export const NETWORK_FILESYSTEMS: ReadonlyMap<number, string> = new Map([
	[0x6969, "nfs"],
	[0x517b, "smb"],
	[0xff534d42, "cifs"],
	[0xfe534d42, "smb2"],
	[0x00c36400, "ceph"],
	[0x0bd00bd0, "lustre"],
	[0x5346414f, "afs"],
	[0x6b414653, "afs"],
	[0x01021997, "9p"],
	[0x47504653, "gpfs"],
	[0x19830326, "beegfs"],
	[0x7461636f, "ocfs2"],
	[0x01161970, "gfs2"],
	[0x013111a8, "ibrix"],
	[0x564c, "ncp"],
	[0x73757245, "coda"],
	[0xaad7aaea, "panfs"],
	[0xbeefdead, "snfs"],
	[0x61636673, "acfs"],
]);

/**
 * FUSE filesystems that are network ones, by the subtype their mount names (`fuse.glusterfs`). FUSE as such is not
 * one: it may well be local.
 */
export const NETWORK_FUSE: ReadonlySet<string> = new Set(["glusterfs", "sshfs", "ceph", "ceph-fuse", "s3fs", "gcsfuse", "rclone", "juicefs", "lizardfs", "mfs", "moosefs", "beegfs", "cvmfs", "goofys"]);

const FUSE_MAGIC = 0x65735546;

export type FilesystemProbe = {
	/** statfs's f_type for a path (node's `statfsSync(path).type`). */
	statfsType?: (path: string) => number;
	/** /proc/self/mountinfo's text. */
	mountinfo?: () => string;
	platform?: NodeJS.Platform;
};

/** The nearest existing directory at or above `path`: what a directory to be made will be on. */
function existing(path: string, statfsType: (path: string) => number): string {
	for (let at = resolve(path); ; at = dirname(at)) {
		try {
			statfsType(at);
			return at;
		} catch (error) {
			if (at === dirname(at)) throw error;
		}
	}
}

/** The fstype of the mount `path` is on, from mountinfo: the longest mount point that contains it. */
function mountType(path: string, mountinfo: string): string | undefined {
	let best: { point: string; type: string } | undefined;
	for (const line of mountinfo.split("\n")) {
		const [fields, rest] = line.split(" - ");
		if (rest === undefined) continue;
		const point = fields!.split(" ")[4]?.replace(/\\([0-7]{3})/g, (_, octal: string) => String.fromCharCode(Number.parseInt(octal, 8)));
		const type = rest.split(" ")[0];
		if (point === undefined || type === undefined) continue;
		const inside = point === "/" || path === point || path.startsWith(`${point}/`);
		if (inside && (best === undefined || point.length >= best.point.length)) best = { point, type };
	}
	return best?.type;
}

/** The network filesystem `path` (or the directory it would be made in) is on, or undefined for a local one. */
export function networkFilesystem(path: string, probe: FilesystemProbe = {}): string | undefined {
	if ((probe.platform ?? process.platform) !== "linux") return undefined;
	// TAU_STATFS_TYPE=<magic>[:<dir>]: the magic every path (under dir) reads as, for tests (as TAU_BOOT_ID_PATH is).
	const forced = process.env.TAU_STATFS_TYPE?.split(/:(.*)/s);
	const statfsType =
		probe.statfsType ??
		((at: string) => {
			const type = statfsSync(at).type;
			if (forced === undefined) return type;
			const [magic, under] = forced;
			return under === undefined || under === "" || at === under || at.startsWith(`${under}/`) ? Number(magic) : type;
		});
	const at = existing(path, statfsType);
	const type = statfsType(at);
	const named = NETWORK_FILESYSTEMS.get(type >>> 0);
	if (named !== undefined) return named;
	if (type >>> 0 !== FUSE_MAGIC) return undefined;
	let info = "";
	try {
		info = probe.mountinfo?.() ?? readFileSync("/proc/self/mountinfo", "utf8");
	} catch {
		return undefined;
	}
	const subtype = /^fuse(?:blk)?\.(.+)$/.exec(mountType(at, info) ?? "")?.[1];
	return subtype !== undefined && NETWORK_FUSE.has(subtype) ? `fuse.${subtype}` : undefined;
}

/** Why the database cannot be in `dir`, as the server says it, or undefined when it can. `option` names the flag to change. */
export function storageRefusal(dir: string, option: "--data" | "--db", probe: FilesystemProbe = {}): string | undefined {
	const filesystem = networkFilesystem(dir, probe);
	if (filesystem === undefined) return undefined;
	const user = process.env.USER ?? process.env.LOGNAME ?? "you";
	const give = option === "--data" ? `Give --data a local directory, such as /var/tmp/${user}/tau.` : `Give --db a file in a local directory, such as /var/tmp/${user}/tau/tau.db.`;
	return `${dir} is on ${filesystem}. SQLite's WAL needs every user of the database on one host, which a network filesystem does not give (https://sqlite.org/wal.html). ${give}`;
}
