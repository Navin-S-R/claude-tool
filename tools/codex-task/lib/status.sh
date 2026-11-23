# Run state, usage limit, guard and the findings check. Sourced by codex-task.sh.

status_line() {  # "<state> | guard ok|changed[ | retire-failed]"; a lost run has no guard part
  local state extra=""
  state=$(run_state "$RUN_D" "$REG_F")
  [[ -d $RUN_D ]] || { echo "$state"; return; }
  [[ ! -e $RUN_D/retire-failed ]] || extra=" | retire-failed"
  echo "$state | guard $(guard_now "$RUN_D")$extra"
}

run_state() {  # $1 = run dir, $2 = registry file. Precedence: applied > cancelled > limited > done > failed > running > orphan > died
  local d=$1 limit
  [[ -d $d ]] || { lost_state "$d" "$2"; return; }
  if [[ -e $d/applied ]]; then echo applied
  elif [[ -e $d/cancelled ]]; then echo cancelled
  elif limit=$(usage_limit "$d"); then echo "limited until $limit"
  elif [[ -e $d/done ]]; then done_state "$d"
  elif [[ -e $d/failed ]]; then echo "failed $(head -1 "$d/failed")"
  elif wrapper_alive "$(cat "$d/wrapper.pid" 2> /dev/null)"; then echo running
  elif pgid_alive "$(cat "$d/run.pgid" 2> /dev/null)"; then echo orphan
  else echo died; fi
}

lost_state() {  # the run dir was removed (for example with its Claude worktree); the registry still knows the processes
  if run_busy "$1" "$2"; then echo "lost (run directory removed; Codex still running)"
  else echo "lost (run directory removed)"; fi
}

done_state() {
  local d=$1 rc
  read -r rc _ < "$d/done"
  if ((rc == 0)); then echo "done exit=0"; else echo "done exit=$rc$(error_suffix "$d" "$rc")"; fi
}

error_suffix() {  # " error: <text>", or nothing when there is no text
  local msg
  case $2 in
    124) msg="timed out" ;;
    137) msg="killed" ;;
    *) msg=$(first_error "$1") ;;
  esac
  [[ -z $msg ]] || printf ' error: %s' "$msg"
}

first_error() {  # the first error / turn.failed event wins over the first stderr line
  { event_errors "$1"; cat "$1/stderr.txt" 2> /dev/null; } | grep -m1 .
}

event_errors() {
  jq -r 'select(.type == "error" or .type == "turn.failed") | (.message // .error.message // empty)' \
    "$1/events.jsonl" 2> /dev/null
}

# Usage limit = exit != 0 AND (stderr or an error / turn.failed event) says "usage limit".
usage_limit() {
  local d=$1 rc msg t
  [[ -s $d/done ]] || return 1
  read -r rc _ < "$d/done"
  [[ $rc != 0 ]] || return 1
  msg=$(limit_message "$d") || return 1
  t=$(limit_phrase "$msg")
  t=$(sanitize_text "${t#* }")
  echo "${t:-unknown}"
}

limit_message() { limit_messages "$1" | grep -i -m1 'usage limit'; }

limit_phrase() {  # "at 3:04 PM" or "in 2 hours": the words after "try again" (empty when there are none)
  sed -nE 's/.*[Tt]ry again ((at|in) .*)/\1/p' <<< "$1" | head -1
}

sanitize_text() {  # text from Codex is data: no control characters, no trailing dot, at most 80 characters
  printf '%s' "$1" | tr -d '[:cntrl:]' | cut -c1-80 | sed -E 's/[.[:space:]]+$//'
}

limit_messages() {
  cat "$1/stderr.txt" 2> /dev/null
  event_errors "$1"
}

guard_now() {  # the saved value wins once it exists (a worktree being removed must not flip it); else a live look
  local d=$1 wt snap
  if [[ -e $d/guard ]]; then cat "$d/guard"; return; fi
  wt=$(cat "$d/worktree" 2> /dev/null); snap=$(cat "$d/snapshot" 2> /dev/null)
  if [[ -d $wt && -n $snap && -s $d/gitdir ]] && guard_changed "$d" "$wt" "$snap"; then echo changed; else echo ok; fi
}

guard_changed() {  # Codex wrote under .claude/ in its worktree, or the patch touches .claude/
  local d=$1 wt=$2 snap=$3 gd
  gd=$(cat "$d/gitdir")
  [[ -n $(wt_git "$gd" "$wt" "$snap" status --porcelain --untracked-files=all -- .claude 2> /dev/null) ]] && return 0
  if [[ -e $wt/.claude || -L $wt/.claude ]] \
     && [[ -z $(wt_git "$gd" "$wt" "$snap" ls-tree --name-only "$snap" -- .claude 2> /dev/null) ]]; then return 0; fi
  [[ -s $d/files.z ]] && tr '\0' '\n' < "$d/files.z" | grep -qE '^\.claude(/|$)' && return 0
  return 1
}

valid_findings() {  # the full schema/findings.json: no extra keys, severity enum, integer line, strings
  jq -e '
    def keys7: ["dimension","file","fix","line","scenario","severity","summary"];
    type == "object" and keys == ["findings"] and (.findings | type == "array")
    and (.findings | all(.[];
      type == "object" and (keys == keys7)
      and (.severity | IN("BLOCKER","MAJOR","MINOR","NIT"))
      and (.line | type == "number" and . == floor)
      and ([.dimension,.file,.summary,.scenario,.fix,.severity] | all(type == "string"))))' \
    "$1" > /dev/null 2>&1
}
