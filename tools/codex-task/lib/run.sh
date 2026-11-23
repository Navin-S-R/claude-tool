# Run lifecycle: claim a slot, run Codex, write the result, clean up. Sourced by codex-task.sh.

begin_run() {  # claims a run slot; the run dir is printed later, by announce_run
  local rc
  umask 077
  validate_timeout
  load_role "$1"
  require_available
  refuse_if_untracked_too_big
  RUN_ID=$(new_run_id "$ROLE")
  WT=$CT_HOME/${REPO_ROOT##*/}-$RUN_ID
  RUN=$(claim_slot "$ROLE"); rc=$?
  if ((rc != 0)); then
    [[ -n $RUN ]] && echo "$RUN"  # holds the "refused: ..." text
    RUN=""
    exit "$rc"
  fi
  trap on_exit EXIT
  trap on_signal TERM INT HUP
}

announce_run() { echo "$RUN"; ANNOUNCED=1; }

checkpoint() { if [[ -e $RUN/cancelled ]]; then exit 0; fi; }  # a cancel that arrived during setup

# Runs in a subshell under the registry lock; prints the run dir, or "refused: ..." (exit 4).
claim_slot() {
  local dir=$REPO_ROOT/.claude/workflow/codex/$RUN_ID rec
  mkdir -p "$REG_DIR" || die "cannot create $REG_DIR"
  exec 9> "$LOCK_FILE"
  flock 9 || die "cannot lock the registry"
  check_limits "$1"
  mkdir -p "$dir" || die "cannot create $dir"
  rec="$$ $(proc_start "$$")"
  printf '*\n' > "$dir/.gitignore"
  printf '%s\n' "$rec" > "$dir/wrapper.pid"
  printf '%s\n' "$REPO_ROOT" > "$dir/repo"
  printf '%s\n' "$1" > "$dir/role"
  printf '%s\n' "$WT" > "$dir/worktree"
  printf 'repo=%s\nrun=%s\nworktree=%s\nrole=%s\nwrapper=%s\n' "$REPO_ROOT" "$dir" "$WT" "$1" "$rec" > "$REG_DIR/$RUN_ID"
  echo "$dir"
}

check_limits() {  # limits count across all repos: 1 build, 2 runs of any role
  local reg live=0
  for reg in "$REG_DIR"/*; do
    [[ -f $reg ]] || continue
    run_live "$(reg_get "$reg" run)" "$reg" || continue
    live=$((live + 1))
    if [[ $1 == build && $(reg_get "$reg" role) == build ]]; then
      refuse "a Codex build is already live ($(reg_get "$reg" run)); the limit is 1 build"
    fi
  done
  ((live < 2)) || refuse "$live Codex runs are already live; the limit is 2"
}

run_codex() {  # $1 = sandbox mode
  local -a argv=(codex exec --ignore-user-config --ignore-rules --ephemeral -s "$1")
  if [[ $1 == workspace-write ]]; then
    argv+=(-c sandbox_workspace_write.network_access=false
           -c sandbox_workspace_write.exclude_slash_tmp=true
           -c sandbox_workspace_write.exclude_tmpdir_env_var=true -C "$WT")
  fi
  argv+=(-m "$MODEL" -c "model_reasoning_effort=$EFFORT" --json -o "$RUN/final.txt")
  [[ $1 == read-only ]] && argv+=(--output-schema "$TOOL_DIR/schema/findings.json")
  argv+=(-)
  [[ -e $RUN/cancelled ]] && return 0
  start_group "${argv[@]}"
  wait "$CHILD"
  CODEX_RC=$?
  stop_group "$CHILD"  # members that outlive Codex (cwd anywhere) die with the run
  CHILD=""
}

start_group() {  # own process group (job control), so cancel can signal the whole tree
  set -m
  (cd "$WT" && exec timeout -k 30 "$CODEX_TIMEOUT" "$@") \
    < "$RUN/prompt.txt" > "$RUN/events.jsonl" 2> "$RUN/stderr.txt" &
  CHILD=$!
  set +m
  put run.pgid "$CHILD $(proc_start "$CHILD")"  # the leader start time tells a reused number from our group
  printf 'pgid=%s\n' "$(cat "$RUN/run.pgid")" >> "$REG_DIR/$RUN_ID"
}

finish_run() {
  put exit "$CODEX_RC"
  [[ -e $RUN/cancelled ]] && return 0
  if [[ $ROLE == build ]]; then write_build_artefacts || return 1; fi
  put guard "$(guard_now "$RUN")"
  if ((CODEX_RC == 0)); then result_ok || return 1; fi
  write_done
  remember_limit
}

result_ok() {  # an exit-0 run with an empty or invalid result file is never a success
  [[ -s $RUN/final.txt ]] || { put failed "empty result file"; return 1; }
  [[ $ROLE == build ]] && return 0
  valid_findings "$RUN/final.txt" || { put failed "invalid review result (not the findings schema)"; return 1; }
}

write_done() {  # last file written, by rename, so a reader never sees a partial one
  local sha=-
  [[ $ROLE == build ]] && sha=$(sha_of_file "$RUN/patch.diff")
  printf '%s %s\n' "$CODEX_RC" "$sha" > "$RUN/done.tmp" && mv "$RUN/done.tmp" "$RUN/done"
}

remember_limit() {  # a usage limit refuses the next starts until it ends; an unparsable end is not kept
  local p kind text end now
  usage_limit "$RUN" > /dev/null || return 0
  p=$(limit_phrase "$(limit_message "$RUN")")
  kind=${p%% *}
  text=$(sanitize_text "${p#* }" | sed -E 's/([0-9])(st|nd|rd|th)\b/\1/g')  # "Dec 5th" -> "Dec 5"
  [[ -n $text ]] || return 0
  end=$(date -d "$text" +%s 2> /dev/null) || return 0
  now=$(date +%s)
  if [[ $kind == at ]] && ((end <= now)); then end=$((end + 86400)); fi  # a clock time already past: tomorrow
  ((end <= now + 8 * 86400)) || end=$((now + 8 * 86400))
  ((end > now)) || return 0
  printf '%s %s\n' "$end" "$(date -d "@$end" '+%F %H:%M %Z')" > "$LIMIT_FILE"  # the absolute time is what is shown
}

# The wrapper's last steps, on every exit path: stop what is left, free the worktree.
on_exit() {
  [[ -n $CHILD ]] && stop_group "$CHILD"
  [[ -n $WT ]] && kill_by_cwd "$WT"
  retire_worktree
  return 0
}
on_signal() {  # TERM / INT / HUP: record failed (not died) so the worktree is freed; a cancel keeps its own state
  [[ -n $CHILD ]] && stop_group "$CHILD"
  if [[ -n $RUN && -d $RUN && ! -e $RUN/cancelled && ! -e $RUN/done && ! -e $RUN/failed ]]; then
    if ((ANNOUNCED)); then put failed "terminated by signal"; else drop_claim; fi
  fi
  exit 143
}

retire_worktree() {  # after done or failed: keep the worktree only when the guard changed (for the owner)
  [[ -n $RUN && -d $RUN ]] || return 0
  [[ -e $RUN/done || -e $RUN/failed ]] || return 0
  [[ -e $RUN/guard ]] || put guard "$(guard_now "$RUN")"
  [[ $(cat "$RUN/guard") == changed ]] && return 0
  if remove_worktree "$WT" "$REPO_ROOT" "$(cat "$RUN/common" 2> /dev/null)" "$(cat "$RUN/gitdir" 2> /dev/null)"; then
    rm -f -- "$RUN/retire-failed"
  else
    put retire-failed "could not remove $WT"
  fi
}
