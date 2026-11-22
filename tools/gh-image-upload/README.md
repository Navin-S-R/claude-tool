# gh-image-upload

Uploads local screenshots to GitHub as PR attachments and prints their URLs, so
`/pr-description` can put the images inline in the PR body. Nothing is committed to any repo:
the files go to GitHub's attachment store, the same place a drag-and-drop puts them. GitHub has
no API or `gh` command for this, so the script drives real Chrome.

## Set up (once)

```sh
cd ~/.claude/tools/gh-image-upload
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install   # uses your installed Google Chrome
```

## Run

```sh
# open PR
node ~/.claude/tools/gh-image-upload/upload.mjs --repo Aerele-RnD/jarvis --pr 812 shots/before/*.png shots/after/*.png
# no PR yet (the branch must be pushed)
node ~/.claude/tools/gh-image-upload/upload.mjs --repo Aerele-RnD/jarvis --base develop --branch feat/x shots/after/*.png
```

It prints one `URL <file> <url>` line per file, or `FAIL <file> <reason>`. The exit code is 0
only when every file got a URL.

## How it works

- Opens a headed Chrome with its own profile at `~/.claude/gh-upload-profile` (override with
  `GH_UPLOAD_PROFILE`). Your everyday Chrome profile is not touched.
- **First run:** the profile is not signed in. The script prints `LOGIN` and waits up to 5
  minutes. Sign in yourself; the session stays in the profile for later runs.
- Opens the PR page (`--pr`) or the compare page (`--base` / `--branch`), finds the markdown
  box and drops each file into it. It reads back the `user-attachments` URL, restores the box
  to its old text and closes the window. It never clicks Comment or Create.
- On a private repo, the URLs show only to people who can see the repo.

## When it breaks

GitHub changes its markup now and then. If you see `no markdown box found` or
`no file input next to the markdown box`, update the selectors at the top of the
"markdown box" block in `upload.mjs`. `/pr-description` falls back to listing local paths
when the upload fails.
