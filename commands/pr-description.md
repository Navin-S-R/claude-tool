---
description: PR-description writer — the final step of the pipeline; gated on a GREEN /review-loop code verdict and a GREEN flow verdict, five short fixed sections in ASD-STE100 Simplified Technical English, screenshots uploaded as GitHub attachments (inline, never in git)
argument-hint: "[base branch | PR# | ticket ref | blank = the open PR's base, else trunk] [+focus]"
---

# /pr-description — evidence-backed PR description (the last step)

Write the pull-request description for a change that the pipeline has already passed. This is the final step of `PLAN → BUILD → CODE REVIEW → FLOW REVIEW → GREEN → COMMIT → PR`: it runs only on a GREEN review, it writes evidence that exists, and it never invents any:

> `/review-loop` (GREEN code + flow verdicts) → **`/pr-description`** (gate, write, print, confirm) → `gh pr create` / `gh pr edit`

**Scale to tier** (Risk-Tiered Three-Gate SOP — classify by blast radius × reversibility; **state the tier early**, round up when unsure): the **gate applies at every tier**; the tier scales only the depth of the caller / flow search. **T0/T1** → inline caller search. **T2/T3** → read-only Sonnet explorers. Group the changed modules by subsystem: one explorer for each subsystem, at most 4.

## 1. Resolve the target from `$ARGUMENTS`
Pick `<remote>` first: `origin`, else `upstream`, else ask the owner. Run `git fetch <remote>`. Use `<remote>/<base>` as the base in every command. Never use a stale local branch.
- **a base branch** (e.g. `develop`) → diff against `<remote>/develop`.
- **a PR number** → that PR; its description is updated, not created. Run `gh pr view <n> --json baseRefName,headRefName,headRefOid`. The base is `baseRefName`. The current branch must equal `headRefName`, and `git rev-parse HEAD` must equal `headRefOid`. On a mismatch, find the worktree that holds that branch (`git worktree list`) and run there, or stop and ask.
- **a ticket ref** (e.g. `ABC-123`, an issue URL) → the linked issue; name it in Issue Description.
- **empty** → the open PR's base (`gh pr view --json baseRefName`), else the repo trunk (`develop` / `main` / `master`).
- **trailing text** → extra focus.

For a ticket ref or an empty target, check the branch identity: `git branch --show-current` must be the branch the owner means. For an open PR, apply the same `headRefName` and `headRefOid` checks as for a PR number.

State the base you resolved. If you cannot resolve it, ask; do not guess. Read the verdict files and the plan from the worktree that holds the branch you describe, never from another tree.

`<slug>` is the branch name with `/` replaced by `-`. All work files go in `.claude/workflow/pr-assets/<slug>/`. Before you write there, get the exclude file with `git rev-parse --git-path info/exclude` (in a worktree, `.git` is a file). If `git check-ignore -q <path>` fails, append the path to that file, then confirm with `git check-ignore`. **Never edit `.gitignore`.**

## 2. The gate — no description unless the pipeline is green
Run it **before anything is written**, at **every tier**. If a check fails, **stop, name the gate, write nothing.**
- **Change set.** `git diff --name-status <remote>/<base>...HEAD`, plus uncommitted tracked changes (`git diff --name-status HEAD`), plus untracked files outside `.claude/` (`git ls-files --others --exclude-standard -- . ':!.claude'`).
- **Code gate.** `.claude/workflow/reviews/latest-code.md` exists, its first line is exactly `VERDICT: GREEN`, and it is the verdict that **`/review-loop`** wrote (its fresh reviewer). It counts as `/review-loop`'s when the file names the review (cycle, reviewer role, lanes). If it does not, ask the owner to confirm; do not assume. A verdict written by the author does not pass. `VERDICT: RED` always blocks.
- **Flow gate.** `.claude/workflow/reviews/latest-flow.md` comes from an executed flow review on the final state being pushed. Its first line is exactly `VERDICT: GREEN`, or it starts with `VERDICT: GREEN — ` or `VERDICT: GREEN - ` (so `VERDICT: GREENISH` fails). An executed GREEN flow review passes for any change set, browser or not. Stop and ask the owner only when no executed flow review exists. The form `VERDICT: GREEN — N/A: <reason>` passes only for a documentation-only change set. Any suffix that says the flow did not run (`N/A`, skipped, not run) counts as this N/A form. `VERDICT: RED` always blocks.
- **Documentation only.** Every file in the change set has the extension `.md`, `.rst`, `.txt` or `.adoc`, except prompt Markdown that an agent loads (`commands/*.md`, `SKILL.md`, `CLAUDE.md`). That prompt Markdown counts only when the repo has no app or build to run (as in a commands repo). A dev harness under `tools/` is not an app or a build. No file is a dependency, build or config file (`requirements*.txt`, `CMakeLists.txt`, `*.lock`, files under CI directories such as `.github/`). Any code, config, script, dependency, CI, template or data file → **not** documentation only. The owner's explicit classification settles a doubt. Then the `latest-flow.md` file must still exist, with the first line `VERDICT: GREEN — N/A: documentation only …` (the local hook requires the file); if it does not exist, ask the flow reviewer to write it. The PR says "documentation only — no flow review, nothing to run" in place of the flow verdict and the screenshots; for prompt files: "documentation only (agent prompt files) — no flow review, nothing to run". If unsure → stop and ask the owner.
- **Diff hash.** Compute the hash with this rule (pipe the diff to `sha256sum`): If any untracked file exists outside `.claude/`, or the work is uncommitted: `git add -N` every untracked file outside `.claude/`, then hash `git diff <remote>/<base>`. Otherwise hash `git diff <remote>/<base>...HEAD`. A verdict can record one of these hashes with its scope.
- **Staleness.** A verdict is **stale** when any file in the change set has an mtime newer than the verdict file, or when the verdict names a base or branch that differs from the change set being pushed. A base that moved by SHA only, with the same branch name, is not a difference. It is also stale when its recorded diff hash differs from the recomputed hash. For a verdict that records a hash, recompute the hash and compare it. A recorded `HEAD` that is an ancestor of the current `HEAD`, with an unchanged diff hash, is **not** stale. A recorded `HEAD` that is not an ancestor of the current `HEAD`, with no recorded hash, is stale; if unsure, ask the owner. A moved base with an unchanged 3-dot diff is **not** stale. For a committed deletion or rename, the commit time is not a signal. Verdicts are written before the commit, so a later commit is normal. Judge it by the diff hash; if the verdict records no hash, ask the owner. An uncommitted deletion or rename has no time, so the verdict is stale. A rebase or fresh checkout can reset the mtimes so that a good verdict looks stale. The answer is a re-review, not an override; say so. A stale verdict blocks.
- **Cannot decide → stop and ask.** Never assume fresh.

At **gate 1**, write the record to `.claude/workflow/pr-assets/<slug>/gate.md`: the `HEAD` SHA, the change-set list, the diff hash, and the mtime and first line of both verdict files. Run the image check (section 6) as well. The gate runs a **second time** (see section 7) and compares against that file; any difference blocks.

## 3. Gather the context (find, never guess)
- `git diff <remote>/<base>...HEAD`, `git log <remote>/<base>..HEAD`; the approved plan in `.claude/workflow/plans/` and its acceptance criteria; both verdict files; the ticket the owner names.
- Use the verdict files for the gates. Use the acceptance criteria to check your claims. The body does not use the cycle counts or the test-audit report: do not read them.
- **Every file, function, API and user flow the change touches.** Find callers and usages with grep and the code; do not recall them from memory. Scale the depth to the tier (see above).

## 4. Write the five sections — exact headings, exact order, none skipped, renamed or merged
Emit each heading at level `###`, text copied exactly.

**Keep it short.** A reviewer reads the whole description in about two minutes. Target: under 250 words of prose, excluding the screenshot table. The target is soft: the flow-coverage bullets and the unverified line override it. Write for the reviewer of the code, not as an audit log of the pipeline.
- Do not restate the diff, list every file, or explain how the pipeline ran.
- Leave out: verdict quotes, review cycle counts, the test-audit result, lane names, the risk tier, the acceptance-criteria table, the alternatives considered. The gates still apply; their details stay in `.claude/workflow/`.
- No empty filler. If a part has nothing to say, write one short line.

### Issue Description
Two to four sentences: what was broken or missing, and who it affected. The ticket ID, if any.
### Steps to Reproduce
At most six numbered steps on the **base** branch, ending with the expected and the actual result. For a new feature: one line that says what the user cannot do yet.
### Solution Provided
Two to five sentences or bullets: what changed and why. Name a file only when the reviewer needs it to follow the change (a non-obvious location, a migration, a config).
### Impact Analysis – Proof That Existing Flows Are Not Affected
(The dash is an en dash `–`; copy the heading exactly.)
- One bullet per existing flow that touches the changed code: the flow, then how it was verified (test name, browser check, or "unaffected by design" with the reason in a few words).
- One line with the tests that ran and the result (for example `bench run-tests --app jarvis: 214 passed`). Take the numbers from a command you ran or from the verdict files; never invent them.
- One line for rollback, only if it is more than "revert the PR" (a migration, a data patch, a flag).
- Anything you cannot verify: one line, stated as unverified.
### Before and After Screenshots
Table `Scenario | Before | After`, one row per affected screen or state, with the images inline (see section 6). No UI → "N/A – no UI changes", and at most one short before / after log or API response if it helps.

## 5. Language — ASD-STE100 Simplified Technical English (all prose)
- Procedural sentences: 20 words maximum, one instruction each, imperative. Descriptive sentences: 25 words maximum, one topic each. Paragraphs: six sentences maximum.
- Active voice only. Simple present, past and future only. No "-ing" forms as verbs or nouns, except in technical names.
- One word, one meaning. No phrasal verbs, except a technical name. Noun clusters: three words maximum. Use articles where the grammar needs them.
- Vertical lists for sequences and for more than two related items.
- Warnings and cautions stand alone, before the step they apply to, and start with `WARNING:` or `CAUTION:`.
- Technical names (files, functions, endpoints, error codes, UI labels) stay exactly as they appear, in backticks.
- **Self-check every sentence before output:** count the words, look for passive voice, look for more than one instruction. Fix, then print.
- **Conflict rule:** if an STE rule conflicts with the section structure, keep the section names and order, and apply STE inside them.

## 6. Screenshots (strict)
- **Never committed to any codebase.** Store them in `.claude/workflow/pr-assets/<slug>/`, with `before/` and `after/` inside (the slug and the exclude step are in section 1). Create these folders only when there are screenshots.
- **After:** the Haiku agent runs the flow review's check script on the final state with `SHOTS=<absolute assets dir>/after sh ~/.claude/tools/ui-browser-check/run.sh <frontend-dir> <check.mjs>` (Jarvis SPAs; another harness uses its own screenshot option). Or it copies the flow review's own screenshots of the same final state into `after/`, if they exist.
- **Before:** the same script on the base branch in a temporary `git worktree add` (a temp dir), with `SHOTS=<absolute assets dir>/before`. For the Jarvis SPAs, run `npm ci` in `frontend/` and in `wiki-graph-core/` of that worktree first. Remove the worktree afterwards (`git worktree remove`). If the screen did not exist on the base, the cell says so.
- **Upload, then embed.** The PR shows the images inline; the owner never drags files. The Haiku agent uploads the screenshots as GitHub attachments with `~/.claude/tools/gh-image-upload/upload.mjs` (from [`tools/gh-image-upload`](../tools/gh-image-upload)). It uses real Chrome and commits nothing.
  - **When.** Upload only after the owner confirms the description (section 7). Before the confirm, the table cells show the local paths, so the owner can open the files.
  - **Data rule.** Upload only screenshots of test or synthetic data. If a screenshot can show real customer data, or the repo is public and you are not sure, do not upload. Use the fallback and tell the owner.
  - **Preflight.** Run `test -f ~/.claude/tools/gh-image-upload/upload.mjs && test -d ~/.claude/tools/gh-image-upload/node_modules`. If it fails, tell the owner the one-time install command from the root README and use the fallback.
  - **Repo.** Use the BASE repo of the PR (for a fork, use `--pr` after the PR exists).
  - **Mode.** If a PR for the branch exists (`gh pr list --head <branch> --json number`), use `--pr <n>`. Otherwise use `--base <b> --branch <br>`. The branch must be on the remote. Pushing it needs the owner's OK, as part of the confirm in section 7, never before.
  - **Command.** `node ~/.claude/tools/gh-image-upload/upload.mjs --repo <base owner/repo> (--pr <n> | --base <b> --branch <br>) --cache .claude/workflow/pr-assets/<slug>/uploads.md <files>`. Run it with a Bash timeout of 300000 ms. The script never waits for a human.
  - **Read the result for each file.** A `URL` line gives the image URL: use its LAST token in `<img src="<url>" width="280" alt="<scenario> before|after">`. Use every `URL` line, even when the exit code is not 0.
  - **Fallback.** A file with no `URL` line (a `FAIL`, `ERRORS` or `LOGIN` line, a crash, a timeout, or a non-zero exit with no output) gets the fallback, for that file only. The cell text is "screenshot not uploaded (see author)". Tell the owner in chat why, and list the local paths so the owner can drag them in.
  - **`LOGIN` (exit 4).** Tell the owner to run `! node ~/.claude/tools/gh-image-upload/upload.mjs --login` once, then run the upload again. On a server with no screen, the owner runs `xvfb-run -a node ~/.claude/tools/gh-image-upload/upload.mjs --login --terminal` in their own terminal instead. Never enter a credential or a 2FA code. Never read or copy the cookies of the profile. Never run your own Playwright against that profile.
- A cell with no screenshot at all says "unverified — no screenshot (<reason>)", and Impact Analysis states it.
- A UI change with no check script → stop and ask. A check script is code, written by the latest Sonnet at high effort.
- **Image check** (at gate 1, again at gate 2, and before you finish). It looks for images (extensions `png`, `jpg`, `jpeg`, `gif`, `webp`) that the change set adds, stages or leaves untracked. The `.claude/` exclusion applies only to the untracked check; a committed or staged image anywhere, `.claude/` included, counts. "Already tracked" always means tracked in `<remote>/<base>`: do not flag such an image, or a rename of it. Run:
  - `git diff --diff-filter=A --name-only <remote>/<base>...HEAD`
  - `git log --diff-filter=A --name-only --format= <remote>/<base>..HEAD` (it finds an image that a later commit deleted)
  - `git diff --cached --diff-filter=A --name-only`
  - `git diff --diff-filter=A --name-only <remote>/<base>` (it finds an intent-to-add file)
  - `git ls-files --others --exclude-standard -- . ':!.claude'`

  A match in a commit of the branch → **STOP**. Do not create or edit the PR until the owner removes it from the commits. A staged match → unstage it (`git restore --staged <path>`); if it stays, stop. An untracked match → ask the owner to move it or ignore it, and stop to tell the owner. The owner may state in the session that an added image is a product asset. Quote that statement in Impact Analysis. Then the image is not a screenshot and it does not stop the PR.

## 7. Output
- **Print the description in Markdown first**, with the local screenshot paths in the table. Do not create or update the PR yet.
- **Ask the owner to confirm.** In the same question, ask whether to push the branch, if it is not on the remote.
- After the owner **explicitly confirms**, run `git fetch <remote>` first. For a PR number, also re-read `gh pr view <n> --json headRefOid`. Then **re-run both gates** (section 2, staleness included) and the image check **immediately before** the call. Compare them with the `gate.md` record. If `gate.md` is missing, stop and run gate 1 again. If anything differs — a new commit, an edited file, a RED or stale verdict, an image match — **do not create the PR**: say which gate failed.
- Before `gh pr create`, local `HEAD` must equal `<remote>/<branch>`; if not, stop and tell the owner to push or reconcile. Before `gh pr edit`, read `gh pr view <n> --json headRefOid` again, right before the edit. Local `HEAD` must equal it.
- After the confirm and the gates: push the branch if the owner approved, then upload the screenshots (section 6), then replace the local paths with the URLs. Uploads that stay unused remain in GitHub's store, but no page links them.
- Then write the description to `.claude/workflow/pr-assets/<slug>/pr-body.md` and run `gh pr create --body-file <file>` (new PR) or `gh pr edit --body-file <file>` (existing PR). Add no commit or PR attribution of your own; the project's and the owner's rules apply.
- **Never invent** a test result, flow, verdict, number or screenshot.

## Model assignment (SOP)
| Role | Model · effort |
|---|---|
| Write the description; the caller / flow search (T2/T3: the per-subsystem explorers) | latest Sonnet · high |
| Run the check scripts for the before / after screenshots, read them, and upload them with `gh-image-upload` | Haiku |
| Write a new or changed check script (it is code) | latest Sonnet · high |

No Opus and no Fable are used by this command.

## Guardrails
- **No green, no description.** A RED, stale, missing or non-`/review-loop` verdict stops the command; it never writes around it.
- **Proof, not assumption.** Every flow, number and verdict comes from code, a file or a command you ran. Unverifiable items are stated as such.
- **Screenshots stay out of git and show inline.** They are uploaded as GitHub attachments, never committed. No `.gitignore` edit; no image that the change adds is staged, committed or untracked in the tree.
- **Short beats complete.** The pipeline's evidence lives in `.claude/workflow/`; the PR carries only what a reviewer needs.
- **The owner confirms before the PR is created or edited**, and the gates run again first.
- Keep the five headings and their order, always.
