#!/usr/bin/env bash
# codex-task: run Codex as an optional, bounded second model (reviewer or builder).
# Usage: codex-task.sh check [role] | review ... | build <prompt> <allowed> | apply|status|result|cancel|clean <run> | list
# Details: README.md next to this file. Selftest: selftest.sh. The functions live in lib/.
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
TOOL_DIR=${SELF%/*}
CT_HOME=${CODEX_TASK_HOME:-$HOME/.cache/codex-task}
REG_DIR=$CT_HOME/registry
LOCK_FILE=$CT_HOME/lock
LIMIT_FILE=$CT_HOME/limited-until
MAX_UNTRACKED_MB=50
MAX_DIFF_BYTES=${CODEX_TASK_MAX_DIFF_BYTES:-5242880}
MAX_BUILD_BYTES=${CODEX_TASK_MAX_BUILD_BYTES:-$((MAX_UNTRACKED_MB * 1048576))}
USER_UMASK=$(umask)  # git writes into the user's repo under this umask; only the tool's own files are private
CODEX_TIMEOUT=${CODEX_TASK_TIMEOUT:-45m}
CHECK_TIMEOUT=${CODEX_TASK_CHECK_TIMEOUT:-20}
RUN_ID_RE='^[0-9]{8}-[0-9]{6}-(review|build|plan)-[0-9a-f]+$'
# Diff flags that user config cannot change: the hash must equal the /review-loop hash.
DIFF_CFG=(-c diff.noprefix=false -c diff.mnemonicPrefix=false -c color.ui=never)
DIFF_OPT=(--no-ext-diff --src-prefix=a/ --dst-prefix=b/)
CHILD=""; CODEX_RC=143; RUN=""; RUN_ID=""; WT=""; WT_GITDIR=""; ANNOUNCED=0
GUARD_TEXT='CT-DELEGATED-JOB
This is a bounded sub-task from Claude. Do only this task.
Do not run the ct-* workflow and do not use ct-* skills.
Write nothing under .claude/. Do not commit. Do not push.'

for lib in setup snapshot run status apply procs; do
  # shellcheck source=/dev/null
  source "$TOOL_DIR/lib/$lib.sh"
done

# ============================================================== entry point
main() {
  local cmd=${1:-}
  case $cmd in
    check|review|build|apply|status|result|cancel|clean|list) shift ;;
    *) usage ;;
  esac
  case $cmd in review|build) require_repo ;; esac  # the other commands find runs by id or path
  "cmd_$cmd" "$@"
}

usage() {
  echo "usage: codex-task.sh check [review|build|plan] | review --base <ref> [--expect-sha <sha>] [--prompt <file>]" >&2
  echo "       | review --plan <file> | build <prompt-file> <allowed-file> | apply|status|result|cancel|clean <run> | list" >&2
  exit 2
}

# ================================================================= commands
cmd_check() {
  local why
  if [[ ${1:-} == --clear-limit ]]; then clear_limit; return 0; fi
  load_role "${1:-review}"
  if why=$(why_unavailable); then
    echo "not available: $why"
    return 1
  fi
  echo available
}

cmd_review() {
  local role=review
  parse_review_args "$@"
  [[ -n $PLAN_FILE ]] && role=plan
  begin_run "$role"
  make_snapshot; checkpoint
  prepare_diff
  announce_run
  add_worktree; checkpoint
  stage_review; checkpoint
  write_review_task
  compose_prompt "$RUN/task.txt"
  run_codex read-only
  finish_run
}

cmd_build() {
  [[ $# -eq 2 ]] || die "usage: build <prompt-file> <allowed-file>"
  [[ -r $1 && -r $2 ]] || die "the prompt file or the allowed file is not readable"
  validate_allowed "$2"
  begin_run build
  cp -- "$2" "$RUN/allowed"
  make_snapshot; checkpoint
  announce_run
  add_worktree; checkpoint
  compose_prompt "$1"
  run_codex workspace-write
  finish_run
}

cmd_status() {
  resolve_run "${1:-}"
  status_line
}

cmd_result() {
  resolve_run "${1:-}"
  if [[ $(run_state "$RUN_D" "$REG_F") == "done exit=0" && $(guard_now "$RUN_D") == ok ]] \
     && [[ $(cat "$RUN_D/role") != build ]] && valid_findings "$RUN_D/final.txt"; then
    cat "$RUN_D/final.txt"
    return 0
  fi
  status_line
  return 1
}

cmd_cancel() {  # repeatable: it works again while anything of the run is still busy
  resolve_run "${1:-}"
  if ! run_busy "$RUN_D" "$REG_F"; then
    echo "nothing to cancel: $(run_state "$RUN_D" "$REG_F")"
    return 0
  fi
  if [[ -e $RUN_D/done || -e $RUN_D/failed ]]; then  # finished: only a leftover group is stopped, never the wrapper
    wrapper_alive "$(run_wrapper "$RUN_D" "$REG_F")" && { echo "nothing to cancel: $(run_state "$RUN_D" "$REG_F")"; return 0; }
    stop_leftovers
    echo "stopped leftover processes"
    return 0
  fi
  [[ -d $RUN_D ]] && : > "$RUN_D/cancelled"
  term_wrapper "$(run_wrapper "$RUN_D" "$REG_F")"
  stop_group "$(run_pgid "$RUN_D" "$REG_F")"
  kill_by_cwd "$WT_D"
  wait_gone "$(run_wrapper "$RUN_D" "$REG_F")"
  echo cancelled
}

stop_leftovers() {  # the wrapper is gone: stop what is left of the Codex group and of the worktree
  stop_group "$(run_pgid "$RUN_D" "$REG_F")"
  kill_by_cwd "$WT_D"
}

cmd_clean() {
  resolve_run "${1:-}"
  if [[ -e $RUN_D/done || -e $RUN_D/failed ]]; then
    wait_gone "$(run_wrapper "$RUN_D" "$REG_F")"
    wrapper_alive "$(run_wrapper "$RUN_D" "$REG_F")" || stop_leftovers
  fi
  run_busy "$RUN_D" "$REG_F" && die "refused: the run is still live; cancel it first"
  remove_worktree "$WT_D" "$(reg_get "$REG_F" repo)" "$(wt_common "$RUN_D" "$REG_F")" "$(wt_gitdir "$RUN_D" "$REG_F")" \
    || die "refused: could not remove $WT_D"
  [[ -d $RUN_D && ${RUN_D##*/} == "$RUN_ID" ]] && rm -rf -- "${RUN_D:?}"
  rm -f -- "$REG_F"
  echo "cleaned $RUN_ID"
}

cmd_list() {
  local reg
  for reg in "$REG_DIR"/*; do
    [[ -f $reg ]] || continue
    echo "${reg##*/} $(reg_get "$reg" role) $(run_state "$(reg_get "$reg" run)" "$reg")" \
      "| repo=$(reg_get "$reg" repo) worktree=$(reg_get "$reg" worktree)"
  done
  return 0
}

cmd_apply() {
  local repo
  resolve_run "${1:-}"
  [[ -e $RUN_D/applied ]] && die "refused: already applied"
  [[ -e $RUN_D/cancelled ]] && die "refused: the run was cancelled"
  [[ $(cat "$RUN_D/role" 2>/dev/null) == build ]] || die "refused: not a build run"
  apply_check_run "$RUN_D"
  repo=$(cat "$RUN_D/repo")
  cd "$repo" 2>/dev/null || die "refused: the repository $repo is gone"
  [[ $(git rev-parse --show-toplevel 2>/dev/null) == "$repo" ]] || die "refused: $repo is not a top level"
  apply_check_paths "$RUN_D"
  git apply --check "$RUN_D/patch.diff" 2>/dev/null || die "refused: the patch does not apply"
  git apply "$RUN_D/patch.diff" || die "the patch failed to apply"
  date -u +%FT%TZ > "$RUN_D/applied"
  echo "applied ${#PATHS[@]} path(s) to the working tree (not staged)"
}

main "$@"
