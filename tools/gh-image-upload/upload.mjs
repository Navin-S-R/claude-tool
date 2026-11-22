// Upload local images to GitHub as PR attachments and print their URLs, so a PR description
// can embed them inline. Nothing is committed: the files go to GitHub's attachment store
// (https://github.com/user-attachments/assets/...), the same place a drag-and-drop puts them.
//
//   node upload.mjs --repo <owner/repo> (--pr <n> | --base <base> --branch <branch>) <file>...
//
// It opens real Google Chrome (Playwright, headed) with its own profile folder, drops the files
// into the PR's markdown box, reads the URLs GitHub writes back, restores the box and leaves.
// It never clicks a submit button.
//
// First run: the profile is not signed in. The script prints LOGIN and waits up to 5 minutes for
// YOU to sign in to GitHub in the window. The session is kept in the profile for later runs.
//
// Output lines:  URL <file> <url>  |  FAIL <file> <reason>  |  LOGIN ...  |  ERRORS ...
// Exit code 0 only when every file got a URL.
import { chromium } from "playwright";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

const args = process.argv.slice(2);
const opt = {};
const files = [];
for (let i = 0; i < args.length; i++) {
	const a = args[i];
	if (a.startsWith("--")) opt[a.slice(2)] = args[++i];
	else files.push(resolve(a));
}
const usage = "usage: node upload.mjs --repo <owner/repo> (--pr <n> | --base <base> --branch <branch>) <file>...";
if (!opt.repo || (!opt.pr && !(opt.base && opt.branch)) || !files.length) {
	console.log(`ERRORS ${usage}`);
	process.exit(2);
}
for (const f of files) {
	if (!existsSync(f)) {
		console.log(`ERRORS file not found: ${f}`);
		process.exit(2);
	}
}

const target = opt.pr
	? `https://github.com/${opt.repo}/pull/${opt.pr}`
	: `https://github.com/${opt.repo}/compare/${encodeURIComponent(opt.base)}...${encodeURIComponent(opt.branch)}?expand=1`;
const profile = process.env.GH_UPLOAD_PROFILE || join(homedir(), ".claude", "gh-upload-profile");
const ASSET = /https:\/\/(?:github\.com\/user-attachments\/assets\/[0-9a-f-]{36}|user-images\.githubusercontent\.com\/[^\s)"'<>]+)/g;

const ctx = await chromium.launchPersistentContext(profile, { channel: "chrome", headless: false, viewport: { width: 1280, height: 900 } });
const page = ctx.pages()[0] || (await ctx.newPage());
page.on("dialog", (d) => d.accept().catch(() => {})); // "leave site?" after we restore the box

const signedIn = async () =>
	!page.url().includes("/login") && !!(await page.locator('meta[name="user-login"]').getAttribute("content").catch(() => ""));

let failed = 0;
try {
	await page.goto(target, { waitUntil: "domcontentloaded" });
	if (!(await signedIn())) {
		console.log("LOGIN sign in to GitHub in the Chrome window that opened (waiting up to 5 minutes)");
		if (!page.url().includes("/login")) await page.goto("https://github.com/login");
		const until = Date.now() + 5 * 60_000;
		while (!(await signedIn())) {
			if (Date.now() > until) throw new Error("not signed in after 5 minutes");
			await page.waitForTimeout(2000);
		}
		await page.goto(target, { waitUntil: "domcontentloaded" });
	}
	// The markdown box and the file input that belongs to it.
	const boxSelectors = ['textarea[name="pull_request[body]"]', 'textarea[name="comment[body]"]', "#new_comment_field"];
	// Give the page time to render the box. (An open PR for the branch makes the compare page
	// show a link instead of the form: pass --pr then.)
	await page.locator(boxSelectors.join(", ")).first().waitFor({ timeout: 20_000 }).catch(() => {});
	let box = null;
	for (const s of boxSelectors) {
		const l = page.locator(s).filter({ visible: true }).first();
		if (await l.count()) {
			box = l;
			break;
		}
	}
	if (!box) throw new Error(`no markdown box found on ${page.url()} (is the branch pushed? is the PR open?)`);
	const hasInput = await box.evaluate((ta) => {
		for (let el = ta.parentElement; el; el = el.parentElement) {
			const input = el.querySelector('input[type="file"]');
			if (input) {
				input.setAttribute("data-claude-upload", "1");
				return true;
			}
		}
		return false;
	});
	if (!hasInput) throw new Error("no file input next to the markdown box (GitHub markup changed?)");
	const input = page.locator('[data-claude-upload="1"]');
	const original = await box.inputValue();

	for (const f of files) {
		const before = new Set((await box.inputValue()).match(ASSET) || []);
		await input.setInputFiles(f);
		let url = null;
		const until = Date.now() + 60_000;
		while (!url && Date.now() < until) {
			await page.waitForTimeout(500);
			url = ((await box.inputValue()).match(ASSET) || []).find((u) => !before.has(u)) || null;
		}
		if (url) console.log(`URL ${f} ${url}`);
		else {
			failed += 1;
			console.log(`FAIL ${f} no attachment URL within 60s (${basename(f)})`);
		}
	}
	await box.fill(original); // leave the box as it was; nothing is submitted
} catch (e) {
	failed += 1;
	console.log(`ERRORS ${e.message}`);
} finally {
	await ctx.close();
}
process.exit(failed ? 1 : 0);
