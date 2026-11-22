// Pure logic for upload.mjs. No playwright import, so selftest.mjs runs offline.
import { accessSync, appendFileSync, closeSync, constants, existsSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { extname } from "node:path";

export const USAGE =
	"usage: node upload.mjs --repo <owner/repo> (--pr <n> | --base <base> --branch <branch>) [--cache <file>] [--deadline <s>] <file>... | node upload.mjs --login [--terminal [--login-wait <s>]]";
export const MAX_BYTES = 10 * 1024 * 1024;
const EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp"]);
const MAX_DEADLINE_S = 600; // a run must end before the 15-minute stale-lock rule
const MAX_LOGIN_WAIT_S = 900;
const VALUE_FLAGS = new Set(["repo", "pr", "base", "branch", "cache", "deadline", "login-wait"]);
const ASSET =
	/https:\/\/(?:github\.com\/user-attachments\/(?:assets\/[0-9a-f-]{36}|files\/\d+\/[^\s)"'<>]+)|user-images\.githubusercontent\.com\/[^\s)"'<>]+)/g;

export class UsageError extends Error {}

// A failure in a named step. The phase shows in the ERRORS line.
export class PhaseError extends Error {
	constructor(phase, message) {
		super(message);
		this.phase = phase;
	}
}

const ASSET_EXACT = new RegExp(`^(?:${ASSET.source})$`);
// Sign-in input goes only to the real github.com origin (https, no look-alike host).
export function isGithubOrigin(url) {
	try {
		return new URL(url).origin === "https://github.com";
	} catch {
		return false;
	}
}

export const isAssetUrl = (url) => ASSET_EXACT.test(url);

export function parseArgs(argv) {
	const opt = {};
	const files = [];
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === "--") {
			files.push(...argv.slice(i + 1));
			break;
		}
		if (!a.startsWith("--")) {
			files.push(a);
			continue;
		}
		const name = a.slice(2);
		if (name === "login" || name === "terminal") opt[name] = true;
		else if (VALUE_FLAGS.has(name)) opt[name] = takeValue(argv[++i], a);
		else throw new UsageError(`unknown flag ${a}`);
	}
	validate(opt, files);
	return { opt, files };
}

function takeValue(value, flag) {
	if (value === undefined || value.startsWith("--")) throw new UsageError(`missing value for ${flag}`);
	return value;
}

// --terminal and --login-wait belong to the terminal sign-in only.
function validateLogin(opt, files) {
	if (files.length) throw new UsageError("--login takes no files");
	const wait = opt["login-wait"];
	if (wait === undefined) return;
	if (!opt.terminal) throw new UsageError("--login-wait needs --terminal");
	if (!/^\d+$/.test(wait) || Number(wait) < 1) throw new UsageError(`bad --login-wait ${wait}`);
	if (Number(wait) > MAX_LOGIN_WAIT_S) throw new UsageError(`--login-wait above ${MAX_LOGIN_WAIT_S}`);
}

function validate(opt, files) {
	if (opt.login) return validateLogin(opt, files);
	if (opt.terminal) throw new UsageError("--terminal works only with --login");
	if (opt["login-wait"] !== undefined) throw new UsageError("--login-wait works only with --login --terminal");
	if (!opt.repo) throw new UsageError(USAGE);
	if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(opt.repo)) throw new UsageError(`bad --repo ${opt.repo}`);
	if (opt.pr !== undefined && !/^\d+$/.test(opt.pr)) throw new UsageError(`bad --pr ${opt.pr}`);
	if (!opt.pr && !(opt.base && opt.branch)) throw new UsageError(USAGE);
	if (opt.deadline !== undefined && !/^\d+$/.test(opt.deadline)) throw new UsageError(`bad --deadline ${opt.deadline}`);
	if (opt.deadline !== undefined && Number(opt.deadline) > MAX_DEADLINE_S) throw new UsageError(`--deadline above ${MAX_DEADLINE_S}`);
	if (!files.length) throw new UsageError(USAGE);
}

const encodePath = (s) => s.split("/").map(encodeURIComponent).join("/");

export function targetUrl(opt) {
	const root = `https://github.com/${opt.repo}`;
	if (opt.pr) return `${root}/pull/${opt.pr}`;
	return `${root}/compare/${encodePath(opt.base)}...${encodePath(opt.branch)}?expand=1`;
}

export function newAssetUrl(beforeText, afterText) {
	const before = new Set(beforeText.match(ASSET) || []);
	return (afterText.match(ASSET) || []).find((u) => !before.has(u)) || null;
}

export const isLoginPath = (pathname) => /^\/(login|session|sessions)(\/|$)/.test(pathname);

export const isSsoPath = (pathname) => /^\/orgs\/[^/]+\/sso/.test(pathname);

export function checkFile(path) {
	if (!existsSync(path)) throw new UsageError(`file not found: ${path}`);
	if (!statSync(path).isFile()) throw new UsageError(`not a regular file: ${path}`);
	if (!EXTENSIONS.has(extname(path).toLowerCase())) throw new UsageError(`not an image (png, jpg, jpeg, gif, webp): ${path}`);
	if (statSync(path).size > MAX_BYTES) throw new UsageError(`file larger than 10 MB: ${path}`);
}

export const sha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

// Cache file: one line per upload, "<sha256> <url> <file>". Lines that do not parse are ignored,
// and so is a last line without a newline (a write that was cut short).
// A cache that exists but cannot be read is a usage error.
export function readCache(path) {
	const map = new Map();
	if (!path || !existsSync(path)) return map;
	let text;
	try {
		if (!statSync(path).isFile()) throw new Error("not a regular file");
		accessSync(path, constants.R_OK);
		text = readFileSync(path, "utf8");
	} catch (e) {
		throw new UsageError(`cache not readable: ${path} (${oneLine(e.message)})`);
	}
	for (const line of text.split("\n").slice(0, -1)) {
		const m = /^([0-9a-f]{64}) (https:\/\/\S+) (.+)$/.exec(line);
		if (m && isAssetUrl(m[2])) map.set(m[1], m[2]);
	}
	return map;
}

export const cacheLine = (sha, url, file) => `${sha} ${url} ${file}\n`;

// A cut-short last line must not swallow the new one.
function lacksFinalNewline(path) {
	if (!existsSync(path)) return false;
	const size = statSync(path).size;
	if (!size) return false;
	const fd = openSync(path, "r");
	try {
		const last = Buffer.alloc(1);
		readSync(fd, last, 0, 1, size - 1);
		return last[0] !== 10;
	} finally {
		closeSync(fd);
	}
}

export function appendCache(path, sha, url, file) {
	appendFileSync(path, (lacksFinalNewline(path) ? "\n" : "") + cacheLine(sha, url, file));
}

export const oneLine = (s) => String(s).replace(/\s+/g, " ").trim();
