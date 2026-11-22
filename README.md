# claude-tool

Custom [Claude Code](https://claude.com/claude-code) slash commands for a **risk-tiered, evidence-first development cycle**.

Install, in one of two ways. The tools need Google Chrome and Node 18 or newer.

Copy (run again after each pull):

```sh
cp commands/*.md ~/.claude/commands/; mkdir -p ~/.claude/tools && cp -r tools/* ~/.claude/tools/ && (cd ~/.claude/tools/gh-image-upload && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci)
```

Link (a clone that you keep up to date with `git pull`). If `~/.claude/tools` is already a real directory, move or remove it first.

```sh
ln -sf "$PWD"/commands/*.md ~/.claude/commands/ && ln -sfn "$PWD/tools" ~/.claude/tools && (cd tools/gh-image-upload && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci)
```

If `~/.claude/tools` is already a symlink to the `tools` folder of this clone, use the link variant. The copy variant fails with "same file".

For an existing clone at `~/review`, run this one line:

```sh
ln -sfn ~/review/tools ~/.claude/tools && (cd ~/review/tools/gh-image-upload && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci)
```

Then, once, the owner signs in to GitHub for the screenshot upload:

```sh
node ~/.claude/tools/gh-image-upload/upload.mjs --login
```

On a server with no screen, the owner types `xvfb-run -a node ~/.claude/tools/gh-image-upload/upload.mjs --login --terminal` in their own terminal.

## Codex / GPT-6 Astra

The seven workflows are also available as self-contained [Codex skills](./codex/skills).
The official model identifier is `gpt-6-astra` (rather than `chatgpt-6-astra`).
Select that model in your Codex client, or start the CLI with:

```sh
codex --model gpt-6-astra
```

These are instruction-only skills, not API clients or tools for ordinary ChatGPT
without a local skill-capable environment. They use the current session and do not
set a model, change authentication, or require another API key. Access to the model
depends on your client/account. The original Claude commands remain unchanged.

Install from a stable checkout of this branch:

```sh
python3 scripts/install_codex.py --dry-run
python3 scripts/install_codex.py
```

This creates seven symlinks under `~/.agents/skills`, the user-level Codex discovery
location. It refuses to replace existing directories or conflicting links and can
be rerun safely. Keep this checkout in place; edits and branch switches affect the
linked skills. To install for only one project, pass `--destination /path/to/repo/.agents/skills`.
To uninstall, remove only these seven symlinks from the destination; the source stays.
If the skills do not appear after installation, restart the Codex session.

| Claude command | Codex invocation |
|---|---|
| `/architect` | `$ct-architect` |
| `/plan-check` | `$ct-plan-check` |
| `/implement` | `$ct-implement` |
| `/review-loop` | `$ct-review-loop` |
| `/pr-description` | `$ct-pr-description` |
| `/wear-the-coat` | `$ct-wear-the-coat` |
| `/release-notes` | `$ct-release-notes` |

Normal automatic skill selection remains enabled. For ongoing work, select the
relevant stage rather than loading all seven: architecture for design choices,
plan checking for a proposal, implementation for authorized changes, review for a
diff, persona audit for an experience question, release notes for specified PRs,
PR description for a change with a GREEN review.
Explicit invocation is available when you want a particular workflow.

### Jarvis SOP and readiness

For authorized Jarvis feature and fix work, follow **ct-architect → ct-plan-check →
ct-implement → ct-review-loop + ct-wear-the-coat → ct-pr-description**. Load each stage when needed and
scale its effort to risk; small edits need brief reasoning, not a large ceremony.
A request only to explain, plan or review remains within that requested scope.
Existing authorization carries forward without repeated approval questions.

Readiness requires evidence for the relevant failure scenarios, prohibited side
effects, supported environments, affected existing controls and data lifecycle.
Reviewer findings need individual dispositions and verification. Report unresolved
gaps explicitly; green CI and self-review do not establish independent validation.
These requirements live in the stage skills so they apply when invoked separately.

### Adaptation decisions

- Retain evidence, acceptance criteria, eight review dimensions, cross-repo user
  journeys, failure recovery, and the Jarvis release-note rules.
- Replace Claude model aliases and slash-command/tool assumptions with the current
  Codex session and available tools. Delegation is conditional on explicit authority
  and availability; there is no mandatory multi-agent panel or silent model switch.
- Remove required dependencies on unbundled skills. Each Codex skill stands alone.
- Scale review/test effort to risk. Avoid repeated approval requests, universal
  mutation tests, or endless review loops. Keep planning and report-only requests
  distinct from authorization to implement, publish, or merge.
- Keep the `ct-` prefix to avoid collisions with other installed skills.

Run installer tests with `python3 -m unittest discover -s tests -v`. Structural skill
validation and installer tests do not constitute a live model quality evaluation.
Useful manual checks: a trivial edit should not demand a review panel; a read-only
review should not edit; a migration plan should address populated data and rollback;
release notes should omit an unmerged PR and report why.

Sources checked September 25, 2026: [Astra skill guidance](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra),
[Codex skill discovery](https://learn.chatgpt.com/docs/build-skills), and
[GPT-6 Astra model identifier](https://developers.openai.com/api/docs/models/gpt-6-astra).

## The cycle

```
/architect      → generate  — evidence-first, diverge-wide/converge-precise solution + plan
/plan-check     → front gate — pressure-test the plan against every quality dimension
/implement      → middle gate — build to the acceptance criteria (TDD + per-task review)
/review-loop    → back gate  — multi-dimension eight-lane-floor review, looped to green
/wear-the-coat  → user axis  — persona-driven lived-experience audit of a flow
/pr-description → final step — evidence-backed PR description, gated on a GREEN review
```

**Generator → critic → builder → verifier.** The acceptance criteria are the through-line: `/plan-check` emits them, `/implement` builds to them, `/review-loop` verifies against them. `/architect` never grades its own plan — it hands to `/plan-check`.

Every command **scales to a risk tier** (T0 trivial → T3 high-stakes), classified by blast radius × reversibility, so cost matches the stakes.

## The pipeline

PLAN → BUILD → CODE REVIEW → FLOW REVIEW → GREEN → COMMIT → PR

This is the team's development pipeline. It used to be a `CLAUDE.md` inside the product repository; it lives here now, so it applies wherever these commands are used.

1. **No code without an approved plan.** Planning is `/architect` and `/plan-check`, done by Opus 5.5 at high effort. The plan is written to `.claude/workflow/plans/` in the working tree (untracked) and must read `STATUS: APPROVED`, by the owner, before anything is built.
2. **Implementation is `/implement`**, and starts only once the plan is approved. Every task is built by the latest Sonnet at high effort.
3. **No `git commit` until an adversarial reviewer has written `VERDICT: GREEN`** in BOTH `.claude/workflow/reviews/latest-code.md` and `.claude/workflow/reviews/latest-flow.md` for the current change set. The reviewer is a fresh agent, never the one that wrote the code: a Sonnet reviewer for the code verdict, a Haiku agent running the browser checks for the flow verdict.
4. **No `git commit` until the test-audit report exists.** After the last `git add`, run the `test-audit` skill as analysis only on the staged diff. `.claude/workflow/reviews/latest-test-audit.md` must read `TEST-AUDIT: DONE` on its first line and be newer than the git index: write it after the last `git add`, and write it again after any re-stage (a pre-commit reformat). Removals are proposed to the owner, never deleted silently.
5. **No PR until a flow review passed on the final state being pushed**: actually executed against the running app (Playwright in real Chrome). Any change after the last flow review makes it stale: run it again. For a change with nothing to run (documentation only), say so in the PR instead. The PR description is written with `/pr-description`, and the PR is created only on a GREEN `/review-loop`.
6. **RED verdict → fix every BLOCKER and MAJOR → re-review** (one sweep reviewer over the fix diff; the full panel is cycle 1 only: `/review-loop`, "Testing budget"). Findings are never argued away or self-downgraded; only the reviewer withdraws a finding.
7. **Scope changes mid-build go back to planning** for re-approval first.

The goal: strict reviews, high-grade code quality, an architecture that survives adversarial testing. When in doubt, the stricter interpretation wins.

## Which model does what

| Stage | Commands | Model · effort |
|---|---|---|
| Planning | `architect`, `plan-check` | Opus 5.5 · high, for the controller and every agent it dispatches |
| Implementation | `implement` | the latest Sonnet · high, for every task, and only once the plan is approved |
| Review | `review-loop`, the per-task reviews of `implement` | Sonnet, for every lane and for the reviewer that writes the code verdict; also the pre-commit `test-audit` (analysis only) |
| Browser testing | the real-browser gate and the flow review | Haiku: it runs the check scripts in Chrome, applies their pass rule, reads the screenshots and writes the flow verdict. A check script is code and is written by Sonnet |
| PR description | `pr-description` | the latest Sonnet · high writes it and does the caller / flow search; Haiku runs the check scripts for the before / after screenshots, reads them and uploads them with `gh-image-upload` |
| Persona audit | `wear-the-coat` | as that command's own table says |

A task Sonnet cannot get right is taken back to planning, not handed to a bigger model.

**Testing is kept proportionate.** The gates stay (a GREEN code verdict, a GREEN flow verdict, UI checked in real Chrome); the time and tokens around them are kept low: the full review panel runs once, later cycles are one sweep reviewer over the fix diff, the browser run executes the existing scripts once on the final tree, and a mutation run is made per rule a change introduces, not per assertion. The rules are in `/review-loop`, "Testing budget".

## Commands

| Command | Role |
|---|---|
| `architect` | Evidence-first solution architect — explore (codebase + web) → all viable solutions with proof → agree → plan. |
| `plan-check` | Planning pressure-test — stress a plan/spec/approach against every dimension *before* code. |
| `implement` | Build to the criteria with the quality dimensions as live guardrails. |
| `review-loop` | Multi-dimension Phase-1-floor review loop with a coverage gate. |
| `wear-the-coat` | Wear a profession's coat and audit a flow's lived experience. |
| `pr-description` | Write the PR description once the review is GREEN — five short fixed sections in Simplified Technical English, screenshots uploaded as GitHub attachments so they show inline (never in git). |

## UI is verified in a real browser

Whenever a change touches UI, the cycle requires it to be **opened in real Chrome through
Playwright and looked at**; code reading and component tests are not enough. `architect` and
`plan-check` put the browser check in the acceptance criteria, `implement` runs it before
claiming done, `review-loop` gates the green on it (its **Real-browser gate**), and
`wear-the-coat` runs its click-tests instead of only listing them.

[`tools/ui-browser-check/`](./tools/ui-browser-check) is the runner used for the Jarvis SPAs:
it serves a checkout or git worktree on its own port and runs one Playwright check script
against it, with the API answered in the script. See its README.

[`tools/gh-image-upload/`](./tools/gh-image-upload) uploads the before / after screenshots to GitHub as PR
attachments through real Chrome, so `/pr-description` can embed them inline without committing them.

## Project tools

Project-specific commands (not part of the generic cycle above):

| Command | Role |
|---|---|
| `release-notes` | **Jarvis** release-notes generator — turn a set of merged jarvis-app PRs into customer-facing, grouped notes (New / Improvements / Fixes / Action needed) ready to paste into a Jarvis Changelog. User-facing only; internal changes dropped. Local + manual (the LLM is your Claude session, no service to call); read-only (`gh pr view`). Needs `gh` read access to `Aerele-RnD/jarvis`. |
