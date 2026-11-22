// Upload local images to GitHub as PR attachments and print their URLs, so a PR description
// can embed them inline. Nothing is committed: the files go to GitHub's attachment store
// (https://github.com/user-attachments/assets/...), the same place a drag-and-drop puts them.
//
//   node upload.mjs --repo <owner/repo> (--pr <n> | --base <base> --branch <branch>)
//                   [--cache <file>] [--deadline <seconds>] <file>...
//   node upload.mjs --login        (the OWNER runs this once to sign in; an agent never does)
//   node upload.mjs --login --terminal [--login-wait <seconds>]
//                   headless server: the OWNER types the user name, password and 2FA code in the terminal
//
// It opens real Google Chrome (Playwright, headed) with its own profile folder, drops the files
// into the PR's markdown box, reads the URLs GitHub writes back, restores the box and leaves.
// It never clicks a submit button and it never waits for a human, except in --login mode.
//
// Output lines (the URL is always the LAST token of a URL line, because paths can hold spaces):
//   URL <file> <url>      the file is uploaded (or found in --cache)
//   FAIL <file> <reason>  the file has no URL
//   LOGIN ...             the profile is not signed in (exit 4); in --terminal mode also a status line
//   LOGIN-OK <user>       --login finished
//   ERRORS <phase> <msg>  one line; phase: usage setup launch login goto find-box find-input upload
//   INFO ...              evidence after a failure (page title, final URL, screenshot path),
//                         or "cache not written" (the run goes on; the cache is only a shortcut)
//   DONE <ok>/<total>     always the last stdout line of an upload run, on every exit path.
//                         Once files are known, each file has exactly one URL or FAIL line.
// Exit codes: 0 every file has a URL, 1 some file FAILed, 2 usage, 3 setup, launch or goto, 4 login.
import { mkdirSync } from "node:fs";
import { homedir, hostname, userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PhaseError, UsageError, appendCache, checkFile, isGithubOrigin, isLoginPath, isSsoPath, newAssetUrl, oneLine, parseArgs, readCache, sha256, targetUrl } from "./lib.mjs";
import { ProfileLock } from "./lock.mjs";
import { TerminalLogin } from "./terminal-login.mjs";
import { TtyPrompt } from "./tty-prompt.mjs";

const SELF = fileURLToPath(import.meta.url);
const PROFILE = process.env.GH_UPLOAD_PROFILE || join(homedir(), ".claude", "gh-upload-profile");
const FILE_TIMEOUT_MS = 60_000;
const LOGIN_WAIT_S = 300;
const HARD_STOP_MS = 20_000; // longer than the cleanup timeouts together (3 + 5 + 5 s)
const BOX_SELECTORS = ['textarea[name="pull_request[body]"]', 'textarea[name="comment[body]"]', "#new_comment_field"];
const EXIT_BY_PHASE = { setup: 3, launch: 3, goto: 3, login: 4 };

// Set by die(). Once set, nothing else prints or exits: die() owns the last lines.
let shuttingDown = false;
let active = null;

function withTimeout(promise, ms) {
	let timer;
	const timeout = new Promise((done) => (timer = setTimeout(done, ms)));
	return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// A cleanup that hangs must not hold the process forever.
function armHardStop(getCode) {
	setTimeout(() => process.exit(getCode()), HARD_STOP_MS).unref();
}

class Uploader {
	// No I/O here: everything that can throw runs inside run() or loginMode().
	constructor(opt, files, cache = new Map()) {
		this.opt = opt;
		this.files = files;
		this.cache = cache;
		this.unresolved = new Set(files);
		this.ok = 0;
		this.exitCode = 0;
		this.lock = new ProfileLock(PROFILE);
		this.ctx = null;
		this.page = null;
		this.box = null;
		this.original = null;
		this.cacheOk = Boolean(opt.cache);
		this.evidenced = false;
		this.doneLogged = false;
		this.cleaning = null;
		this.deadlineAt = Date.now() + Number(opt.deadline || 240) * 1000;
	}

	// Entry point of an upload run. Returns the exit code.
	async run() {
		try {
			const pending = this.serveFromCache();
			if (pending.length) await this.uploadPending(pending);
		} catch (e) {
			await this.reportError(e);
		}
		// Print the last lines first: the hard stop can then never cut them off.
		if (!shuttingDown) {
			this.failUnresolved("stopped before an upload result");
			this.printDone();
		}
		await this.cleanup();
		return shuttingDown ? 0 : this.currentCode();
	}

	currentCode() {
		return this.exitCode || (this.ok === this.files.length ? 0 : 1);
	}

	// Files with the same content upload once; every listed path gets the URL.
	serveFromCache() {
		const groups = new Map();
		for (const file of this.files) {
			const sha = sha256(file);
			const url = this.cache.get(sha);
			if (url) this.succeed(file, url);
			else if (groups.has(sha)) groups.get(sha).files.push(file);
			else groups.set(sha, { sha, files: [file] });
		}
		return [...groups.values()];
	}

	async uploadPending(pending) {
		this.prepareCache();
		const playwright = await loadPlaywright();
		await this.open(playwright);
		await this.ensureSignedIn();
		await this.goto(targetUrl(this.opt));
		await this.findBox();
		const input = await this.findInput();
		await this.uploadAll(pending, input);
	}

	async open(playwright) {
		if (!this.opt.terminal && process.platform === "linux" && !process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) {
			throw new PhaseError("launch", "no display (run under xvfb-run, or from a desktop session)");
		}
		this.lock.take();
		try {
			// Our own guards handle the signals, so Playwright must not exit first.
			this.ctx = await playwright.chromium.launchPersistentContext(PROFILE, {
				channel: "chrome",
				headless: Boolean(this.opt.terminal), // --terminal runs on a server with no screen
				viewport: { width: 1280, height: 900 },
				handleSIGINT: false,
				handleSIGTERM: false,
				handleSIGHUP: false,
			});
		} catch (e) {
			throw new PhaseError("launch", oneLine(e.message.split("\n")[0]));
		}
		this.page = this.ctx.pages()[0] || (await this.ctx.newPage());
		// Accept only "leave site?"; dismiss every other dialog.
		this.page.on("dialog", (d) => (d.type() === "beforeunload" ? d.accept() : d.dismiss()).catch(() => {}));
	}

	// Network, DNS and timeout errors are goto errors; so is an HTTP error status.
	async navigate(url) {
		let response;
		try {
			response = await this.page.goto(url, { waitUntil: "domcontentloaded" });
		} catch (e) {
			throw new PhaseError("goto", oneLine(e.message.split("\n")[0]));
		}
		if (response && response.status() >= 400) throw new PhaseError("goto", `HTTP ${response.status()} ${this.page.url()}`);
	}

	async signedInUser() {
		if (!isGithubOrigin(this.page.url())) return "";
		const { pathname } = new URL(this.page.url());
		if (isLoginPath(pathname) || isSsoPath(pathname)) return "";
		return (await this.page.locator('meta[name="user-login"]').getAttribute("content", { timeout: 3000 }).catch(() => "")) || "";
	}

	async ensureSignedIn() {
		await this.navigate("https://github.com/");
		if (await this.signedInUser()) return;
		this.say(`LOGIN not signed in: the owner runs once: node ${SELF} --login`);
		throw new PhaseError("login", "not signed in");
	}

	async goto(url) {
		await this.navigate(url);
		if (!(await this.signedInUser())) {
			this.say(`LOGIN not signed in (SSO or session ended): the owner runs once: node ${SELF} --login`);
			throw new PhaseError("login", `not signed in at ${this.page.url()}`);
		}
	}

	async findBox() {
		// One union locator, visible only: a hidden textarea must not burn the whole wait.
		const box = this.page.locator(BOX_SELECTORS.join(", ")).filter({ visible: true }).first();
		try {
			await box.waitFor({ timeout: 20_000 });
		} catch {
			throw new PhaseError("find-box", `no markdown box on ${this.page.url()} (is the branch pushed? is the PR open?)`);
		}
		this.box = box;
		this.original = await box.inputValue();
	}

	// The file input of the box: nearest form or file-attachment, else a few levels up.
	async findInput() {
		const found = await this.box.evaluate((ta) => {
			const scope = ta.closest("file-attachment") || ta.closest("form");
			let input = scope && scope.querySelector('input[type="file"]');
			for (let el = ta.parentElement, n = 0; !input && el && n < 6; el = el.parentElement, n++) input = el.querySelector('input[type="file"]');
			if (input) input.setAttribute("data-claude-upload", "1");
			return !!input;
		});
		if (!found) throw new PhaseError("find-input", "no file input next to the markdown box (GitHub markup changed?)");
		return this.page.locator('[data-claude-upload="1"]');
	}

	async uploadAll(pending, input) {
		let stop = null; // reason that skips every remaining file
		for (const group of pending) {
			if (!stop && Date.now() >= this.deadlineAt) stop = "skipped: deadline";
			if (stop) {
				this.failGroup(group, stop);
				continue;
			}
			const url = await this.uploadOne(group.files[0], input);
			if (url) {
				this.succeedGroup(group, url);
				continue;
			}
			const hitDeadline = Date.now() >= this.deadlineAt;
			const detail = await this.uploadErrorText();
			this.failGroup(group, hitDeadline ? "skipped: deadline" : `no attachment URL within 60s${detail}`);
			// A late URL of this file would be credited to the next one: stop here.
			stop = hitDeadline ? "skipped: deadline" : "skipped after an earlier failure";
			await this.evidenceOnce();
		}
	}

	async uploadOne(file, input) {
		const before = await this.box.inputValue();
		await input.setInputFiles(file);
		const until = Math.min(Date.now() + FILE_TIMEOUT_MS, this.deadlineAt);
		while (Date.now() < until) {
			await this.page.waitForTimeout(500);
			const url = newAssetUrl(before, await this.box.inputValue());
			if (url) return url;
		}
		return null;
	}

	async uploadErrorText() {
		const text = await this.page.locator('.flash-error:visible, [role="alert"]:visible').first().textContent({ timeout: 500 }).catch(() => "");
		return text && oneLine(text) ? `: ${oneLine(text).slice(0, 200)}` : "";
	}

	say(line) {
		if (!shuttingDown) console.log(line);
	}

	succeed(file, url) {
		if (shuttingDown) return;
		this.unresolved.delete(file);
		this.ok += 1;
		console.log(`URL ${file} ${url}`);
	}

	fail(file, reason) {
		if (shuttingDown) return;
		this.unresolved.delete(file);
		console.log(`FAIL ${file} ${reason}`);
	}

	succeedGroup(group, url) {
		for (const file of group.files) this.succeed(file, url);
		this.writeCache(group.sha, url, group.files[0]);
	}

	failGroup(group, reason) {
		for (const file of group.files) this.fail(file, reason);
	}

	failUnresolved(reason) {
		for (const file of [...this.unresolved]) this.fail(file, reason);
	}

	// The cache is a shortcut. A cache error never changes the exit code or stops the loop.
	prepareCache() {
		if (!this.opt.cache) return;
		try {
			mkdirSync(dirname(resolve(this.opt.cache)), { recursive: true });
		} catch (e) {
			this.cacheFailed(e);
		}
	}

	writeCache(sha, url, file) {
		if (!this.cacheOk) return;
		try {
			appendCache(this.opt.cache, sha, url, file);
		} catch (e) {
			this.cacheFailed(e);
		}
	}

	cacheFailed(e) {
		this.cacheOk = false;
		this.say(`INFO cache not written: ${oneLine(e.message)}`);
	}

	printDone() {
		if (!this.files.length || this.doneLogged) return;
		this.doneLogged = true;
		console.log(`DONE ${this.ok}/${this.files.length}`);
	}

	async reportError(e) {
		if (shuttingDown) return;
		console.error(e.stack);
		const phase = e.phase || "upload";
		this.say(`ERRORS ${phase} ${oneLine(e.message)}`);
		this.exitCode = EXIT_BY_PHASE[phase] || 0;
		if (this.page && !["setup", "launch"].includes(phase)) await this.evidenceOnce();
		this.failUnresolved(`stopped by ${phase} error`);
	}

	// Last lines on a signal or an internal error: a FAIL for each open file, then DONE.
	abort(message) {
		if (message && !this.doneLogged) console.log(`ERRORS internal ${oneLine(message)}`);
		for (const file of this.unresolved) console.log(`FAIL ${file} ${message ? "internal error" : "interrupted"}`);
		this.unresolved.clear();
		this.printDone();
	}

	async evidenceOnce() {
		if (this.evidenced || !this.page) return;
		this.evidenced = true;
		await this.evidence();
	}

	// The INFO line prints even when the screenshot fails.
	async evidence() {
		const page = this.page;
		const shot = join(PROFILE, "last-failure.png");
		let shotText = "";
		try {
			await page.screenshot({ path: shot, timeout: 5000 });
			shotText = `, screenshot ${shot}`;
		} catch {}
		const title = await withTimeout(page.title().catch(() => ""), 3000);
		this.say(`INFO page "${oneLine(title || "")}" at ${page.url()}${shotText}`);
	}

	// Best effort and idempotent. Cleanup errors never change the exit code.
	cleanup() {
		this.cleaning ||= this.doCleanup();
		return this.cleaning;
	}

	async doCleanup() {
		if (!shuttingDown) armHardStop(() => this.currentCode());
		const { box, page, ctx, original } = this;
		this.ctx = this.page = this.box = null;
		try {
			if (box && original !== null) await box.fill(original, { timeout: 3000 });
		} catch {}
		try {
			if (page) await page.goto("about:blank", { timeout: 5000 });
		} catch {}
		try {
			if (ctx) await withTimeout(ctx.close(), 5000);
		} catch {}
		this.lock.release();
	}
}

async function loadPlaywright() {
	try {
		return await import("playwright");
	} catch {
		const dir = dirname(SELF);
		throw new PhaseError("setup", `playwright not installed: run "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci" in ${dir}`);
	}
}

// --login: the owner signs in once; the session stays in the profile.
async function loginMode(up) {
	const waitS = Number(up.opt["login-wait"] || LOGIN_WAIT_S);
	try {
		await up.open(await loadPlaywright());
		await up.navigate("https://github.com/login");
		const user = up.opt.terminal ? await new TerminalLogin(up, new TtyPrompt(), waitS).run() : await waitForSignIn(up, waitS);
		up.say(`LOGIN-OK ${user}`);
		return 0;
	} catch (e) {
		if (!shuttingDown) {
			console.error(e.stack);
			console.log(`ERRORS ${e.phase || "internal"} ${oneLine(e.message)}`);
		}
		return e.phase ? EXIT_BY_PHASE[e.phase] || 4 : 1;
	} finally {
		await up.cleanup();
	}
}

// Visible Chrome: the owner signs in in the window.
async function waitForSignIn(up, waitS) {
	const until = Date.now() + waitS * 1000;
	let user = await up.signedInUser();
	while (!user && Date.now() < until) {
		await up.page.waitForTimeout(2000);
		user = await up.signedInUser();
	}
	if (!user) throw new PhaseError("login", "not signed in after 5 minutes");
	return user;
}

function usageExit(message) {
	console.log(`ERRORS usage ${oneLine(message)}`);
	process.exit(2);
}

// A signal ends the run with one protocol line. A terminal prompt may be open, so a
// newline comes first: the shell prompt must not land on the "Password:" line.
function announceSignal(signal) {
	if (active && active.opt.terminal) process.stdout.write("\n");
	console.log(`ERRORS ${active && active.opt.login ? "login" : "upload"} interrupted (${signal})`);
}

async function die(code, message, signal) {
	if (shuttingDown) return;
	shuttingDown = true;
	armHardStop(() => code);
	if (signal) announceSignal(signal);
	if (active) active.abort(message);
	else if (message) console.log(`ERRORS internal ${oneLine(message)}`);
	if (active) await active.cleanup();
	process.exit(code);
}

function installProcessGuards() {
	const crash = (e) => (console.error(e && e.stack), die(1, String((e && e.message) || e)));
	process.on("uncaughtException", crash);
	process.on("unhandledRejection", crash);
	process.on("SIGINT", () => die(130, undefined, "SIGINT"));
	process.on("SIGTERM", () => die(143, undefined, "SIGTERM"));
	process.on("SIGHUP", () => die(129, undefined, "SIGHUP"));
}

// The cache is checked first: a bad --cache is a usage error before any other work.
function parseInput() {
	try {
		const { opt, files } = parseArgs(process.argv.slice(2));
		if (opt.terminal && !process.stdin.isTTY) {
			console.log("ERRORS usage --terminal needs an interactive terminal");
			process.exit(2);
		}
		const cache = readCache(opt.cache);
		const paths = [...new Set(files.map((f) => resolve(f)))];
		for (const path of paths) checkFile(path);
		return { opt, cache, files: paths };
	} catch (e) {
		if (e instanceof UsageError) usageExit(e.message);
		throw e;
	}
}

async function main() {
	installProcessGuards();
	const { opt, cache, files } = parseInput();
	active = new Uploader(opt, files, cache);
	const code = opt.login ? await loginMode(active) : await active.run();
	if (!shuttingDown) process.exit(code);
}

await main();
