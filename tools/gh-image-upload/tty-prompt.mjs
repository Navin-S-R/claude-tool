// Line input from the terminal for the --terminal sign-in. Raw mode: we echo each key
// ourselves, so a hidden answer (the password) never reaches the screen.
// `until` (epoch ms) ends the wait: raw mode is restored and the answer is rejected.
import { PhaseError } from "./lib.mjs";

export class TtyPrompt {
	ask(label, { hidden = false, until = 0, waitS = 0 } = {}) {
		return new Promise((resolve, reject) => {
			const stdin = process.stdin;
			let text = "";
			let timer = null;
			const release = () => {
				clearTimeout(timer);
				stdin.off("data", onData);
				stdin.setRawMode(false);
				stdin.pause();
				process.stdout.write("\n");
			};
			const finish = () => {
				release();
				resolve(text);
			};
			const expire = () => {
				release();
				text = "";
				reject(new PhaseError("login", `not signed in after ${waitS} s`));
			};
			const onData = (chunk) => {
				for (const ch of String(chunk)) {
					if (ch === "\r" || ch === "\n") return finish();
					if (ch === "\u0003") return interrupt(stdin);
					if (ch === "\u001b") return; // arrow keys and other escape sequences
					if (ch === "\u007f" || ch === "\b") text = erase(text, hidden);
					else if (ch >= " ") text = add(text, ch, hidden);
				}
			};
			process.stdout.write(`${label} `);
			stdin.setEncoding("utf8");
			stdin.setRawMode(true);
			stdin.resume();
			stdin.on("data", onData);
			if (until) timer = setTimeout(expire, Math.max(0, until - Date.now()));
		});
	}
}

function add(text, ch, hidden) {
	if (!hidden) process.stdout.write(ch);
	return text + ch;
}

function erase(text, hidden) {
	if (text && !hidden) process.stdout.write("\b \b");
	return text.slice(0, -1);
}

// Raw mode turns Ctrl-C into a plain key: send the signal ourselves.
function interrupt(stdin) {
	stdin.setRawMode(false);
	process.kill(process.pid, "SIGINT");
}
