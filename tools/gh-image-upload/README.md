# gh-image-upload

Uploads local screenshots to GitHub as PR attachments and prints their URLs, so
`/pr-description` can put the images inline in the PR body. Nothing is committed to any repo:
the files go to GitHub's attachment store, the same place a drag-and-drop puts them. GitHub has
no API or `gh` command for this, so the script drives real Chrome.

## Set up (once)

You need Google Chrome and Node 18 or newer. Use the lockfile:

```sh
cd ~/.claude/tools/gh-image-upload
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci
```

First sign-in: the OWNER runs this once and signs in to GitHub in the Chrome window.

```sh
node ~/.claude/tools/gh-image-upload/upload.mjs --login
```

The script prints `LOGIN-OK <user>`. The session stays in the profile for later runs.

## Sign in on a headless server

The server has no screen. The OWNER signs in, never an agent. Use one of two ways.

(a) Sign in by terminal. Type this in your own terminal on the server:

```sh
xvfb-run -a node ~/.claude/tools/gh-image-upload/upload.mjs --login --terminal [--login-wait <seconds>]
```

The script asks for the user name and the password. The password does not show on the screen.
It asks for the 2FA code (authenticator app, SMS or device-verification email) when GitHub asks.
For GitHub Mobile, it prints `LOGIN approve the sign-in in GitHub Mobile (number <n>)`. Approve on
your phone. A passkey-only sign-in is not supported: choose another 2FA method on GitHub.
A wrong password or code gets three tries. `--login-wait` is the total time: default 300, maximum 900.
`--terminal` works only with `--login`, and it needs an interactive terminal (exit 2 otherwise).
A password that holds an ESC byte cannot be typed in `--terminal` mode.
An agent never runs this command and never types a credential.

(b) Forward a screen. If your computer has an X server, connect with `ssh -Y <user>@<host>`.
Then run `node ~/.claude/tools/gh-image-upload/upload.mjs --login` and sign in in the Chrome window.

## Run

```sh
# open PR
node ~/.claude/tools/gh-image-upload/upload.mjs --repo <owner/repo> --pr <n> shots/before/*.png shots/after/*.png
# no PR yet (the branch must be on the remote)
node ~/.claude/tools/gh-image-upload/upload.mjs --repo <owner/repo> --base <base> --branch <branch> shots/after/*.png
```

Options:

- `--cache <file>`: one line per upload, `<sha256> <url> <file>`. A file with the same content
  is not uploaded again. All files cached: Chrome does not start. The file must be a readable
  regular file, or the script exits with a usage error. A cache URL must be a GitHub attachment URL.
  A last line without a newline is ignored.
- `--deadline <seconds>`: total time limit. Default 240, maximum 600. Files left at the limit get
  `FAIL <file> skipped: deadline`.
- Files: regular files, png, jpg, jpeg, gif or webp, 10 MB at most. Files with the same content
  upload once, and each path gets the URL.

The script never waits for a human, except in `--login` mode. Run it with a Bash timeout of
300000 ms.

## Output lines

The URL is always the last token of a `URL` line, because a path can hold spaces.

| Line | Meaning | What to do |
|---|---|---|
| `URL <file> <url>` | The file has a URL. | Use it. |
| `FAIL <file> <reason>` | The file has no URL. After the first upload FAIL, the script skips the other files. After an error, a signal or a crash, every file with no URL gets a FAIL line. | Use the fallback for that file. |
| `LOGIN ...` | The profile is not signed in (exit 4). | The owner runs `node upload.mjs --login`, then run again. |
| `LOGIN-OK <user>` | `--login` finished. | Run the upload again. |
| `ERRORS <phase> <message>` | A step failed. One line. Phases: `usage`, `setup`, `launch`, `login`, `goto`, `find-box`, `find-input`, `upload`. | Read the message. Use the fallback for files with no URL. |
| `INFO ...` | Page title, final URL and screenshot path after a failure. Or `cache not written: <message>`. | Open the screenshot. A cache message needs no action: the upload went on. |
| `DONE <ok>/<total>` | Always the last stdout line of an upload run, also after an error or a signal. | Compare with the number of files. |

Exit codes: 0 all files uploaded, 1 some file FAILed, 2 usage, 3 setup, launch or goto, 4 login.
A `URL` line stays valid even when the exit code is not 0. A cache error never changes the exit code.
Once the upload run starts, each file gets exactly one `URL` or `FAIL` line.

## How it works

- Opens a headed Chrome with its own profile at `~/.claude/gh-upload-profile` (override with
  `GH_UPLOAD_PROFILE`). Your everyday Chrome profile is not touched.
- Opens the PR page (`--pr`) or the compare page (`--base` / `--branch`), finds the markdown
  box and drops each file into it. It reads back the `user-attachments` URL, restores the box
  to its old text and closes the window. It never clicks Comment or Create.
- A lock file, `<profile>/.upload.lock`, holds the PID. It is created whole, never empty. A second run says
  `profile busy`. The lock is stale, and the script replaces it, when the PID is not valid, the
  process is dead, or the lock is older than 15 minutes.
- On Linux with no `DISPLAY` and no `WAYLAND_DISPLAY`, it stops with `no display`. Run it under
  `xvfb-run`, or from a desktop session.
- After a failure, it saves `<profile>/last-failure.png`.

## Security

- The profile folder is a credential (mode 700). It holds the GitHub session.
- An agent never reads the profile cookies, never exports the storage state, and never enters a
  password or a 2FA code. The owner signs in.
- An upload stays in GitHub's store even when no page uses it. On a public repo, anyone with the
  URL can see it. On a private repo, the URL shows only to people who can see the repo.
- Upload only screenshots of test or synthetic data.

## When it breaks

GitHub changes its markup now and then. Update two places in `upload.mjs`:

- `BOX_SELECTORS`: the selectors of the markdown textarea.
- `findInput()`: the lookup of the `input[type=file]` near the textarea.

Open the PR page in Chrome. Inspect the textarea and the `input[type=file]` in DevTools. Then
change the selector or the lookup to match.

A stuck lock: check that no upload runs, then delete `~/.claude/gh-upload-profile/.upload.lock`.

Run the offline tests with `npm test`. They cover `lib.mjs` only. `/pr-description` falls back to
local paths when the upload fails.
