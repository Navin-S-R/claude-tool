# Selftest cases: tool files, check, models, argv.
# Sourced by selftest.sh (it holds the framework and the stub).

case_files() {
  begin files
  want_true "codex-task.sh executable" test -x "$CT"
  want_true "selftest executable" test -x "$HERE/selftest.sh"
  local k
  for k in REVIEW_MODEL REVIEW_EFFORT BUILD_MODEL BUILD_EFFORT PLAN_MODEL PLAN_EFFORT; do
    want_true "models.env $k" grep -q "^$k=." "$HERE/models.env"
  done
  want_true "schema findings item has 7 required keys" \
    jq -e '.properties.findings.items.required | length == 7' "$SCHEMA"
  want_true "schema forbids extra keys" jq -e '.additionalProperties == false' "$SCHEMA"
  finish
}

case_usage() {
  begin usage; fresh_repo
  run_ct frobnicate; want rc "$RC" 2
  run_ct; want rc-none "$RC" 2
  finish
}

case_check_ok() {
  begin check_ok; fresh_repo
  local r
  for r in review build plan; do
    run_ct check "$r"
    want "check $r rc" "$RC" 0; want "check $r" "$OUT" available
  done
  run_ct check; want "check default role" "$OUT" available
  want_has "check logs login" "$(calls)" "login status"
  want_has "check logs models" "$(calls)" "debug models"
  want "check sends no prompt" "$(exec_calls)" 0
  finish
}

case_check_no_codex() {
  begin check_no_codex; fresh_repo
  OUT=$(PATH=$T/without-codex "$BASH" "$CT" check review 2>&1); RC=$?
  want_fail "rc" "$RC"; want_has "text" "$OUT" "not available: "
  want_has "reason" "$OUT" "codex"
  OUT=$(PATH=$T/without-codex "$BASH" "$CT" review --base main 2>&1); RC=$?
  want_fail "review rc" "$RC"; want_has "review says not available" "$OUT" "not available"
  finish
}

case_check_tools() {
  begin check_tools; fresh_repo
  local t
  for t in flock timeout ps jq; do
    make_path_without "$t"
    OUT=$(PATH=$T/bin:$T/without-$t "$BASH" "$CT" check review 2>&1); RC=$?
    want_fail "$t missing: rc" "$RC"
    want_has "$t missing: text" "$OUT" "not available: "
    want_has "$t named" "$OUT" "$t"
  done
  OUT=$(PATH=$T/bin:$T/without-flock "$BASH" "$CT" review --base main 2>&1); RC=$?
  want "start without flock is not available (3)" "$RC" 3
  finish
}

case_check_hang() {  # a hung `codex login status` or `codex debug models` must not hang check
  begin check_hang; fresh_repo
  local t0=$SECONDS
  STUB_LOGIN_SLEEP=30 CODEX_TASK_CHECK_TIMEOUT=1 run_ct check review
  want_fail "hung login rc" "$RC"; want_has "hung login text" "$OUT" "login"
  STUB_MODELS_SLEEP=30 CODEX_TASK_CHECK_TIMEOUT=1 run_ct check review
  want_fail "hung models rc" "$RC"; want_has "hung models text" "$OUT" "model"
  ((SECONDS - t0 < 15)) || CASE_ERR+=" [check took $((SECONDS - t0)) s]"
  finish
}

case_check_login() {
  begin check_login; fresh_repo
  STUB_LOGIN_RC=1 run_ct check review
  want_fail rc "$RC"; want_has text "$OUT" "not available: "; want_has reason "$OUT" "login"
  STUB_LOGIN_RC=1 launch review --base main; wait_rc
  want_fail "review rc" "$LRC"; want_has "review text" "$(cat "$LOUT")" "not available"
  STUB_LOGIN_RC=1 launch build "$P" "$A"; wait_rc
  want_fail "build rc" "$LRC"
  want "no exec" "$(exec_calls)" 0
  want_false "no run dir" test -e "$R/.claude/workflow/codex"
  finish
}

case_check_models() {
  begin check_models; fresh_repo
  STUB_MODELS="gpt-6.2-astra" run_ct check review
  want_fail "absent model rc" "$RC"; want_has "absent model" "$OUT" "not available: "
  STUB_MODELS="gpt-6.2-sol-mini" run_ct check review
  want_fail "prefix-only slug is not the model" "$RC"
  REVIEW_MODEL=gpt-6.2-hidden run_ct check review
  want_fail "model named only in a description" "$RC"
  STUB_MODELS_RAW='this is not json' run_ct check review
  want_fail "unparsable models output" "$RC"; want_has "unparsable text" "$OUT" "not available: "
  STUB_MODELS="gpt-6.2-sol" run_ct check plan
  want_fail "plan model absent (check plan reads PLAN_MODEL)" "$RC"
  STUB_MODELS="gpt-6.2-sol" run_ct check review
  want "review model present" "$RC" 0
  STUB_MODELS="gpt-6.2-astra" run_ct check plan
  want "plan model present" "$RC" 0
  finish
}

case_effort_refused() {
  begin effort_refused; fresh_repo
  local e
  for e in ultra turbo; do
    REVIEW_EFFORT=$e launch review --base main; wait_rc
    want_fail "review $e" "$LRC"
    BUILD_EFFORT=$e launch build "$P" "$A"; wait_rc
    want_fail "build $e" "$LRC"
    REVIEW_EFFORT=$e run_ct check review
    want_fail "check $e" "$RC"
  done
  want_has "ultra named" "$(REVIEW_EFFORT=ultra bash "$CT" review --base main 2>&1)" ultra
  want "codex never started" "$(exec_calls)" 0
  finish
}

case_models_env_keys() {  # models.env may set only the six REVIEW_/BUILD_/PLAN_ keys
  begin models_env_keys; fresh_repo
  local copy=$T/toolcopy$NCASE save=$CT
  cp -r "$HERE" "$copy"
  printf 'STUB_HOOK=touch %s/pwned\nSTUB_EXIT=7\nREVIEW_EXTRA=1\n' "$T" >> "$copy/models.env"
  CT=$copy/codex-task.sh
  launch review --base main; waitrun
  CT=$save
  want_false "STUB_HOOK from models.env is not exported" test -e "$T/pwned"
  want "STUB_EXIT from models.env is not exported" "$ST" "done exit=0 | guard ok"
  finish
}

case_models_env_last_line() {  # a last line without a newline is still read
  begin models_env_last_line; fresh_repo
  local copy=$T/toolcopy$NCASE save=$CT
  cp -r "$HERE" "$copy"
  grep -v '^PLAN_EFFORT=' "$HERE/models.env" > "$copy/models.env"
  printf 'PLAN_EFFORT=low' >> "$copy/models.env"
  CT=$copy/codex-task.sh
  launch review --plan "$T/plan.md"; waitrun
  CT=$save
  want_has "effort from the last line" "$(cat "$RUN/stub.argv" 2>/dev/null)" "model_reasoning_effort=low"
  finish
}

case_check_git_version() {  # every role needs git 2.40: the guard uses --attr-source, the gitdir record needs 2.31
  begin check_git_version; fresh_repo
  local r
  for r in review plan build; do
    PATH=$T/shim:$PATH SHIM_VERSION=2.39.0 run_ct check "$r"
    want_fail "old git: $r" "$RC"; want_has "old git: $r text" "$OUT" "git 2.40"
    PATH=$T/shim:$PATH SHIM_VERSION=2.40.0 run_ct check "$r"
    want "git 2.40: $r" "$OUT" available
  done
  PATH=$T/shim:$PATH SHIM_VERSION=2.34.1 launch review --base main; wait_rc
  want "start on old git is not available (3)" "$LRC" 3
  want_false "no run dir" test -e "$R/.claude/workflow/codex"
  finish
}

case_argv_review() {
  begin argv_review; fresh_repo
  launch review --base main; waitrun
  local want="exec|--ignore-user-config|--ignore-rules|--ephemeral|-s|read-only|-m|$(env_val REVIEW_MODEL)|-c|model_reasoning_effort=$(env_val REVIEW_EFFORT)|--json|-o|$RUN/final.txt|--output-schema|$SCHEMA|-"
  want argv "$(paste -sd'|' "$RUN/stub.argv")" "$want"
  want_true "stdin is the prompt file, then EOF" cmp "$RUN/stub.stdin" "$RUN/prompt.txt"
  want marker "$(head -1 "$RUN/prompt.txt")" CT-DELEGATED-JOB
  want_false "prompt avoids the word git" grep -qi git "$RUN/prompt.txt"
  want_true "guard text" grep -q 'Write nothing under .claude/' "$RUN/prompt.txt"
  want cwd "$(readlink -f "$(cat "$RUN/stub.cwd")")" "$(readlink -f "$(cat "$RUN/worktree")")"
  want status "$ST" "done exit=0 | guard ok"
  finish
}

case_argv_build() {
  begin argv_build; fresh_repo
  do_build
  local wt; wt=$(cat "$RUN/worktree")
  local want="exec|--ignore-user-config|--ignore-rules|--ephemeral|-s|workspace-write|-c|sandbox_workspace_write.network_access=false|-c|sandbox_workspace_write.exclude_slash_tmp=true|-c|sandbox_workspace_write.exclude_tmpdir_env_var=true|-C|$wt|-m|$(env_val BUILD_MODEL)|-c|model_reasoning_effort=$(env_val BUILD_EFFORT)|--json|-o|$RUN/final.txt|-"
  want argv "$(paste -sd'|' "$RUN/stub.argv")" "$want"
  want marker "$(head -1 "$RUN/stub.stdin")" CT-DELEGATED-JOB
  want_true "stdin holds the task text" grep -qx TASK-BODY-LINE "$RUN/stub.stdin"
  want_false "prompt avoids the word git" grep -qi git "$RUN/stub.stdin"
  want_true "stdin is the prompt file" cmp "$RUN/stub.stdin" "$RUN/prompt.txt"
  want cwd "$(readlink -f "$(cat "$RUN/stub.cwd")")" "$(readlink -f "$wt")"
  finish
}

case_argv_plan() {
  begin argv_plan; fresh_repo
  printf 'PLAN TEXT\n' > "$T/plan.md"
  launch review --plan "$T/plan.md"; waitrun
  want_true "run created without --base" test -d "$RUN"
  want "model/effort come from PLAN_*" "$(sed -n '8p;10p' "$RUN/stub.argv" | paste -sd' ')" \
    "$(env_val PLAN_MODEL) model_reasoning_effort=$(env_val PLAN_EFFORT)"
  want_has "run id names the role" "$RUN" "-plan-"
  want_true "plan text in the worktree" cmp "$T/plan.md" "$RUN/stub.ctdiff"
  want "diff-sha is the plan hash" "$(cat "$RUN/diff-sha")" "$(sha_of < "$T/plan.md")"
  want "no stale check without --expect-sha" "$ST" "done exit=0 | guard ok"
  want_true "schema passed" grep -qx -- --output-schema "$RUN/stub.argv"
  finish
}

case_review_prompt() {  # --prompt replaces the default review text
  begin review_prompt; fresh_repo
  printf 'CUSTOM-REVIEW-TEXT\n' > "$T/rp.txt"
  launch review --base main --prompt "$T/rp.txt"; waitrun
  want_true "custom text in the prompt" grep -qx CUSTOM-REVIEW-TEXT "$RUN/stub.stdin"
  want_false "default text replaced" grep -q 'Find real defects only' "$RUN/stub.stdin"
  want marker "$(head -1 "$RUN/stub.stdin")" CT-DELEGATED-JOB
  run_ct review --base main --prompt "$T/missing.txt"
  want_fail "unreadable prompt file" "$RC"; want_has "text" "$OUT" "not readable"
  finish
}

case_env_beats_file() {
  begin env_beats_file; fresh_repo
  STUB_MODELS="zz-model" REVIEW_MODEL=zz-model REVIEW_EFFORT=low launch review --base main; waitrun
  want "model" "$(sed -n '8p' "$RUN/stub.argv")" zz-model
  want_has "effort" "$(cat "$RUN/stub.argv")" "model_reasoning_effort=low"
  STUB_MODELS="zz-b" BUILD_MODEL=zz-b BUILD_EFFORT=max do_build
  want_has "build model" "$(cat "$RUN/stub.argv")" "zz-b"
  want_has "build effort" "$(cat "$RUN/stub.argv")" "model_reasoning_effort=max"
  STUB_MODELS="zz-p" PLAN_MODEL=zz-p PLAN_EFFORT=xhigh launch review --plan "$T/plan.md"; waitrun
  want_has "plan model" "$(cat "$RUN/stub.argv")" "zz-p"
  finish
}
