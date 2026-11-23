# Selftest cases: registry, limits, processes, cancel, clean, guard, worktree hardening.
# Sourced by selftest.sh (it holds the framework and the stub).

# -- registry
case_limits() {
  begin limits; fresh_repo
  STUB_SLEEP=600 start_build
  local b1=$RUN; want_true "build 1 running" wait_state running
  local n; n=$(ls "$R/.claude/workflow/codex" | wc -l)
  launch build "$P" "$A"; wait_rc
  want "2nd build: distinct exit code" "$LRC" 4; want_has "2nd build text" "$(cat "$LOUT")" "refused:"
  want "no run dir left" "$(ls "$R/.claude/workflow/codex" | wc -l)" "$n"
  second_repo
  launch build "$P" "$A"; wait_rc
  want "2nd build from a second repo" "$LRC" 4
  want_false "no run dir in 2nd repo" test -e "$R2/.claude"
  cd "$R" || return
  STUB_SLEEP=600 launch review --base main; local r1=$RUN
  want_true "review next to a build is allowed" test -d "$r1"
  launch review --base main; wait_rc
  want "3rd run refused" "$LRC" 4; want_has "3rd text" "$(cat "$LOUT")" "refused:"
  bash "$CT" cancel "$b1" > /dev/null 2>&1; bash "$CT" cancel "$r1" > /dev/null 2>&1
  launch review --base main; waitrun
  want "slots free after cancel" "$ST" "done exit=0 | guard ok"
  finish
}

case_limits_reviews() {
  begin limits_reviews; fresh_repo
  STUB_SLEEP=600 launch review --base main; local a=$RUN
  STUB_SLEEP=600 launch review --base main; local b=$RUN
  want_true "two reviews run" test -d "$b"
  launch review --base main; wait_rc
  want "3rd review refused" "$LRC" 4
  STUB_SLEEP=600 launch build "$P" "$A"; wait_rc
  want "build refused while 2 are live" "$LRC" 4
  bash "$CT" cancel "$a" > /dev/null 2>&1; bash "$CT" cancel "$b" > /dev/null 2>&1
  finish
}

case_wrapper_cleans() {  # the wrapper frees the external worktree itself once done or failed is written
  begin wrapper_cleans; fresh_repo
  launch review --base main; waitrun
  local wt id=${RUN##*/}; wt=$(cat "$RUN/worktree")
  want "review status" "$ST" "done exit=0 | guard ok"
  want_false "review: worktree dir removed" test -e "$wt"
  want_false "review: worktree listing removed" bash -c "git worktree list | grep -q '$id'"
  want_true "run dir kept for the status" test -d "$RUN"
  do_build; wt=$(cat "$RUN/worktree")
  want_false "build: worktree dir removed" test -e "$wt"
  run_ct apply "$RUN"; want "apply works after the worktree is gone" "$RC" 0
  STUB_EXIT=3 do_build; wt=$(cat "$RUN/worktree")
  want_has "exit 3 status" "$ST" "done exit=3"; want_false "exit 3: worktree removed" test -e "$wt"
  STUB_FINAL='not json' launch review --base main; waitrun; wt=$(cat "$RUN/worktree")
  want_has "failed status" "$ST" "failed"; want_false "failed: worktree removed" test -e "$wt"
  STUB_HOOK='mkdir -p .claude; echo x > .claude/x' launch review --base main; waitrun; wt=$(cat "$RUN/worktree")
  want "guard changed status" "$ST" "done exit=0 | guard changed"
  want_true "guard changed: worktree kept for the owner" test -d "$wt"
  run_ct clean "$RUN"; want "clean removes it" "$RC" 0; want_false "gone after clean" test -e "$wt"
  finish
}

case_list_lost_run() {  # the run dir (inside a removed Claude worktree) is gone; the registry still finds the run
  begin list_lost_run; fresh_repo
  git worktree add -q -b lwb "$T/lw$NCASE" > /dev/null 2>&1
  cd "$T/lw$NCASE" || return
  STUB_SLEEP=600 STUB_HOOK="$(SLEEPER_HOOK); $(UP_HOOK)" launch review --base main
  local id=${RUN##*/} wt; wt=$(cat "$RUN/worktree")
  want_true "up" wait_up
  cd "$R" || return
  git worktree remove --force "$T/lw$NCASE"
  want_true "external worktree survives" test -d "$wt"
  run_ct list; want_has "list finds the run" "$OUT" "$id"
  run_ct status "$id"; want_has "status says lost" "$OUT" "lost"
  run_ct clean "$id"; want_fail "clean refuses a live run whose dir is gone" "$RC"
  run_ct cancel "$id"; want "cancel by id rc" "$RC" 0; want_has "cancel text" "$OUT" cancelled
  want "no stub process" "$(stub_procs)" 0
  want_true "sleeper stopped" pid_gone "$(cat "$T/sleeper.pid")"
  run_ct clean "$id"; want "clean by id" "$RC" 0
  want_false "external worktree removed" test -e "$wt"
  run_ct list; want_no "list is empty again" "$OUT" "$id"
  finish
}

# -- processes
case_cancel() {
  begin cancel; fresh_repo
  STUB_SLEEP=600 STUB_HOOK="$(SLEEPER_HOOK); $(UP_HOOK)" launch review --base main
  local wt; wt=$(cat "$RUN/worktree")
  want_true "stub and its own-group child are up" wait_up
  run_ct cancel "$RUN"; want "cancel rc" "$RC" 0
  want "no process left in the worktree" "$(procs_in "$wt")" 0
  want "no stub process" "$(stub_procs)" 0
  want_true "own-group child stopped" pid_gone "$(cat "$T/sleeper.pid")"
  want_has "status" "$(bash "$CT" status "$RUN")" "cancelled"
  wait_rc
  want_false "wrapper gone" kill -0 "$LPID"
  finish
}

case_cancel_repeat() {  # cancel works again while processes are still busy (an earlier cancel did not finish)
  begin cancel_repeat; fresh_repo
  STUB_SLEEP=600 STUB_HOOK="$(UP_HOOK)" launch review --base main
  want_true "up" wait_up
  : > "$RUN/cancelled"
  run_ct cancel "$RUN"; want "rc" "$RC" 0; want "text" "$OUT" cancelled
  want "no stub process" "$(stub_procs)" 0
  wait_rc; want_false "wrapper gone" kill -0 "$LPID"
  run_ct cancel "$RUN"; want_has "a second cancel finds nothing" "$OUT" "nothing to cancel"
  finish
}

case_cancel_in_setup() {  # cancel while the wrapper still sets up: no worktree, no Codex
  begin cancel_in_setup; fresh_repo
  PATH=$T/shim:$PATH SHIM_ON=diff SHIM_SLEEP=3 bash "$CT" review --base main > "$T/setup.out" 2>&1 &
  LPID=$!; LPIDS+=("$LPID")
  local i d=""
  for ((i = 0; i < 50; i++)); do
    d=$(ls "$R/.claude/workflow/codex" 2>/dev/null | head -1)
    [[ -n $d ]] && break
    sleep 0.1
  done
  want_ne "the run dir exists during setup" "$d" ""
  run_ct cancel "$R/.claude/workflow/codex/$d"; want "cancel rc" "$RC" 0
  wait_rc
  want "codex not started" "$(exec_calls)" 0
  want "no external worktree" "$(ls "$CODEX_TASK_HOME" | grep -c "^$(basename "$R")-")" 0
  want_has "status" "$(bash "$CT" status "$R/.claude/workflow/codex/$d")" cancelled
  finish
}

case_sigkill_orphan() {
  begin sigkill_orphan; fresh_repo
  STUB_SLEEP=600 STUB_HOOK="$(SLEEPER_HOOK); $(UP_HOOK)" launch review --base main
  local wt; wt=$(cat "$RUN/worktree"); local id=${RUN##*/}
  want_true "up" wait_up
  kill -KILL "$LPID"; wait "$LPID" 2>/dev/null
  want_true "orphan" wait_state orphan 50
  run_ct clean "$RUN"; want_fail "clean refuses an orphan" "$RC"
  want_true "run dir kept" test -d "$RUN"
  run_ct cancel "$RUN"; want "cancel rc" "$RC" 0
  want "0 processes in the worktree" "$(procs_in "$wt")" 0
  want "0 stub processes" "$(stub_procs)" 0
  want_true "own-group child stopped" pid_gone "$(cat "$T/sleeper.pid")"
  run_ct clean "$RUN"; want "clean rc" "$RC" 0
  want_false "no worktree dir" test -e "$wt"
  want_false "no run dir" test -e "$RUN"
  want_false "no worktree in the list" bash -c "git worktree list | grep -q '$id'"
  want "registry empty" "$(ls "$CODEX_TASK_HOME/registry" | wc -l)" 0
  finish
}

case_term_wrapper() {
  begin term_wrapper; fresh_repo
  STUB_SLEEP=600 STUB_HOOK="$(SLEEPER_HOOK); $(UP_HOOK)" launch review --base main
  local wt; wt=$(cat "$RUN/worktree")
  want_true "up" wait_up
  kill -TERM "$LPID"; wait "$LPID" 2>/dev/null
  want "no stub process" "$(stub_procs)" 0
  want "no process left in the worktree" "$(procs_in "$wt")" 0
  want_true "own-group child stopped" pid_gone "$(cat "$T/sleeper.pid")"
  want_true "a signalled wrapper records failed (not died)" wait_state "failed terminated by signal" 50
  wait_for_gone_dir "$(cat "$RUN/worktree")"
  want_false "the worktree is freed" test -e "$(cat "$RUN/worktree")"
  finish
}

case_clean_kills_strays() {  # a sandbox child outside the Codex group is stopped before clean removes the worktree
  begin clean_kills_strays; fresh_repo
  STUB_SLEEP=600 STUB_HOOK="$(SLEEPER_HOOK); $(UP_HOOK)" launch review --base main
  local wt; wt=$(cat "$RUN/worktree")
  want_true "up" wait_up
  kill -KILL "$LPID"; wait "$LPID" 2>/dev/null
  kill -KILL -- "-$(cut -d' ' -f1 "$RUN/run.pgid")" 2>/dev/null
  want_true "both gone, one stray left: died" wait_state died 50
  want_true "the stray is alive" pid_up "$(cat "$T/sleeper.pid")"
  run_ct clean "$RUN"; want "clean rc" "$RC" 0
  want_true "the stray is stopped" pid_gone "$(cat "$T/sleeper.pid")"
  want_false "worktree removed" test -e "$wt"
  finish
}

case_pid_reuse() {  # the wrapper is alive only when pid and start time both match
  begin pid_reuse; fresh_repo
  launch review --base main; waitrun
  rm -f "$RUN/done"
  sleep 600 & local sp=$! st
  st=$(sed 's/.*) //' "/proc/$sp/stat" | cut -d' ' -f20)
  printf '%s %s\n' "$sp" "$st" > "$RUN/wrapper.pid"
  want "same pid, same start: running" "$(bash "$CT" status "$RUN" | cut -d' ' -f1)" running
  printf '%s %s\n' "$sp" "$((st + 1))" > "$RUN/wrapper.pid"
  want "same pid, other start: died" "$(bash "$CT" status "$RUN" | cut -d' ' -f1)" died
  kill -KILL "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  finish
}

wait_for_gone_dir() { local i; for ((i = 0; i < 100; i++)); do [[ -e $1 ]] || return 0; sleep 0.1; done; return 1; }

# -- retire, clean and the retire window
case_retire_readonly() {  # read-only dirs left by Codex do not leak the worktree
  begin retire_readonly; fresh_repo
  do_build 'mkdir -p ro/sub; echo x > ro/sub/f; chmod -R a-w ro; echo n > new.txt' 'new.txt'
  local wt id=${RUN##*/}; wt=$(cat "$RUN/worktree")
  want "status" "$ST" "done exit=0 | guard ok"
  want_false "worktree dir removed" test -e "$wt"
  want_false "worktree registration removed" bash -c "git worktree list | grep -q '$id'"
  want_false "no admin dir left" bash -c "ls '$R/.git/worktrees' 2>/dev/null | grep -q ."
  finish
}

case_retire_failed() {  # a removal that fails is visible in status, and clean does not claim success
  begin retire_failed; fresh_repo
  STUB_HOOK="chmod a-w '$CODEX_TASK_HOME'" launch review --base main; waitrun
  local wt; wt=$(cat "$RUN/worktree")
  want_has "status shows the failed retire" "$ST" "retire-failed"
  want_true "the worktree is still there" test -d "$wt"
  run_ct clean "$RUN"
  want "clean fails" "$RC" 1; want_has "clean text" "$OUT" "could not remove"
  want_true "run dir kept" test -d "$RUN"
  want_true "registry kept" test -f "$CODEX_TASK_HOME/registry/${RUN##*/}"
  chmod u+w "$CODEX_TASK_HOME"
  run_ct clean "$RUN"; want "clean works once the dir is writable" "$RC" 0
  want_false "worktree gone" test -e "$wt"
  finish
}

case_clean_other_home() {  # a different CODEX_TASK_HOME cannot remove the worktree: no false success
  begin clean_other_home; fresh_repo
  STUB_SLEEP=600 start_build "echo n > new.txt; $(UP_HOOK)"
  want_true "up" wait_up
  local wt; wt=$(cat "$RUN/worktree")
  run_ct cancel "$RUN"; wait_rc
  CODEX_TASK_HOME=$T/other run_ct clean "$RUN"
  want "clean from another home fails" "$RC" 1; want_has "text" "$OUT" "could not remove"
  want_true "run dir kept" test -d "$RUN"; want_true "worktree kept" test -d "$wt"
  run_ct clean "$RUN"; want "clean from the right home" "$RC" 0
  want_false "worktree gone" test -e "$wt"
  finish
}

case_guard_saved() {  # once the guard is saved it wins: a half-removed worktree must not flip it
  begin guard_saved; fresh_repo
  do_build
  local wt; wt=$(cat "$RUN/worktree")
  want "status" "$ST" "done exit=0 | guard ok"
  mkdir -p "$wt/.claude"
  want "the saved guard wins over a live look" "$(bash "$CT" status "$RUN")" "done exit=0 | guard ok"
  rm -rf "$wt"
  finish
}

case_cancel_after_done() {  # no cancel once done exists (the wrapper only retires); clean waits for it
  begin cancel_after_done; fresh_repo
  do_build
  sleep 600 & local sp=$! st
  st=$(sed 's/.*) //' "/proc/$sp/stat" | cut -d' ' -f20)
  printf '%s %s\n' "$sp" "$st" > "$RUN/wrapper.pid"
  run_ct cancel "$RUN"
  want "rc" "$RC" 0; want_has "text" "$OUT" "nothing to cancel"
  want_false "no cancel marker" test -e "$RUN/cancelled"
  want_true "the wrapper-side process is untouched" pid_up "$sp"
  ( sleep 2; kill -KILL "$sp" ) &
  local t0=$SECONDS
  run_ct clean "$RUN"
  want "clean waits for the wrapper, then works" "$RC" 0
  ((SECONDS - t0 >= 1)) || CASE_ERR+=" [clean did not wait]"
  wait 2>/dev/null
  finish
}

# -- guard and clean
case_guard() {
  begin guard; fresh_repo
  STUB_HOOK='mkdir -p .claude; echo x > .claude/x' launch review --base main; waitrun
  want "guard changed" "$ST" "done exit=0 | guard changed"
  run_ct result "$RUN"; want_fail "result refuses a changed guard" "$RC"
  mkdir -p "$R/.claude/workflow/reviews"
  STUB_HOOK="echo v >> '$R/.claude/workflow/reviews/latest-code.md'" launch review --base main; waitrun
  want "guard ok while the main tree's reviews/ changes" "$ST" "done exit=0 | guard ok"
  finish
}

case_clean() {
  begin clean; fresh_repo
  STUB_SLEEP=600 start_build "echo n > new.txt; $(UP_HOOK)"
  want_true "up" wait_up
  run_ct clean "$RUN"; want_fail "clean refuses a running run" "$RC"
  local wt; wt=$(cat "$RUN/worktree"); local id=${RUN##*/}
  want_true "untracked files left by the build" test -f "$wt/new.txt"
  run_ct cancel "$RUN"; wait_rc
  run_ct clean "$RUN"
  want "force removal" "$RC" 0
  want_false "worktree dir" test -e "$wt"
  want_false "run dir" test -e "$RUN"
  want_false "worktree listing" bash -c "git worktree list | grep -q '$id'"
  want_false "registry entry" test -e "$CODEX_TASK_HOME/registry/$id"
  finish
}

# -- the worktree is Codex-controlled: no git call there may run its config or hooks
FSM_HOOK() {  # the stub's own control call proves the planted fsmonitor runs for an unhardened git call
  cat > "$T/fsm.sh" <<EOF
#!/bin/sh
echo ran >> "$T/fsm.mark"
EOF
  chmod +x "$T/fsm.sh"
  cat > "$T/hook$NCASE.sh" <<EOF
$1
git status > /dev/null 2>&1
[ -e "$T/fsm.mark" ] && mv "$T/fsm.mark" "$T/fsm.control"
echo n > new.txt
EOF
  echo "bash '$T/hook$NCASE.sh'"
}

check_planted_not_run() {  # $1 = hook body that plants a fsmonitor
  rm -f "$T/fsm.mark" "$T/fsm.control"
  do_build "$(FSM_HOOK "$1")" new.txt
  want_true "control: the planted fsmonitor runs for an unhardened git call" test -e "$T/fsm.control"
  want_false "the wrapper never ran the planted fsmonitor" test -e "$T/fsm.mark"
  want "run is done" "$ST" "done exit=0 | guard ok"
  run_ct apply "$RUN"; want "the patch is right" "$RC" 0
  want "new.txt" "$(cat new.txt)" n
}

case_fsmonitor() {  # a core.fsmonitor in the worktree's own config
  begin fsmonitor; fresh_repo
  check_planted_not_run "git config extensions.worktreeConfig true; git config --worktree core.fsmonitor '$T/fsm.sh'"
  finish
}

case_git_pin() {  # Codex replaces the .git pointer with its own repository
  begin git_pin; fresh_repo
  check_planted_not_run "rm -f .git; git init -q .; git config core.fsmonitor '$T/fsm.sh'"
  finish
}

case_post_checkout() {  # a failing post-checkout hook must not run or break the worktree add
  begin post_checkout; fresh_repo
  printf '#!/bin/sh\ntouch "%s/hook.mark"\nexit 1\n' "$T" > .git/hooks/post-checkout
  chmod +x .git/hooks/post-checkout
  rm -f "$T/hook.mark"
  launch review --base main; waitrun
  want "status" "$ST" "done exit=0 | guard ok"
  want_false "the hook did not run" test -e "$T/hook.mark"
  finish
}

# -- outside a git repository
case_not_a_repo() {  # only review and build need a repository
  begin not_a_repo; fresh_repo
  do_build
  local id=${RUN##*/} run=$RUN
  mkdir -p "$T/plain"; cd "$T/plain" || return
  : > "$T/calls"
  local c
  for c in "review --base main" "review --plan $T/plan.md" "build $P $A"; do
    run_ct $c
    want_fail "$c" "$RC"; want_has "$c: text" "$OUT" "not inside a git repository"
  done
  want "codex never started" "$(exec_calls)" 0
  run_ct check review; want "check works outside a repo" "$RC" 0
  run_ct list; want "list works outside a repo" "$RC" 0; want_has "list text" "$OUT" "$id"
  run_ct status "$run"; want "status works outside a repo" "$RC" 0; want_has "status text" "$OUT" "done exit=0"
  run_ct apply "$run"; want "apply works outside a repo" "$RC" 0
  want "applied in the recorded repo" "$(cat "$R/new.txt")" new
  for c in "status $T/x" "result $T/x" "cancel $T/x" "clean $T/x" "apply $T/x"; do
    run_ct $c
    want_fail "$c" "$RC"
  done
  cd "$R" || return
  finish
}

case_straggler() {  # a group member whose cwd is outside the worktree must not outlive the run
  begin straggler; fresh_repo
  STUB_HOOK="(cd / && exec sleep 600) < /dev/null > /dev/null 2>&1 & echo \$! > '$T/sleeper.pid'" launch review --base main; waitrun
  want "status" "$ST" "done exit=0 | guard ok"
  want_true "no member of the Codex group is left" pid_gone "$(cat "$T/sleeper.pid")"
  run_ct clean "$RUN"; want "clean works" "$RC" 0
  finish
}

case_cancel_leftover() {  # a finished run whose wrapper is gone but whose group lives: cancel and clean stop it
  begin cancel_leftover; fresh_repo
  do_build
  setsid sleep 600 < /dev/null > /dev/null 2>&1 &
  local sp=$! st
  echo "$sp" > "$T/sleeper.pid"
  st=$(sed 's/.*) //' "/proc/$sp/stat" | cut -d' ' -f20)
  printf '%s %s\n' "$sp" "$st" > "$RUN/run.pgid"
  run_ct cancel "$RUN"
  want "cancel rc" "$RC" 0; want_has "cancel text" "$OUT" "stopped leftover"
  want_true "the leftover is stopped" pid_gone "$sp"
  want "the state stays done" "$(bash "$CT" status "$RUN")" "done exit=0 | guard ok"
  setsid sleep 600 < /dev/null > /dev/null 2>&1 &
  sp=$!; echo "$sp" > "$T/sleeper.pid"
  st=$(sed 's/.*) //' "/proc/$sp/stat" | cut -d' ' -f20)
  printf '%s %s\n' "$sp" "$st" > "$RUN/run.pgid"
  run_ct clean "$RUN"; want "clean stops a leftover of a finished run" "$RC" 0
  want_true "the second leftover is stopped" pid_gone "$sp"
  finish
}

case_remove_dotdot() {  # recorded worktree and admin paths with .. are never removed
  begin remove_dotdot
  local ct=$T/ct$NCASE victim=$T/victim$NCASE keep=$T/keepc$NCASE
  mkdir -p "$ct" "$victim" "$keep/c/keep" "$keep/c/worktrees" "$ct/wt"; echo v > "$victim/f"
  bash -c "source '$HERE/lib/procs.sh'; CT_HOME='$ct'; remove_worktree '$ct/../victim$NCASE' '' '' ''" > /dev/null 2>&1
  want_true "a .. worktree path is refused and left alone" test -f "$victim/f"
  bash -c "source '$HERE/lib/procs.sh'; CT_HOME='$ct'; remove_worktree '$ct/wt' '' '$keep/c' '$keep/c/worktrees/../keep'" > /dev/null 2>&1
  want_true "a .. admin path is not removed" test -d "$keep/c/keep"
  want_false "the plain worktree is removed" test -e "$ct/wt"
  finish
}

# -- pid and pgid records
case_pgid_record() {  # a pgid is ours only when the leader pid has the recorded start time
  begin pgid_record; fresh_repo
  launch review --base main; waitrun
  rm -f "$RUN/done"
  setsid sleep 600 & local sp=$! st
  st=$(sed 's/.*) //' "/proc/$sp/stat" | cut -d' ' -f20)
  printf '%s %s\n' "$sp" "$st" > "$RUN/run.pgid"
  want "right start: the group is ours" "$(bash "$CT" status "$RUN" | cut -d' ' -f1)" orphan
  printf '%s %s\n' "$sp" "$((st + 1))" > "$RUN/run.pgid"
  want "other start: a reused number" "$(bash "$CT" status "$RUN" | cut -d' ' -f1)" died
  kill -KILL "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  finish
}

case_pid_validate() {  # pids and pgids are integers above 1: never signal -1, 0 or 1
  begin pid_validate
  local v out
  for v in 0 1 -1 abc ""; do
    want_false "valid_pid '$v'" bash -c "source '$HERE/lib/procs.sh'; valid_pid '$v'"
  done
  want_true "valid_pid 2" bash -c "source '$HERE/lib/procs.sh'; valid_pid 2"
  out=$(bash -c "source '$HERE/lib/procs.sh'; kill() { echo \"kill \$*\"; }
    stop_group '1 5'; stop_group 0; stop_group -1; stop_group abc; stop_group '1'; term_wrapper '1 5'; term_wrapper '0 5'" 2>&1)
  want "no signal is sent for a bad record" "$out" ""
  finish
}

case_run_path_dotdot() {  # a run path with .. is refused
  begin run_path_dotdot; fresh_repo
  launch review --base main; waitrun
  run_ct status "$RUN/../${RUN##*/}"
  want_fail "dotdot path" "$RC"; want_has "text" "$OUT" "not a run"
  run_ct status "$RUN"; want "the plain path works" "$RC" 0
  finish
}
