---
description: PR-description writer — the final step of the pipeline; gated on a GREEN /review-loop code verdict and a GREEN flow verdict, five fixed sections in ASD-STE100 Simplified Technical English, screenshots kept out of git
argument-hint: "[base branch | PR# | ticket ref | blank = the open PR's base, else trunk] [+focus]"
---

# /pr-description — evidence-backed PR description (the last step)

Write the pull-request description for a change that the pipeline has already passed. This is the final step of `PLAN → BUILD → CODE REVIEW → FLOW REVIEW → GREEN → COMMIT → PR`: it runs only on a GREEN review, it writes evidence that exists, and it never invents any:

> `/review-loop` (GREEN code + flow verdicts) → **`/pr-description`** (gate, write, print, confirm) → `gh pr create` / `gh pr edit`

**Scale to tier** (Risk-Tiered Three-Gate SOP — classify by blast radius × reversibility; **state the tier early**, round up when unsure): the **gate applies at every tier**; the tier scales only the depth of the caller / flow search. **T0/T1** → inline caller search. **T2/T3** → read-only Sonnet explorers, one per changed module.

## 1. Resolve the target from `$ARGUMENTS`
- **a base branch** (e.g. `develop`) → diff against it.
- **a PR number** → that PR; its description is updated, not created. Run `git fetch`, then `gh pr view <n> --json baseRefName,headRefName,headRefOid`. The base is `baseRefName`. The current branch must equal `headRefName`, and `git rev-parse HEAD` must equal `headRefOid`. On a mismatch, find the worktree that holds that branch (`git worktree list`) and run there, or stop and ask.
- **a ticket ref** (e.g. `ABC-123`, an issue URL) → the linked issue; name it in Issue Description.
- **empty** → the open PR's base (`gh pr view --json baseRefName`), else the repo trunk (`develop` / `main` / `master`), after `git fetch`.
- **trailing text** → extra focus.

State the base you resolved. If you cannot resolve it, ask; do not guess. Read the verdict files and the plan from the worktree that holds the branch you describe, never from another tree.

## 2. The gate — no description unless the pipeline is green
Run it **before anything is written**, at **every tier**. If a check fails, **stop, name the gate, write nothing.**
- **Change set.** `git diff --name-status <base>...HEAD`, plus uncommitted tracked changes (`git diff --name-status HEAD`), plus untracked files outside `.claude/` (`git ls-files --others --exclude-standard`).
- **Code gate.** `.claude/workflow/reviews/latest-code.md` exists, its first line is exactly `VERDICT: GREEN`, and it is the verdict that **`/review-loop`** wrote (its fresh reviewer). It counts as `/review-loop`'s when the file names the review (cycle, reviewer role, lanes). If it does not, ask the owner to confirm; do not assume. A verdict written by the author does not pass. `VERDICT: RED` always blocks.
- **Flow gate.** `.claude/workflow/reviews/latest-flow.md` has a first line that starts with `VERDICT: GREEN`, from an executed flow review on the final state being pushed. The form `VERDICT: GREEN — N/A: <reason>` passes only for a documentation-only change set. Any other change set needs an executed flow review; for a tests-only or backend-only change, stop and ask the owner. `VERDICT: RED` always blocks.
- **Documentation only.** Every file in the change set has the extension `.md`, `.rst`, `.txt` or `.adoc`, and none is a dependency, build or config file (`requirements*.txt`, `CMakeLists.txt`, `*.lock`, files under CI directories such as `.github/`). Any code, config, script, dependency, CI, template or data file → **not** documentation only. Prompt Markdown that an agent loads (`commands/*.md`, `SKILL.md`, `CLAUDE.md`) counts as documentation only when the repo has no app or build to run (as in a commands repo). Then a missing flow verdict passes. The PR says "documentation only — no flow review, nothing to run" in place of the flow verdict and the screenshots; for prompt files: "documentation only (agent prompt files) — no flow review, nothing to run". If unsure → stop and ask the owner.
- **Staleness.** A verdict is **stale** when any file in the change set has an mtime newer than the verdict file, or when the verdict names a commit, tree, base or branch that differs from the change set being pushed. For a deleted or renamed file, compare the commit time of the commit that deleted or renamed it (`git log -1 --format=%ct <base>..HEAD -- <path>`) with the verdict mtime; an uncommitted deletion or rename has no time, so the verdict is stale. A verdict older than the commit is normal: verdicts are written before the commit. A rebase or fresh checkout can reset the mtimes so that a good verdict looks stale. The answer is a re-review, not an override; say so. A stale verdict blocks.
- **Cannot decide → stop and ask.** Never assume fresh.

At **gate 1**, record the `HEAD` SHA, the change-set list, and the mtime and first line of both verdict files. The gate runs a **second time** (see section 7) and compares all of them; any difference blocks.

## 3. Gather the context (find, never guess)
- `git diff <base>...HEAD`, `git log <base>..HEAD`; the approved plan in `.claude/workflow/plans/` and its acceptance criteria; both verdict files with their cycle counts (when the files hold them); the ticket the owner names.
- `.claude/workflow/reviews/latest-test-audit.md`, when it exists.
- **Every file, function, API and user flow the change touches.** Find callers and usages with grep and the code; do not recall them from memory. Scale the depth to the tier (see above).

## 4. Write the five sections — exact headings, exact order, none skipped, renamed or merged
Emit each heading at level `###`, text copied exactly.

### Issue Description
What was broken or missing, who it affected, why it matters. The ticket ID, if any.
### Steps to Reproduce
Numbered steps on the **base** branch: environment, preconditions, test data, expected result, actual result.
### Solution Provided
What changed and why this approach. Each changed file or module with a one-line reason. The alternatives `/architect` considered, if the plan records them.
### Impact Analysis – Proof That Existing Flows Are Not Affected
(The dash is an en dash `–`; copy the heading exactly.)
- Every existing flow that touches the changed code, and for each one how it was verified: unit test, integration test, real-browser check, or unaffected by design (say why).
- Each acceptance criterion mapped to its evidence.
- The code and flow verdicts, quoted, with the number of review cycles (if the files do not record it, write "cycles: not recorded"). The `latest-test-audit.md` result, quoted when the report exists (evidence only; it is not a PR gate).
- The test commands that ran and their results: pass counts, coverage delta if known.
- Risk tier, remaining risk, rollback plan. Anything you cannot verify is **stated here as unverified**.
### Before and After Screenshots
Table `Scenario | Before | After`, one row per affected screen or state. See section 6. No UI → "N/A – no UI changes", plus before / after logs, API responses or CLI output.

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
- **Never committed to any codebase.** `<slug>` is the branch name with `/` replaced by `-`. Store them in `.claude/workflow/pr-assets/<slug>/`, with `before/` and `after/` inside. Get the exclude file with `git rev-parse --git-path info/exclude` (in a worktree, `.git` is a file). If `git check-ignore -q <path>` fails, append the pr-assets path to that file, then confirm with `git check-ignore`. **Never edit `.gitignore`.**
- **After:** the Haiku agent runs the flow review's check script on the final state with `SHOTS=<absolute assets dir>/after sh tools/ui-browser-check/run.sh <frontend-dir> <check.mjs>` (Jarvis SPAs; another harness uses its own screenshot option). Or it copies the flow review's own screenshots of the same final state into `after/`, if they exist.
- **Before:** the same script on the base branch in a temporary `git worktree add` (a temp dir), with `SHOTS=<absolute assets dir>/before`. Remove the worktree afterwards (`git worktree remove`). If the screen did not exist on the base, the cell says so.
- A placeholder, such as `<!-- drag before-login.png here -->`, may name only a file that exists on disk. List the exact local paths below the table so the owner can drag them into the GitHub editor. A cell with no screenshot says "unverified — no screenshot (<reason>)", and Impact Analysis states it.
- A UI change with no check script → stop and ask. A check script is code, written by Sonnet.
- Before you finish, run `git status --porcelain --untracked-files=all` and `git ls-files`. If any `*.png`, `*.jpg`, `*.jpeg`, `*.gif` or `*.webp` is staged, tracked, or untracked outside `.claude/`, unstage it (`git restore --staged <path>`) and **stop to tell the owner**.

## 7. Output
- **Print the description in Markdown first.** Do not create or update the PR yet.
- After the owner **explicitly confirms**, **re-run both gates** (section 2, staleness included) **immediately before** the call. If anything differs from the gate 1 record — a new commit, an edited file, a RED or stale verdict — **do not create the PR**: say which gate failed.
- Then write the description to a file and run `gh pr create --body-file <file>` (new PR) or `gh pr edit --body-file <file>` (existing PR). Add no commit or PR attribution of your own; the project's and the owner's rules apply.
- **Never invent** a test result, flow, verdict, number or screenshot.

## Model assignment (SOP)
| Role | Model · effort |
|---|---|
| Write the description; the caller / flow search (T2/T3: the per-module explorers) | latest Sonnet · high |
| Run the check scripts for the before / after screenshots, and read them | Haiku |
| Write a new or changed check script (it is code) | latest Sonnet · high |

No Opus and no Fable are used by this command.

## Guardrails
- **No green, no description.** A RED, stale, missing or non-`/review-loop` verdict stops the command; it never writes around it.
- **Proof, not assumption.** Every flow, number and verdict comes from code, a file or a command you ran. Unverifiable items are stated as such.
- **Screenshots stay out of git.** No `.gitignore` edit; no image staged, tracked or untracked in the tree.
- **The owner confirms before the PR is created or edited**, and the gates run again first.
- Keep the five headings and their order, always.
