# Selftest cases: snapshot, review results, diff, stale, usage limit, errors.
# Sourced by selftest.sh (it holds the framework and the stub).

case_snapshot() {
  begin snapshot; fresh_repo
  echo changed >> a.txt; echo untracked > "un tracked.txt"
  mkdir .claude; echo s > .claude/secret; echo ign > ign.log
  git status --porcelain > /dev/null
  local before_st before_idx before_head
  before_st=$(git status --porcelain); before_idx=$(sha_of < .git/index); before_head=$(git rev-parse HEAD)
  local wt=$T/wtcopy$NCASE
  STUB_HOOK="cp -a . '$wt'" launch review --base main; waitrun
  local snap; snap=$(cat "$RUN/snapshot")
  want_true "untracked file in worktree" test -f "$wt/un tracked.txt"
  want_true "modified file in worktree" grep -q changed "$wt/a.txt"
  want_false ".claude excluded" test -e "$wt/.claude"
  want_false "ignored file excluded" test -e "$wt/ign.log"
  want_true "diff holds the untracked file" grep -q "un tracked.txt" "$RUN/stub.ctdiff"
  want "snapshot parent is HEAD" "$(git rev-parse "$snap^")" "$before_head"
  want "status unchanged" "$(git status --porcelain)" "$before_st"
  want "index unchanged" "$(sha_of < .git/index)" "$before_idx"
  want "HEAD unchanged" "$(git rev-parse HEAD)" "$before_head"
  finish
}

case_snapshot_claude_ignored() {  # .claude/ ignored by info/exclude or a root .gitignore: review and build still start
  begin snapshot_claude_ignored
  local how snap
  for how in exclude gitignore; do
    fresh_repo
    mkdir -p .claude/workflow/codex/old; echo x > .claude/workflow/codex/old/f; echo s > .claude/secret
    if [[ $how == exclude ]]; then echo '.claude/' >> .git/info/exclude
    else echo '.claude/' >> .gitignore; git add .gitignore; git commit -q -m ign; fi
    echo more >> a.txt
    launch review --base main; waitrun
    want "$how: review starts" "$ST" "done exit=0 | guard ok"
    snap=$(cat "$RUN/snapshot" 2>/dev/null)
    want "$how: review snapshot has no .claude path" "$(git ls-tree -r --name-only "${snap:-HEAD}" | grep -c '^\.claude')" 0
    do_build
    want "$how: build starts" "$ST" "done exit=0 | guard ok"
    snap=$(cat "$RUN/snapshot" 2>/dev/null)
    want "$how: build snapshot has no .claude path" "$(git ls-tree -r --name-only "${snap:-HEAD}" | grep -c '^\.claude')" 0
  done
  finish
}

case_snapshot_claude_tracked() {  # tracked .claude files stay at their HEAD content; later edits and new files stay out
  begin snapshot_claude_tracked; fresh_repo
  mkdir -p .claude; echo v1 > .claude/t; git add -f .claude/t; git commit -q -m tracked
  echo v2 > .claude/t; echo new > .claude/u; echo more >> a.txt
  launch review --base main; waitrun
  want "review starts" "$ST" "done exit=0 | guard ok"
  local snap; snap=$(cat "$RUN/snapshot" 2>/dev/null)
  want "tracked file at its HEAD content" "$(git show "${snap:-HEAD}:.claude/t" 2>/dev/null)" v1
  want "new untracked file is out" "$(git ls-tree -r --name-only "${snap:-HEAD}" | grep -c '^\.claude/u')" 0
  do_build
  want "build starts" "$ST" "done exit=0 | guard ok"
  finish
}

case_snapshot_too_big() {
  begin snapshot_too_big; fresh_repo
  truncate -s 51M big.bin
  launch review --base main; wait_rc
  want rc "$LRC" 4; want_has refused "$(cat "$LOUT")" "refused:"
  want "codex not started" "$(exec_calls)" 0
  want_false "no run dir" test -e "$R/.claude"
  want "no external worktree" "$(ls "$CODEX_TASK_HOME" 2>/dev/null | grep -c "^$(basename "$R")-")" 0
  want "registry empty" "$(ls "$CODEX_TASK_HOME/registry" 2>/dev/null | wc -l)" 0
  rm -f big.bin
  launch review --base main; waitrun
  want "small tree is fine" "$ST" "done exit=0 | guard ok"
  finish
}

case_no_commits() {  # a repository with no commit fails before the claim: no run dir, no registry entry
  begin no_commits
  NCASE=$((NCASE + 1)); export CODEX_TASK_HOME=$T/home$NCASE; : > "$T/calls"
  mkdir -p "$T/empty$NCASE" && cd "$T/empty$NCASE" && git init -q -b main . && R=$(pwd -P)
  launch review --plan "$T/plan.md"; wait_rc
  want_fail "plan review rc" "$LRC"; want_has "text" "$(cat "$LOUT.err")" "no commit"
  launch build "$P" "$A"; wait_rc
  want_fail "build rc" "$LRC"
  want_false "no run dir" test -e "$R/.claude"
  want "registry empty" "$(ls "$CODEX_TASK_HOME/registry" 2>/dev/null | wc -l)" 0
  want "codex never started" "$(exec_calls)" 0
  finish
}

case_rundir_layout() {
  begin rundir_layout; fresh_repo
  launch review --base main; waitrun
  local id=${RUN##*/}
  want_true "path under .claude/workflow/codex" test "$(dirname "$RUN")" = "$R/.claude/workflow/codex"
  want_true "run id shape" bash -c "[[ $id =~ ^[0-9]{8}-[0-9]{6}-review-[0-9a-f]+$ ]]"
  want ".gitignore" "$(cat "$RUN/.gitignore")" '*'
  want_true "wrapper.pid" test -s "$RUN/wrapper.pid"
  want "wrapper.pid holds the pid and the start time" "$(wc -w < "$RUN/wrapper.pid")" 2
  want_true "run.pgid" test -s "$RUN/run.pgid"
  want "run.pgid holds the pgid and the leader start time" "$(wc -w < "$RUN/run.pgid")" 2
  want_true "gitdir recorded" test -s "$RUN/gitdir"
  want "repo" "$(cat "$RUN/repo")" "$R"
  want "role" "$(cat "$RUN/role")" review
  want "run dir is private (umask 077)" "$(mode_of "$RUN")" 700
  want "run files are private" "$(mode_of "$RUN/wrapper.pid")" 600
  want "status in a repo without .claude is clean" "$(git status --porcelain)" ""
  local reg=$CODEX_TASK_HOME/registry/$id
  want_true "registry file" test -f "$reg"
  want_true "registry keys" bash -c "grep -q '^repo=' $reg && grep -q '^run=' $reg && grep -q '^worktree=' $reg && grep -q '^role=review' $reg && grep -q '^pgid=' $reg && grep -q '^wrapper=' $reg"
  do_build
  want "build done = exit and patch sha" "$(cat "$RUN/done")" "0 $(sha_of < "$RUN/patch.diff")"
  want_true "files.z" test -s "$RUN/files.z"
  finish
}

case_stage_nofollow() {  # a tracked CT-DIFF.patch (symlink or dir) must not redirect the write
  begin stage_nofollow; fresh_repo
  local victim=$T/victim$NCASE
  echo VICTIM > "$victim"; ln -s "$victim" CT-DIFF.patch
  git add CT-DIFF.patch; git commit -q -m link; echo more >> a.txt
  launch review --base main; waitrun
  want "status" "$ST" "done exit=0 | guard ok"
  want "the file outside the worktree is unchanged" "$(cat "$victim")" VICTIM
  want_false "CT-DIFF.patch is not a symlink" test -e "$RUN/stub.ctlink"
  want_true "the patch is the reviewed diff" cmp "$RUN/diff.txt" "$RUN/stub.ctdiff"
  launch review --plan "$T/plan.md"; waitrun
  want "plan: the file outside is unchanged" "$(cat "$victim")" VICTIM
  want_false "plan: not a symlink" test -e "$RUN/stub.ctlink"
  fresh_repo
  mkdir CT-DIFF.patch; echo x > CT-DIFF.patch/f; git add CT-DIFF.patch; git commit -q -m dir; echo more >> a.txt
  launch review --base main; waitrun
  want_has "a directory of that name fails the run" "$ST" "failed"
  want_false "nothing was written into the directory" test -e "$RUN/stub.argv"
  finish
}

# -- review results
GOOD='{"findings":[{"dimension":"x","severity":"MAJOR","file":"a.txt","line":3,"summary":"s","scenario":"c","fix":"f"}]}'
case_review_result() {
  begin review_result; fresh_repo
  STUB_FINAL=$GOOD launch review --base main; waitrun
  want status "$ST" "done exit=0 | guard ok"
  run_ct result "$RUN"
  want rc "$RC" 0; want json "$(jq -c . <<< "$OUT")" "$GOOD"
  STUB_FINAL='not json' launch review --base main; waitrun
  want_has "invalid json" "$ST" "failed"; want_false "no done" test -e "$RUN/done"
  run_ct result "$RUN"; want_fail "result refuses failed" "$RC"; want_has "status line" "$OUT" failed
  STUB_FINAL='{"x":1}' launch review --base main; waitrun
  want_has "wrong shape" "$ST" "failed"
  STUB_FINAL='{"findings":[{"dimension":"x"}]}' launch review --base main; waitrun
  want_has "missing keys" "$ST" "failed"
  STUB_FINAL='' launch review --base main; waitrun
  want_has "empty result is never success" "$ST" "failed"
  STUB_SLEEP=600 STUB_HOOK="$(UP_HOOK)" launch review --base main
  want_true "running" wait_state running
  run_ct result "$RUN"; want_fail "result refuses running" "$RC"; want_has "running line" "$OUT" running
  bash "$CT" cancel "$RUN" > /dev/null 2>&1
  finish
}

case_review_schema() {  # the full findings schema is enforced: enum, integer line, strings, no extra keys
  begin review_schema; fresh_repo
  local -a bad=(
    "$(jq -c '.findings[0].severity = "HUGE"' <<< "$GOOD")"
    "$(jq -c '.findings[0].line = "3"' <<< "$GOOD")"
    "$(jq -c '.findings[0].line = 1.5' <<< "$GOOD")"
    "$(jq -c '.findings[0].extra = 1' <<< "$GOOD")"
    "$(jq -c '.findings[0].summary = 7' <<< "$GOOD")"
    "$(jq -c '.extra = 1' <<< "$GOOD")"
    '[]'
  )
  local b
  for b in "${bad[@]}"; do
    STUB_FINAL=$b launch review --base main; waitrun
    want_has "refused: $b" "$ST" "failed"
  done
  STUB_FINAL='{"findings":[]}' launch review --base main; waitrun
  want "empty findings are valid" "$ST" "done exit=0 | guard ok"
  finish
}

case_result_not_review() {
  begin result_not_review; fresh_repo
  do_build
  run_ct result "$RUN"; want_fail "result refuses a build run" "$RC"
  finish
}

mk_diverged() {
  fresh_repo
  git checkout -q -b feat; echo f1 >> a.txt; git commit -qam f1
  git checkout -q main; echo m1 >> dir/b.txt; git commit -qam m1
  git checkout -q feat
}
case_diff_sha() {
  begin diff_sha; mk_diverged
  local three two exp
  three=$(git diff main...HEAD | sha_of); two=$(git diff main HEAD | sha_of)
  want_ne "recipes differ (base moved past the merge-base)" "$three" "$two"
  launch review --base main; waitrun
  want "committed: three-dot recipe" "$(cat "$RUN/diff-sha")" "$three"
  echo more >> a.txt; echo u > un.txt
  git add -N un.txt; exp=$(git diff main | sha_of); git reset -q -- un.txt
  want_ne "uncommitted differs from three-dot" "$exp" "$three"
  launch review --base main; waitrun
  want "uncommitted + 1 untracked: two-dot recipe" "$(cat "$RUN/diff-sha")" "$exp"
  want_true "patch uses the same range" grep -q "un.txt" "$RUN/stub.ctdiff"
  want "the hash is the hash of the patch Codex reads" "$(sha_of < "$RUN/stub.ctdiff")" "$exp"
  git checkout -q -- a.txt; rm -f un.txt; echo stray > stray.txt   # committed work + one stray untracked file
  git add -N stray.txt; exp=$(git diff main | sha_of); git reset -q -- stray.txt
  launch review --base main; waitrun
  want "committed + untracked file: two-dot recipe (the one rule)" "$(cat "$RUN/diff-sha")" "$exp"
  rm stray.txt
  launch review --base main; waitrun
  want "committed and clean: three-dot recipe" "$(cat "$RUN/diff-sha")" "$three"
  finish
}

case_diff_flags() {  # user diff config must not change the patch or its hash
  begin diff_flags; mk_diverged
  local exp; exp=$(git diff main...HEAD | sha_of)
  printf '#!/bin/sh\nexit 1\n' > "$T/extdiff.sh"; chmod +x "$T/extdiff.sh"
  git config diff.noprefix true; git config diff.mnemonicPrefix true
  git config color.ui always; git config diff.external "$T/extdiff.sh"
  launch review --base main; waitrun
  want "status" "$ST" "done exit=0 | guard ok"
  want "hash ignores user diff config" "$(cat "$RUN/diff-sha")" "$exp"
  want_true "a/ b/ prefixes" grep -q '^diff --git a/a.txt b/a.txt' "$RUN/stub.ctdiff"
  want_false "no colour codes" grep -q $'\033' "$RUN/stub.ctdiff"
  finish
}

case_diff_too_large() {
  begin diff_too_large; fresh_repo
  seq 1 5000 > big.txt; printf '\377\000\377\001\002' > bin.dat
  CODEX_TASK_MAX_DIFF_BYTES=1000 launch review --base main; wait_rc
  want rc "$LRC" 4; want_has text "$(cat "$LOUT")" "refused: diff too large"
  want "codex not started" "$(exec_calls)" 0
  want "no run dir left" "$(ls "$R/.claude/workflow/codex" 2>/dev/null | wc -l)" 0
  want "registry empty" "$(ls "$CODEX_TASK_HOME/registry" 2>/dev/null | wc -l)" 0
  want "no external worktree" "$(ls "$CODEX_TASK_HOME" 2>/dev/null | grep -c "^$(basename "$R")-")" 0
  rm big.txt
  launch review --base main; waitrun
  want "a small diff is fine" "$ST" "done exit=0 | guard ok"
  want_false "the patch has no binary payload" grep -q 'GIT binary patch' "$RUN/stub.ctdiff"
  want_true "the patch names the binary file" grep -q '^Binary files' "$RUN/stub.ctdiff"
  finish
}

case_stale() {  # a hash that differs at start is refused: exit 4, no run, no stale state
  begin stale; mk_diverged
  launch review --base main; waitrun
  local sha n; sha=$(cat "$RUN/diff-sha")
  launch review --base main --expect-sha "$sha"; waitrun
  want "matching sha" "$ST" "done exit=0 | guard ok"
  n=$(ls "$R/.claude/workflow/codex" | wc -l); : > "$T/calls"
  launch review --base main --expect-sha deadbeef; wait_rc
  want "rc" "$LRC" 4
  want "text" "$(cat "$LOUT")" "refused: stale (expected deadbeef, saw $sha)"
  want "no run printed" "$RUN" ""
  want "codex not started" "$(exec_calls)" 0
  want "no run dir left" "$(ls "$R/.claude/workflow/codex" | wc -l)" "$n"
  want "registry has no live entry" "$(ls "$CODEX_TASK_HOME/registry" | wc -l)" "$n"
  launch review --plan "$T/plan.md" --expect-sha deadbeef; wait_rc
  want "stale plan: rc" "$LRC" 4; want_has "stale plan: text" "$(cat "$LOUT")" "refused: stale"
  finish
}

case_plan_base() {
  begin plan_base; fresh_repo
  run_ct review --plan "$T/plan.md" --base main
  want "rc" "$RC" 1; want_has "text" "$OUT" "--plan"
  want_false "no run dir" test -e "$R/.claude"
  want "codex not started" "$(exec_calls)" 0
  finish
}

case_base_option() {  # --base is resolved to a commit; an option-like value is refused
  begin base_option; fresh_repo
  run_ct review --base --stat; want "option-like base: rc" "$RC" 1; want_has "text" "$OUT" "unknown base"
  run_ct review --base nosuchref; want "unknown base: rc" "$RC" 1
  git tag release-1
  launch review --base release-1; waitrun
  want "a tag works as the base" "$ST" "done exit=0 | guard ok"
  finish
}

# -- usage limit
case_limit_error() {
  begin limit_error; fresh_repo
  STUB_EXIT=1 STUB_ERROR="You've hit your usage limit. Try again at 3:04 PM." launch review --base main; waitrun
  want_has "limited" "$ST" "limited until 3:04 PM"
  want_false "stderr empty (per the spike)" test -s "$RUN/stderr.txt"
  want_false "-o file empty" test -s "$RUN/final.txt"
  rm -f "$CODEX_TASK_HOME/limited-until"
  STUB_EXIT=1 STUB_STDERR="usage limit reached, try again in 2 hours" launch review --base main; waitrun
  want_has "limit on stderr" "$ST" "limited until 2 hours"
  finish
}

case_limit_remember() {  # a usage limit is remembered; starts are refused until it ends
  begin limit_remember; fresh_repo
  local f=$CODEX_TASK_HOME/limited-until now; now=$(date +%s)
  STUB_EXIT=1 STUB_ERROR="usage limit. Try again in 3 hours." launch review --base main; waitrun
  want_true "limited-until written" test -s "$f"
  want_true "the end is about 3 hours away" bash -c "e=\$(cut -d' ' -f1 '$f'); ((e > $now + 10000 && e < $now + 11500))"
  : > "$T/calls"
  launch review --base main; wait_rc
  want "start refused: rc" "$LRC" 3
  local abs; abs=$(date -d "@$(cut -d' ' -f1 "$f")" '+%F %H:%M')
  want_has "start refused: text (the absolute time)" "$(cat "$LOUT")" "not available: usage limit until $abs"
  want "codex not started" "$(exec_calls)" 0
  run_ct check review; want_fail "check says not available" "$RC"; want_has "check text" "$OUT" "usage limit until"
  echo "1 an old limit" > "$f"
  launch review --base main; waitrun
  want "a limit in the past does not refuse" "$ST" "done exit=0 | guard ok"
  rm -f "$f"
  STUB_EXIT=1 STUB_STDERR="usage limit reached" launch review --base main; waitrun
  want_has "no time given" "$ST" "limited until unknown"
  want_false "an unparsable time is not remembered" test -e "$f"
  finish
}

case_limit_forms() {  # ordinals, 8-day cap, +1 day only for "at HH:MM", sanitised text
  begin limit_forms; fresh_repo
  local f=$CODEX_TASK_HOME/limited-until now e t; now=$(date +%s)
  STUB_EXIT=1 STUB_ERROR="usage limit. Try again at Dec 5th, 2031 3:04 PM." launch review --base main; waitrun
  e=$(cut -d' ' -f1 "$f" 2>/dev/null || echo 0)
  want_true "far future with an ordinal is parsed and capped at 8 days" test "$e" -gt $((now + 7 * 86400)) -a "$e" -le $((now + 8 * 86400 + 60))
  rm -f "$f"
  STUB_EXIT=1 STUB_ERROR="usage limit. Try again at $(date -d '1 minute ago' +%H:%M)." launch review --base main; waitrun
  e=$(cut -d' ' -f1 "$f" 2>/dev/null || echo 0)
  want_true "a clock time already past means tomorrow" test "$e" -gt $((now + 23 * 3600)) -a "$e" -le $((now + 86400 + 120))
  rm -f "$f"
  STUB_EXIT=1 STUB_ERROR=$'usage limit. Try again in 2 hours\a\r' launch review --base main; waitrun
  e=$(cut -d' ' -f1 "$f" 2>/dev/null || echo 0)
  want_true "a relative time gets no extra day" test "$e" -gt $((now + 7000)) -a "$e" -lt $((now + 7500))
  want_false "no control characters in the status" bash -c "printf %s '$ST' | grep -q '[[:cntrl:]]'"
  want_false "no control characters in the saved text" bash -c "grep -q '[[:cntrl:]]' '$f'"
  rm -f "$f"
  STUB_EXIT=1 STUB_ERROR="usage limit. Try again at $(head -c 300 /dev/zero | tr '\0' x)" launch review --base main; waitrun
  t=${ST#limited until }; t=${t%% | guard*}
  want_true "the text is cut to 80 characters" test "${#t}" -le 80 -a "${#t}" -gt 0
  want_false "an unparsable time is not saved" test -e "$f"
  finish
}

case_limit_clear() {  # check --clear-limit removes the saved limit
  begin limit_clear; fresh_repo
  local f=$CODEX_TASK_HOME/limited-until
  mkdir -p "$CODEX_TASK_HOME"; echo "$(($(date +%s) + 3600)) some day" > "$f"
  run_ct check review; want_fail "limited" "$RC"
  run_ct check --clear-limit; want "clear rc" "$RC" 0; want_has "clear text" "$OUT" "cleared"
  want_false "file removed" test -e "$f"
  run_ct check review; want "available again" "$OUT" available
  run_ct check --clear-limit; want "nothing to clear: rc" "$RC" 0
  finish
}

case_limit_only_on_error() {
  begin limit_only_on_error; fresh_repo
  STUB_EXIT=0 STUB_ERROR="usage limit hit, try again at noon" launch review --base main; waitrun
  want "exit 0 is never limited" "$ST" "done exit=0 | guard ok"
  want_false "exit 0 writes no limit" test -e "$CODEX_TASK_HOME/limited-until"
  STUB_EXIT=1 STUB_AGENT_TEXT="rate limit: usage limit, try again at noon" launch review --base main; waitrun
  want_has "agent text is not a limit" "$ST" "done exit=1"
  want_no "not limited" "$ST" limited
  STUB_AGENT_TEXT="we hit a rate limit, please try again" launch review --base main; waitrun
  want "rate limit text in an exit-0 run" "$ST" "done exit=0 | guard ok"
  finish
}

case_error_text() {
  begin error_text; fresh_repo
  STUB_EXIT=1 STUB_STDERR="stderr line" STUB_ERROR="event error text" launch review --base main; waitrun
  want "the first error event wins over stderr" "$ST" "done exit=1 error: event error text | guard ok"
  STUB_EXIT=1 STUB_STDERR="stderr line" launch review --base main; waitrun
  want "stderr is the fallback" "$ST" "done exit=1 error: stderr line | guard ok"
  STUB_EXIT=1 launch review --base main; waitrun
  want "no message: no empty suffix" "$ST" "done exit=1 | guard ok"
  STUB_EXIT=124 STUB_ERROR="something else" launch review --base main; waitrun
  want "124 is a timeout" "$ST" "done exit=124 error: timed out | guard ok"
  STUB_EXIT=137 launch review --base main; waitrun
  want "137 is a kill" "$ST" "done exit=137 error: killed | guard ok"
  finish
}

case_timeout() {  # CODEX_TASK_TIMEOUT bounds a run; timeout exits 124
  begin timeout; fresh_repo
  CODEX_TASK_TIMEOUT=1s STUB_SLEEP=20 launch review --base main; waitrun
  want "timed-out run" "$ST" "done exit=124 error: timed out | guard ok"
  CODEX_TASK_TIMEOUT=abc run_ct review --base main
  want "a bad timeout is refused" "$RC" 1; want_has "text" "$OUT" "CODEX_TASK_TIMEOUT"
  finish
}

case_git_umask() {  # the caller's umask applies to git objects written into the user's repo
  begin git_umask; fresh_repo
  echo untracked > new.txt
  local old; old=$(umask); umask 022
  launch review --base main; waitrun
  do_build 'echo blob > b.txt' 'b.txt'
  umask "$old"
  want_true "the build ran" test -s "$RUN/patch.diff"
  want "no private dirs in the object store" "$(find "$R/.git/objects" -type d -perm 700 | wc -l)" 0
  want "the run dir stays private" "$(mode_of "$RUN")" 700
  finish
}
