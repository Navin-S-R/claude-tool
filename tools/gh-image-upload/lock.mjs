// Profile lock for upload.mjs: one upload at a time per Chrome profile.
import { randomBytes } from "node:crypto";
import { chmodSync, linkSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PhaseError } from "./lib.mjs";

const STALE_MS = 15 * 60_000;

export function pidAlive(pid) {
	try {
		process.kill(pid, 0);
		return true;
	} catch (e) {
		return e.code === "EPERM";
	}
}

// Stale: not a real PID, older than 15 minutes (the PID may be reused), or a dead process.
export function isStaleLock(content, ageMs, alive = pidAlive) {
	const text = content.trim();
	if (!/^\d+$/.test(text) || Number(text) <= 1) return true;
	return ageMs > STALE_MS || !alive(Number(text));
}

function busy(why) {
	return new PhaseError("launch", `profile busy (${why})`);
}

export class ProfileLock {
	constructor(dir) {
		this.dir = dir;
		this.path = join(dir, ".upload.lock");
		this.held = false;
	}

	take() {
		this.prepareDir();
		if (this.create()) return;
		const owner = this.readOwner();
		if (!owner) {
			if (this.create()) return; // the owner released it between our two calls
			throw busy("could not take the lock");
		}
		if (!isStaleLock(owner.content, Date.now() - owner.mtimeMs)) throw busy(`another upload runs, pid ${owner.content.trim()}`);
		this.takeOver(owner.content);
	}

	// Rename is atomic: only one taker gets the stale file, the others get ENOENT.
	takeOver(staleContent) {
		const moved = this.uniquePath("stale");
		try {
			renameSync(this.path, moved);
		} catch (e) {
			if (e.code === "ENOENT" && this.create()) return;
			throw busy(e.code === "ENOENT" ? "could not take the lock" : `lock failed: ${e.message}`);
		}
		if (this.readFile(moved) !== staleContent) {
			this.restore(moved); // we moved a fresh lock of another run: give it back
			throw busy("lock changed while taking over");
		}
		rmSync(moved, { force: true });
		if (!this.create()) throw busy("could not take the lock");
	}

	restore(moved) {
		try {
			linkSync(moved, this.path);
		} catch {}
		rmSync(moved, { force: true });
	}

	release() {
		try {
			if (this.held) rmSync(this.path, { force: true });
		} catch {}
		this.held = false;
	}

	prepareDir() {
		this.guard(() => {
			mkdirSync(this.dir, { recursive: true, mode: 0o700 });
			chmodSync(this.dir, 0o700);
		});
	}

	// The PID is written to a temp file first, then linked: a reader never sees an empty lock.
	create() {
		const temp = this.uniquePath("tmp");
		try {
			writeFileSync(temp, String(process.pid), { flag: "wx" });
			linkSync(temp, this.path);
			this.held = true;
			return true;
		} catch (e) {
			if (e.code === "EEXIST") return false;
			throw new PhaseError("launch", `lock failed: ${e.message}`);
		} finally {
			rmSync(temp, { force: true });
		}
	}

	uniquePath(kind) {
		return `${this.path}.${kind}.${process.pid}.${randomBytes(4).toString("hex")}`;
	}

	readFile(path) {
		try {
			return readFileSync(path, "utf8");
		} catch {
			return null;
		}
	}

	// Content and mtime of the lock, or null when it is gone.
	readOwner() {
		try {
			return { content: readFileSync(this.path, "utf8"), mtimeMs: statSync(this.path).mtimeMs };
		} catch (e) {
			if (e.code === "ENOENT") return null;
			throw new PhaseError("launch", `lock failed: ${e.message}`);
		}
	}

	guard(fn) {
		try {
			fn();
		} catch (e) {
			throw new PhaseError("launch", `profile folder failed: ${e.message}`);
		}
	}
}
