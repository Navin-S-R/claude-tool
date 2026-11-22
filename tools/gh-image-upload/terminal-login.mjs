// Sign in to GitHub from a terminal, for a server with no screen (upload.mjs --login --terminal).
// The password and the codes live only in local variables. No error text, log line or stack
// may hold a field value: failures here are rebuilt as PhaseErrors with fixed text.
import { PhaseError, isGithubOrigin, oneLine } from "./lib.mjs";

const MAX_TRIES = 3;
const SETTLE_MS = 6000; // a page that just got a submit may still show the old form
const UNKNOWN_MS = 6000; // an unknown page this long is not a page that is still loading
const OTP = 'input[name="app_otp"], #app_totp, input[name="otp"], #otp, input[name="sms_otp"], input[autocomplete="one-time-code"]';
const FLASH = '.flash-error:visible, [role="alert"]:visible';
const OTHER_METHOD = 'a[href*="/sessions/two-factor/app"], a:has-text("authenticator app"), a:has-text("authentication app")';

export class TerminalLogin {
	constructor(up, tty, waitS) {
		this.up = up;
		this.page = up.page;
		this.tty = tty;
		this.until = Date.now() + waitS * 1000;
		this.waitS = waitS;
		this.passwordTries = 1; // the first password is already in
		this.codeTries = 0;
		this.submittedAt = 0;
		this.unknownSince = 0;
		this.mobileTold = false;
	}

	// Returns the user name, or throws a PhaseError.
	async run() {
		const signedIn = await this.submitFirst();
		if (signedIn) return signedIn;
		while (Date.now() < this.until) {
			const user = await this.up.signedInUser();
			if (user) return user;
			await this.step();
			await this.page.waitForTimeout(1000);
		}
		const span = this.waitS >= 60 && this.waitS % 60 === 0 ? `${this.waitS / 60} minutes` : `${this.waitS} seconds`;
		throw new PhaseError("login", `not signed in after ${span}`);
	}

	assertOnGithub() {
		if (!isGithubOrigin(this.page.url())) throw new PhaseError("login", `sign-in left github.com: ${this.page.url()}`);
	}

	// A prompt ends at the login-wait deadline, so a stuck page never holds the terminal.
	ask(label, hidden = false) {
		return this.tty.ask(label, { hidden, until: this.until, waitS: this.waitS });
	}

	async step() {
		this.assertOnGithub();
		if (await this.visible(OTP)) return this.handleCode();
		if ((await this.visible("#login_field")) && (await this.visible("#password"))) return this.handleLoginForm();
		if (await this.clickOtherMethod()) return this.noteKnown();
		const text = await this.bodyText();
		if (/GitHub Mobile/i.test(text) && !/passkey|security key/i.test(text)) return this.handleMobile(text);
		if (/passkey|security key|webauthn/i.test(`${this.page.url()} ${text}`)) {
			throw new PhaseError("login", "passkey sign-in is not supported in --terminal; choose another 2FA method on GitHub");
		}
		await this.handleUnknown();
	}

	async submitFirst() {
		const user = await this.up.signedInUser();
		if (user) return user;
		const name = await this.ask("GitHub user name or email:");
		const password = await this.ask("Password:", true);
		await this.fillForm([["#login_field", name], ["#password", password]], "#password", "sign-in form");
		return null;
	}

	// The values leave this module through the page only. The error text names no value.
	async fillForm(fields, submitSelector, what) {
		this.assertOnGithub();
		try {
			for (const [selector, value] of fields) await this.page.locator(selector).fill(value, { timeout: 10_000 });
			this.assertOnGithub();
			await this.page.locator(submitSelector).press("Enter");
		} catch (e) {
			if (e instanceof PhaseError) throw e;
			throw new PhaseError("login", `could not fill the ${what} at ${this.page.url()}`);
		} finally {
			for (const field of fields) field[1] = "";
		}
		this.markSubmitted();
	}

	async handleLoginForm() {
		const flash = await this.flashText();
		if (!flash || this.recentlySubmitted()) return;
		this.up.say(`LOGIN ${flash}`);
		if (this.passwordTries >= MAX_TRIES) throw new PhaseError("login", `sign-in refused after ${MAX_TRIES} tries: ${flash}`);
		this.passwordTries += 1;
		const password = await this.ask("Password:", true);
		await this.fillForm([["#password", password]], "#password", "sign-in form");
	}

	async handleCode() {
		if (this.recentlySubmitted() && !(await this.flashText())) return;
		this.codeTries += 1;
		if (this.codeTries > MAX_TRIES) throw new PhaseError("login", `sign-in code refused ${MAX_TRIES} times`);
		const prompt = await this.headingText();
		if (prompt) this.up.say(`LOGIN ${prompt}`);
		const code = await this.ask("Code:");
		const field = this.page.locator(OTP).filter({ visible: true }).first();
		await this.fillCode(field, code);
	}

	async fillCode(field, code) {
		this.assertOnGithub();
		try {
			await field.fill(code, { timeout: 10_000 });
			this.assertOnGithub();
			await field.press("Enter");
		} catch (e) {
			if (e instanceof PhaseError) throw e;
			throw new PhaseError("login", `could not fill the code form at ${this.page.url()}`);
		}
		this.markSubmitted();
	}

	handleMobile(text) {
		this.noteKnown();
		if (this.mobileTold) return;
		this.mobileTold = true;
		const digits = /(?:number|enter)[^\d]{0,80}(\d{1,3})\b/i.exec(text);
		this.up.say(`LOGIN approve the sign-in in GitHub Mobile (number ${digits ? digits[1] : "not shown"})`);
	}

	async handleUnknown() {
		this.unknownSince ||= Date.now();
		if (Date.now() - this.unknownSince < UNKNOWN_MS) return;
		const title = await this.page.title().catch(() => "");
		await this.up.evidence();
		throw new PhaseError("login", `unexpected page "${oneLine(title)}" ${this.page.url()}`);
	}

	async clickOtherMethod() {
		const link = this.page.locator(OTHER_METHOD).filter({ visible: true }).first();
		if (/two-factor\/app/.test(this.page.url()) || !(await link.count())) return false;
		await link.click({ timeout: 5000 }).catch(() => {});
		return true;
	}

	markSubmitted() {
		this.submittedAt = Date.now();
		this.noteKnown();
	}

	recentlySubmitted() {
		return Date.now() - this.submittedAt < SETTLE_MS;
	}

	noteKnown() {
		this.unknownSince = 0;
	}

	visible(selector) {
		return this.page.locator(selector).filter({ visible: true }).first().isVisible().catch(() => false);
	}

	async flashText() {
		const text = await this.page.locator(FLASH).first().textContent({ timeout: 500 }).catch(() => "");
		return oneLine(text || "").slice(0, 200);
	}

	async headingText() {
		const text = await this.page.locator("h1, h2").first().textContent({ timeout: 500 }).catch(() => "");
		return oneLine(text || "").slice(0, 200);
	}

	bodyText() {
		return this.page.locator("body").innerText({ timeout: 2000 }).catch(() => "");
	}
}
