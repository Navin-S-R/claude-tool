---
name: ct-pr-description
description: Write the pull-request description for a change that already has a GREEN review verdict and a GREEN flow verdict, in five short fixed sections, with screenshots uploaded and shown inline.
---

# Evidence-backed PR description (the last step)

Write the PR description only for a change that the pipeline already passed:
`$ct-review-loop` GREEN, then this skill (gate, write, print, confirm), then
`gh pr create` or `gh pr edit`. Use only evidence that exists; never invent any.
Explicit user instructions and higher-priority instructions take precedence.
State the risk tier early. The gate applies at every tier; the tier scales only
the depth of the caller and flow search.

## 1. Resolve the target

Pick `<remote>` first from the repo (it can be `upstream`, not `origin`). Run
`git fetch <remote>`. Use `<remote>/<base>` as the base, never a stale local branch.

- A base branch name: diff against it. A PR number: update that PR. Run
  `gh pr view <n> --json baseRefName,headRefName,headRefOid`. The current branch
  must equal `headRefName` and `git rev-parse HEAD` must equal `headRefOid`. On a
  mismatch, use the worktree that holds the branch or ask.
- A ticket ref (`ABC-123`, an issue URL): name the issue in Issue Description.
- Empty: the open PR's base, else the trunk (`develop`, `main` or `master`).
- Trailing text is extra focus.

State the base. If it is unclear, ask. Read verdicts and plan from the worktree
that holds the branch you describe.

Define `<slug>`: the branch name with `/` replaced by `-`. All work files go in
`.claude/workflow/pr-assets/<slug>/`. Before you write there, get the exclude file
with `git rev-parse --git-path info/exclude` (in a worktree `.git` is a file). If
`git check-ignore -q <path>` fails, append the path to that file and confirm with
`git check-ignore`. Never edit `.gitignore`.

## 2. The gate: no description unless the pipeline is green

Run it before anything is written. If a check fails, stop, name the gate, write nothing.

- Change set: `git diff --name-status <remote>/<base>...HEAD`, plus uncommitted
  tracked changes (`git diff --name-status HEAD`), plus untracked files outside
  `.claude/` (`git ls-files --others --exclude-standard`).
- Code gate: `.claude/workflow/reviews/latest-code.md` has the exact first line
  `VERDICT: GREEN` and names the review (cycle, reviewer, dimensions) from
  `$ct-review-loop`. If it does not name them, ask the owner; do not assume.
  `VERDICT: RED` always blocks. An author-written verdict does not pass. A
  disclosed single-agent review passes only if the reviewer is not the author of
  the change (a separate session or agent). A self-review by the author does not
  pass. If this is unclear, ask the owner.
- Flow gate: `.claude/workflow/reviews/latest-flow.md` first line is exactly
  `VERDICT: GREEN`, or starts with `VERDICT: GREEN — ` or `VERDICT: GREEN - `
  (so `VERDICT: GREENISH` fails). It must come from an executed flow review of the
  final state. An executed GREEN flow review passes the gate for any change,
  backend-only included, browser or not. Stop and ask only when no executed flow
  review exists. `VERDICT: GREEN — N/A: <reason>` passes only for documentation-only
  changes. `VERDICT: RED` always blocks.
- Documentation only: every file in the change set ends in `.md`, `.rst`, `.txt`
  or `.adoc` (agent prompt Markdown such as `SKILL.md`, `AGENTS.md` and
  `commands/*.md` counts only when the repo has no app or build to run), and none
  is a dependency, build or config file (`requirements*.txt`, `CMakeLists.txt`,
  `*.lock`, CI paths such as `.github/`). A dev harness under `tools/` does not
  count as an app or build. Any code, config, script, dependency, CI, template or
  data file means not documentation only. The owner's explicit classification
  settles a doubt. Then the PR says "documentation only — no flow review, nothing
  to run" (prompt files: "documentation only (agent prompt files) — no flow
  review, nothing to run"). If unsure, ask.
- Diff hash: for a committed change set use `git diff <remote>/<base>...HEAD | sha256sum`.
  For an uncommitted review use `git diff <remote>/<base> | sha256sum` (working
  tree including staged; list untracked files by name). A verdict records one of
  these hashes with its scope.
- Staleness: a verdict is stale when a change-set file has an mtime newer than
  the verdict, or when it names a base or branch that differs from the change set,
  or when its recorded diff hash differs from the recomputed hash. A recorded `HEAD`
  that is an ancestor of the current `HEAD` with an unchanged diff hash is NOT
  stale. A moved base with an unchanged 3-dot diff is not stale. For a committed
  delete or rename, the commit time is not a signal (a commit after the verdict is
  normal): judge it by the diff hash, and if no hash is recorded, ask. An
  uncommitted deletion or rename is stale. After a rebase or fresh checkout,
  the answer to a stale verdict is a re-review, not an override. A stale verdict blocks.
- Cannot decide: stop and ask. Never assume fresh.

At gate 1, write the record to `.claude/workflow/pr-assets/<slug>/gate.md`: the
`HEAD` SHA, the change-set list, the diff hash, and the mtime and first line of both
verdict files. Gate 2 (section 7) reads that file and compares all of it; any
difference blocks.

## 3. Gather the context (search, never memory)

Read `git diff <remote>/<base>...HEAD`, `git log <remote>/<base>..HEAD`, the approved
plan and its acceptance criteria, both verdicts, and the ticket the owner names.
Use the verdicts for the gates. Use the acceptance criteria to check your claims.
The body does not use the cycle counts or the test-audit report: do not read them.
Find every file, function, API and user flow the change touches with
search and the code. T0/T1: inline caller search. T2/T3: one explorer per module,
only when delegation is authorized.

## 4. Write five sections: exact headings, exact order, none skipped or merged

Use level `###` and copy the text exactly.

**Keep it short.** A reviewer reads the whole description in about two minutes.
Target: under 250 words of prose, excluding the screenshot table. The target is
soft: the flow-coverage bullets and the unverified line override it. Write for the
reviewer of the code, not as an audit log of the pipeline.

- Do not restate the diff, list every file, or explain how the pipeline ran.
- Leave out: verdict quotes, review cycle counts, the test-audit result, lane
  names, the risk tier, the acceptance-criteria table, the alternatives considered.
  The gates still apply; their details stay in `.claude/workflow/`.
- No empty filler. If a part has nothing to say, write one short line.

- `### Issue Description`: two to four sentences: what was broken or missing, and who it affected. The ticket ID, if any.
- `### Steps to Reproduce`: at most six numbered steps on the base branch, ending with the expected and the actual result. For a new feature: one line that says what the user cannot do yet.
- `### Solution Provided`: two to five sentences or bullets: what changed and why. Name a file only when the reviewer needs it to follow the change (a non-obvious location, a migration, a config).
- `### Impact Analysis – Proof That Existing Flows Are Not Affected` (en dash `–`):
  - One bullet per existing flow that touches the changed code: the flow, then how it was verified (test name, browser check, or "unaffected by design" with the reason in a few words).
  - One line with the tests that ran and the result. Take the numbers from a command you ran or from the verdict files; never invent them.
  - One line for rollback, only if it is more than "revert the PR" (a migration, a data patch, a flag).
  - Anything you cannot verify: one line, stated as unverified.
- `### Before and After Screenshots`: table `Scenario | Before | After`, one row per affected screen or state, with the images inline (see section 6). No UI: "N/A – no UI changes", and at most one short before/after log or API response if it helps.

## 5. Language: ASD-STE100 Simplified Technical English

Procedural sentences: 20 words maximum, one imperative instruction each.
Descriptive sentences: 25 words maximum, one topic each. Paragraphs: six
sentences maximum. Use active voice and the simple present, past and future only.
No "-ing" forms as verbs or nouns, except in technical names. One word has one
meaning. Avoid phrasal verbs and noun clusters of more than three words. Use
articles. Use vertical lists for sequences and for more than two related items.
Warnings stand alone before the step and start with `WARNING:` or `CAUTION:`.
Technical names stay exact, in backticks. Before output, check every sentence for
word count, passive voice and more than one instruction; fix, then print. Conflict
rule: if an STE rule conflicts with the section structure, keep the section names
and order, and apply STE inside them.

## 6. Screenshots (strict)

- Never commit them. Store them in `.claude/workflow/pr-assets/<slug>/{before,after}/`
  (the slug and the exclude step are in section 1).
- After: run the flow review's check script on the final state, or copy the flow
  review's screenshots of that state. Before: run it on the base in a temporary
  `git worktree add`, then remove the worktree. A screen that is new says so.
- **Upload, then embed.** The PR shows the images inline; the owner never drags
  files. Upload the screenshots as GitHub attachments with `upload.mjs` from
  `tools/gh-image-upload`. It uses real Chrome and commits nothing.
  - **When.** Upload only after the owner confirms the description (section 7).
    Before the confirm, the table cells show the local paths. The owner opens the
    local images at the confirm.
  - **Data rule.** Upload only screenshots of test or synthetic data. Real-data flow
    screenshots can show customer data: do not upload them. If you are unsure, or the
    repo is public, use the fallback and tell the owner.
  - **Repo.** Use the BASE repo of the PR. For a fork, a PR must exist first.
    A fork with no PR gets the fallback for every file.
  - **Mode.** Find the PR: `gh pr list --head <branch> --state open --json number`.
    If several PRs return, take the open one. With a PR, use `--pr <n>`.
    Otherwise use `--base <b> --branch <br>`. The branch must be on the remote.
    Push it only with the owner's OK from the confirm (section 7).
  - **Command.** Run the path, the preflight and the upload in ONE shell command.
    A new command starts a fresh shell, so `$UPLOAD` does not carry over.
    Replace the words in angle brackets. Allow the command up to 300 seconds (the tool stops itself after 240 s).
    The script never waits for a human.

    ```sh
    # ct-upload-path
    for c in \
      "$(realpath ~/.agents/skills/ct-pr-description 2>/dev/null)/../../../tools/gh-image-upload/upload.mjs" \
      "$(realpath "$(git rev-parse --show-toplevel 2>/dev/null)/.agents/skills/ct-pr-description" 2>/dev/null)/../../../tools/gh-image-upload/upload.mjs" \
      ~/.claude/tools/gh-image-upload/upload.mjs
    do
      [ -f "$c" ] && UPLOAD="$(realpath "$c")" && break
    done
    X=; [ -n "$DISPLAY$WAYLAND_DISPLAY" ] || X="xvfb-run -a"
    if [ -z "$UPLOAD" ] || [ ! -d "$(dirname "$UPLOAD")/node_modules" ]; then
      echo "PREFLIGHT-FAIL no upload tool or no node_modules"
    elif [ -n "$X" ] && ! command -v xvfb-run >/dev/null; then
      echo "PREFLIGHT-FAIL no display and no xvfb-run"
    else
      $X node "$UPLOAD" --repo <base owner/repo> (--pr <n> | --base <b> --branch <br>) \
        --cache .claude/workflow/pr-assets/<slug>/uploads.md <files>
    fi
    ```

    The installed skill is a symlink into the checkout, so three `..` reach the
    checkout root. The loop tries the user install, the project install, then
    `~/.claude/tools`. On `PREFLIGHT-FAIL`, give the owner the one-time setup from
    the root README (`npm ci` in `tools/gh-image-upload`, then the sign-in). Use
    the fallback and quote the reason in one line.
  - **Read the result for each file.** A `URL` line gives the image URL: use its LAST
    token in `<img src="<url>" width="280" alt="<scenario> before|after">`. Use every
    `URL` line, even when the exit code is not 0. The last line is `DONE <ok>/<total>`.
    Compare `<ok>` and `<total>` with the file count. A mismatch means a lost file.
  - **Busy profile.** If an `ERRORS launch profile busy` line shows, wait 30 seconds
    and run the command once more. Do not retry more than once.
  - **Fallback.** A file with no `URL` line (a `FAIL`, `ERRORS` or `LOGIN` line, a
    crash, a timeout, or a non-zero exit with no output) gets the fallback, for that
    file only. The cell text is "screenshot not uploaded (see author)". Tell the owner
    in chat why. Quote each `ERRORS` and `INFO` line and the `last-failure.png` path
    from the `INFO` line. List the local paths so the owner can drag them in.
  - **`LOGIN` (exit 4).** The owner signs in, never you. Print this command with the
    expanded absolute path of `$UPLOAD`: `xvfb-run -a node <absolute path> --login --terminal`
    for a server with no screen, or `node <absolute path> --login` with a display.
    The owner runs it once in their own terminal and sees `LOGIN-OK <user>`. Then run
    the upload again. Never run `--login` yourself. Never enter a credential or a 2FA
    code. Never read or copy the cookies of the profile. Never run your own Playwright
    against that profile.
- A cell with no screenshot at all says "unverified — no screenshot (<reason>)";
  Impact Analysis states it. A UI change with no check script: stop and ask.
- Image check, before you finish: only images the change set adds, stages or
  leaves untracked outside `.claude/` count (`git diff --diff-filter=AR --name-only <remote>/<base>...HEAD`,
  `git diff --cached --diff-filter=AR --name-only`, `git ls-files --others --exclude-standard`;
  extensions png, jpg, jpeg, gif, webp). Do not flag images already tracked in the
  repo. If a match is staged, unstage it (`git restore --staged <path>`). If a match
  is in a commit of the branch, or stays after unstaging, STOP: do not create or
  edit the PR until the owner removes it from the commits.

## 7. Output

1. Print the description in Markdown first, with the local screenshot paths in the
   table. Do not create or update the PR yet. Ask the owner to confirm. In the same
   question, ask "Push <branch> to <push remote>?", if the branch is not on that remote.
   Find `<push remote>` by the rule in step 3 before you ask.
2. After the owner explicitly confirms, run both gates again (staleness included)
   against the gate 1 record, and run the image check of section 6 again. A new
   commit, an edited file, a RED or stale verdict, or an image match blocks: name
   the gate that failed.
3. Find `<push remote>`: the first of these that is set.
   - `git config branch.<branch>.pushRemote`
   - `git config remote.pushDefault`
   - `git config branch.<branch>.remote`

   If none is set and the repo has one remote, use it. Otherwise ask the owner.
   Never use the base remote as the default when the repo has a separate base remote.
   Run `git fetch <push remote>`.
4. If the branch is not on `<push remote>`, or the local branch is ahead of it, run
   `git push -u <push remote> <branch>` only with the owner's approval. If the
   remote branch has commits that the local branch lacks (behind or diverged),
   stop and tell the owner. Never use `--force`.
5. If the owner refused the push and no PR exists, skip the upload. Give every
   screenshot cell the fallback and tell the owner why. Otherwise upload the
   screenshots (section 6) and replace the local paths with the URLs.
   Unused uploads remain in GitHub's store, but no page links them.
6. If any file used the fallback, show the owner the result and get an OK.
7. Check the head. For a new PR, local `HEAD` must equal `<push remote>/<branch>`.
   Run `git fetch <push remote>` first. For a PR that exists, read
   `gh pr view <n> --json headRefOid` after the push. Local `HEAD` must equal it.
   If it differs, wait 5 seconds and read it once more. If it still differs, stop
   and tell the owner.
8. Write the body to `.claude/workflow/pr-assets/<slug>/pr-body.md`, then run
   `gh pr create --body-file <that file>` or `gh pr edit --body-file <that file>`.
   Add no attribution of your own; project and owner rules apply.

Never invent a test result, flow, verdict, number or screenshot. Keep the five
headings and their order, always.

## Codex execution

Use the session model, targeting `gpt-6-astra`. Run browser checks with the tools
available; when the repo has `tools/ui-browser-check/`, use Playwright through it
with `SHOTS=<absolute assets dir>/after sh tools/ui-browser-check/run.sh <frontend-dir> <check.mjs>`
(and `/before` for the base). Delegate only when explicitly authorized and
supported, inheriting the selected model. Otherwise do the work as one agent and
disclose that it was a single-agent run.
The upload tool path is in section 6. The session never waits for a human: the
owner does the sign-in in their own terminal.
