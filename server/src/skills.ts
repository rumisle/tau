// Skills (https://agentskills.io): folders with a SKILL.md whose front matter names the skill and says when to use it.
// The system prompt lists them, and the model reads a skill's file with the read tool when a task matches, as pi's
// coding agent does (packages/coding-agent/src/core/skills.ts, whose discovery and prompt this follows). tau looks in
// `.agents/skills` only: the user's (~/.agents/skills) and the conversation's directory's.
//
// The list is a prompt section, rendered at each request. Durable compares it with what the transcript already shows
// and appends a system delta only when it changed, so the render must give the same text for the same skills: skills are
// sorted, nothing time-dependent is in it, and a skill that cannot be read is left out rather than shown with an error.
// A skill added, changed or removed appears at the next request, as one delta; the prompt before it stays cached.
import { readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { type PromptSection, section } from "@earendil-works/pi-durable";
import { parse } from "yaml";

export type Skill = { name: string; description: string; filePath: string };

const MAX_DESCRIPTION_LENGTH = 1024;
/** Directory levels below a skills root that are searched for SKILL.md. */
const MAX_DEPTH = 4;

/** Parsed front matter per file, kept while the file's size and modification time stay the same. */
const parsed = new Map<string, { size: number; mtimeMs: number; skill: Skill | undefined }>();

/**
 * The skills in `~/.agents/skills` and `<cwd>/.agents/skills`, in that order of precedence for a name both have, then
 * sorted by name. A file reached twice (a symbolic link) counts once.
 */
export function loadSkills(cwd: string | undefined, home = homedir()): Skill[] {
	const roots = [join(home, ".agents", "skills")];
	if (cwd !== undefined) {
		const project = resolve(cwd, ".agents", "skills");
		if (project !== roots[0]) roots.push(project);
	}
	const byName = new Map<string, Skill>();
	const seen = new Set<string>();
	for (const root of roots) {
		for (const file of skillFiles(root, 0)) {
			let real: string;
			try {
				real = realpathSync(file);
			} catch {
				continue;
			}
			if (seen.has(real)) continue;
			seen.add(real);
			const skill = readSkill(file);
			if (skill !== undefined && !byName.has(skill.name)) byName.set(skill.name, skill);
		}
	}
	return [...byName.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

/** SKILL.md files under `dir`: a directory that has one is a skill and is not searched further. */
function skillFiles(dir: string, depth: number): string[] {
	let entries: string[];
	try {
		entries = readdirSync(dir).sort();
	} catch {
		return [];
	}
	if (entries.includes("SKILL.md") && isFile(join(dir, "SKILL.md"))) return [join(dir, "SKILL.md")];
	if (depth >= MAX_DEPTH) return [];
	const files: string[] = [];
	for (const name of entries) {
		if (name.startsWith(".") || name === "node_modules") continue;
		const path = join(dir, name);
		if (isDirectory(path)) files.push(...skillFiles(path, depth + 1));
	}
	return files;
}

function readSkill(file: string): Skill | undefined {
	let stats: { size: number; mtimeMs: number };
	try {
		stats = statSync(file);
	} catch {
		return undefined;
	}
	const cached = parsed.get(file);
	if (cached !== undefined && cached.size === stats.size && cached.mtimeMs === stats.mtimeMs) return cached.skill;
	let skill: Skill | undefined;
	try {
		skill = parseSkill(readFileSync(file, "utf8"), file);
	} catch {
		skill = undefined;
	}
	parsed.set(file, { size: stats.size, mtimeMs: stats.mtimeMs, skill });
	return skill;
}

/** A skill from its SKILL.md: front matter `name` (default: its directory's name) and a `description`, which it needs. */
export function parseSkill(content: string, filePath: string): Skill | undefined {
	const text = content.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
	if (!text.startsWith("---")) return undefined;
	const end = text.indexOf("\n---", 3);
	if (end === -1) return undefined;
	const front = frontMatter(text.slice(4, end));
	if (front === undefined) return undefined;
	if (front["disable-model-invocation"] === true) return undefined;
	const description = typeof front.description === "string" ? front.description.trim() : "";
	if (description === "" || description.length > MAX_DESCRIPTION_LENGTH) return undefined;
	const name = typeof front.name === "string" && front.name.trim() !== "" ? front.name.trim() : basename(dirname(filePath));
	return { name, description, filePath };
}

/**
 * The front matter as YAML; failing that, as `key: value` lines. Hand-written descriptions often have a colon and a
 * space in them, which plain YAML takes for a mapping and rejects (pi then leaves the skill out).
 */
function frontMatter(yaml: string): Record<string, unknown> | undefined {
	try {
		const parsed = parse(yaml) as unknown;
		if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
	} catch {}
	const fields: Record<string, unknown> = {};
	for (const line of yaml.split("\n")) {
		const match = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line);
		if (match === null) continue;
		const value = match[2]!.trim();
		fields[match[1]!] = value === "true" ? true : value === "false" ? false : value.replace(/^(["'])(.*)\1$/, "$2");
	}
	return Object.keys(fields).length === 0 ? undefined : fields;
}

/** pi's `formatSkillsForPrompt`, for the read tool. Undefined without skills, which removes the section. */
export function formatSkills(skills: readonly Skill[]): string | undefined {
	if (skills.length === 0) return undefined;
	const lines = [
		"The following skills provide specialized instructions for specific tasks.",
		"Use the read tool to load a skill's file when the task matches its description.",
		"When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
		"",
		"<available_skills>",
	];
	for (const skill of skills) {
		lines.push("  <skill>", `    <name>${escapeXml(skill.name)}</name>`, `    <description>${escapeXml(skill.description)}</description>`, `    <location>${escapeXml(skill.filePath)}</location>`, "  </skill>");
	}
	lines.push("</available_skills>");
	return lines.join("\n");
}

/** The section: the skills of the conversation's directory. Its own tags, as pi's prompt has them. */
export function skillsSection(home?: string): PromptSection {
	return section("skills", (input) => formatSkills(loadSkills(input.env?.cwd, home)), { tag: false });
}

function escapeXml(text: string): string {
	return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

function isFile(path: string): boolean {
	try {
		return statSync(path).isFile();
	} catch {
		return false;
	}
}

function isDirectory(path: string): boolean {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}
