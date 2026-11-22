import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, truncateSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs, targetUrl, newAssetUrl, isLoginPath, isSsoPath, isGithubOrigin, readCache, cacheLine, appendCache, checkFile, UsageError } from "./lib.mjs";
import { ProfileLock, isStaleLock } from "./lock.mjs";

const A = "https://github.com/user-attachments/assets/11111111-2222-3333-4444-555555555555";
const B = "https://github.com/user-attachments/assets/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

test("parseArgs: pr form", () => {
	const { opt, files } = parseArgs(["--repo", "o/r", "--pr", "7", "a.png", "b.png"]);
	assert.deepEqual(opt, { repo: "o/r", pr: "7" });
	assert.deepEqual(files, ["a.png", "b.png"]);
});

test("parseArgs: compare form with cache and deadline", () => {
	const { opt } = parseArgs(["--repo", "o/r", "--base", "develop", "--branch", "feat/x", "--cache", "c.md", "--deadline", "90", "a.png"]);
	assert.equal(opt.branch, "feat/x");
	assert.equal(opt.deadline, "90");
});

test("parseArgs: --login alone", () => {
	assert.deepEqual(parseArgs(["--login"]), { opt: { login: true }, files: [] });
});

test("parseArgs: rejects bad input", () => {
	const bad = [
		["--repo", "o/r", "--pr", "7", "--nope", "a.png"],
		["--repo", "o/r", "--pr"],
		["--repo", "--pr", "7", "a.png"],
		["--repo", "no-slash", "--pr", "7", "a.png"],
		["--repo", "o/r", "--pr", "7x", "a.png"],
		["--repo", "o/r", "--pr", "7"],
		["--repo", "o/r", "a.png"],
	];
	for (const argv of bad) assert.throws(() => parseArgs(argv), UsageError, argv.join(" "));
});

test("parseArgs: -- ends the flags", () => {
	const { files } = parseArgs(["--repo", "o/r", "--pr", "7", "--", "--odd.png"]);
	assert.deepEqual(files, ["--odd.png"]);
});

test("targetUrl keeps / in base and branch", () => {
	assert.equal(targetUrl({ repo: "o/r", pr: "7" }), "https://github.com/o/r/pull/7");
	assert.equal(
		targetUrl({ repo: "o/r", base: "develop", branch: "feat/a b" }),
		"https://github.com/o/r/compare/develop...feat/a%20b?expand=1",
	);
});

test("newAssetUrl", () => {
	assert.equal(newAssetUrl("", `![x](${A})`), A);
	assert.equal(newAssetUrl("", `<img width="1" src="${A}">`), A);
	assert.equal(newAssetUrl(`![x](${A})`, `![x](${A})\n![y](${B})`), B);
	assert.equal(newAssetUrl(`![x](${A})`, `![x](${A})`), null);
	assert.equal(newAssetUrl("", "![Uploading x.png…]()"), null);
	const f = "https://github.com/user-attachments/files/123/my.pdf";
	assert.equal(newAssetUrl("", `[my.pdf](${f})`), f);
});

test("isLoginPath and isSsoPath", () => {
	assert.equal(isLoginPath("/login"), true);
	assert.equal(isLoginPath("/login/oauth"), true);
	assert.equal(isLoginPath("/session"), true);
	assert.equal(isLoginPath("/sessions/two-factor"), true);
	assert.equal(isLoginPath("/owner/login-service"), false);
	assert.equal(isSsoPath("/orgs/acme/sso"), true);
	assert.equal(isSsoPath("/acme/sso"), false);
});

test("cache round trip", () => {
	const dir = mkdtempSync(join(tmpdir(), "ghu-"));
	const path = join(dir, "uploads.md");
	const sha = "a".repeat(64);
	writeFileSync(path, `garbage line\n${cacheLine(sha, A, "/tmp/with space/a.png")}not a sha ${B} x\n`);
	const cache = readCache(path);
	assert.equal(cache.size, 1);
	assert.equal(cache.get(sha), A);
	assert.equal(readCache(join(dir, "missing")).size, 0);
});

test("checkFile", () => {
	const dir = mkdtempSync(join(tmpdir(), "ghu-"));
	const ok = join(dir, "a.png");
	writeFileSync(ok, "x");
	assert.doesNotThrow(() => checkFile(ok));
	const txt = join(dir, "a.txt");
	writeFileSync(txt, "x");
	assert.throws(() => checkFile(txt), /a\.txt/);
	const big = join(dir, "big.png");
	writeFileSync(big, "");
	truncateSync(big, 10 * 1024 * 1024 + 1);
	assert.throws(() => checkFile(big), /big\.png/);
	assert.throws(() => checkFile(join(dir, "none.png")), /none\.png/);
});

test("checkFile: a directory named like an image is not a regular file", () => {
	const dir = mkdtempSync(join(tmpdir(), "ghu-"));
	const fake = join(dir, "x.png");
	mkdirSync(fake);
	assert.throws(() => checkFile(fake), /not a regular file/);
});

test("readCache: ignores a last line without a newline", () => {
	const dir = mkdtempSync(join(tmpdir(), "ghu-"));
	const path = join(dir, "uploads.md");
	writeFileSync(path, cacheLine("a".repeat(64), A, "a.png") + cacheLine("b".repeat(64), B, "b.png").trimEnd());
	const cache = readCache(path);
	assert.equal(cache.size, 1);
	assert.equal(cache.has("b".repeat(64)), false);
});

test("readCache: ignores a hit whose URL is not an asset URL", () => {
	const dir = mkdtempSync(join(tmpdir(), "ghu-"));
	const path = join(dir, "uploads.md");
	writeFileSync(path, cacheLine("a".repeat(64), "https://evil.example/x.png", "a.png") + cacheLine("b".repeat(64), B, "b.png"));
	const cache = readCache(path);
	assert.equal(cache.has("a".repeat(64)), false);
	assert.equal(cache.get("b".repeat(64)), B);
});

test("readCache: a directory as cache is a usage error", () => {
	assert.throws(() => readCache(mkdtempSync(join(tmpdir(), "ghu-"))), UsageError);
});

test("appendCache: adds a leading newline after a cut-short line", () => {
	const dir = mkdtempSync(join(tmpdir(), "ghu-"));
	const path = join(dir, "uploads.md");
	writeFileSync(path, "partial line");
	appendCache(path, "c".repeat(64), A, "c.png");
	assert.equal(readFileSync(path, "utf8"), `partial line\n${cacheLine("c".repeat(64), A, "c.png")}`);
	assert.equal(readCache(path).get("c".repeat(64)), A);
	appendCache(path, "d".repeat(64), B, "d.png");
	assert.equal(readCache(path).size, 2);
});

test("parseArgs: --login rejects files", () => {
	assert.throws(() => parseArgs(["--login", "a.png"]), UsageError);
});

test("parseArgs: --terminal and --login-wait with --login", () => {
	const { opt } = parseArgs(["--login", "--terminal", "--login-wait", "900"]);
	assert.equal(opt.terminal, true);
	assert.equal(opt["login-wait"], "900");
});

test("parseArgs: --terminal without --login is rejected", () => {
	assert.throws(() => parseArgs(["--terminal", "--repo", "a/b", "--pr", "1", "x.png"]), UsageError);
});

test("parseArgs: --login-wait cap and scope", () => {
	assert.throws(() => parseArgs(["--login", "--terminal", "--login-wait", "901"]), UsageError);
	assert.throws(() => parseArgs(["--login", "--terminal", "--login-wait", "0"]), UsageError);
	assert.throws(() => parseArgs(["--login", "--terminal", "--login-wait", "x"]), UsageError);
	assert.throws(() => parseArgs(["--login", "--login-wait", "60"]), UsageError);
	assert.throws(() => parseArgs(["--login-wait", "60", "--repo", "a/b", "--pr", "1", "x.png"]), UsageError);
});

test("isStaleLock", () => {
	const alive = () => true;
	assert.equal(isStaleLock("abc", 0, alive), true);
	assert.equal(isStaleLock("1", 0, alive), true);
	assert.equal(isStaleLock("4242", 16 * 60_000, alive), true);
	assert.equal(isStaleLock("4242", 1000, () => false), true);
	assert.equal(isStaleLock("4242", 1000, alive), false);
});

test("parseArgs: --deadline is capped at 600", () => {
	const base = ["--repo", "o/r", "--pr", "7"];
	assert.equal(parseArgs([...base, "--deadline", "600", "a.png"]).opt.deadline, "600");
	assert.throws(() => parseArgs([...base, "--deadline", "601", "a.png"]), UsageError);
});

test("ProfileLock: create, busy, stale takeover, release", () => {
	const dir = mkdtempSync(join(tmpdir(), "lock-"));
	const first = new ProfileLock(dir);
	first.take();
	assert.equal(readFileSync(first.path, "utf8"), String(process.pid));
	assert.throws(() => new ProfileLock(dir).take(), /profile busy/);
	first.release();
	assert.equal(existsSync(first.path), false);
	writeFileSync(first.path, "999999999");
	const second = new ProfileLock(dir);
	second.take();
	assert.equal(readFileSync(second.path, "utf8"), String(process.pid));
	second.release();
	assert.deepEqual(readdirSync(dir), []);
});

test("isGithubOrigin: only https://github.com", () => {
	assert.equal(isGithubOrigin("https://github.com/login"), true);
	assert.equal(isGithubOrigin("https://github.com.evil.com/login"), false);
	assert.equal(isGithubOrigin("https://evil.com/github.com"), false);
	assert.equal(isGithubOrigin("http://github.com/login"), false);
	assert.equal(isGithubOrigin("garbage"), false);
});
