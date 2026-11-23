#!/usr/bin/env bash
# Selftest for codex-task.sh. A stub `codex` is put first on PATH; the real one is never run.
# The registry and cache live in a temp dir (CODEX_TASK_HOME); nothing under $HOME is touched.
# Usage: bash tools/codex-task/selftest.sh      (SELFTEST_ONLY="case1 case2" runs a subset)
# The cases live in selftest-check.sh, selftest-core.sh, selftest-apply.sh and selftest-run.sh.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CT=$HERE/codex-task.sh
SCHEMA=$HERE/schema/findings.json
T=$(mktemp -d "${TMPDIR:-/tmp}/codex-task-selftest.XXXXXX")
PASS=0; FAILN=0; CASE=""; CASE_ERR=""; NCASE=0; NOUT=0
LPIDS=(); RUN=""; LPID=""; LRC=0; OUT=""; RC=0; ST=""; FIRST=""; LOUT=""

# The tool reads these; a stray value in the caller's shell must not leak into a case.
unset REVIEW_MODEL REVIEW_EFFORT BUILD_MODEL BUILD_EFFORT PLAN_MODEL PLAN_EFFORT
unset CODEX_TASK_TIMEOUT CODEX_TASK_CHECK_TIMEOUT CODEX_TASK_MAX_DIFF_BYTES CODEX_TASK_MAX_BUILD_BYTES CODEX_TASK_HOME

# ---------------------------------------------------------------- stub codex
make_stub() {
  mkdir -p "$T/bin"
  cat > "$T/bin/codex" <<'STUB'
#!/usr/bin/env bash
# Stub codex. Behaviour comes from STUB_* variables. Records each call in $STUB_CALLS.
printf '%s\n' "$*" >> "${STUB_CALLS:?}"
case "${1:-}" in
  login) [[ -n ${STUB_LOGIN_SLEEP:-} ]] && exec sleep "$STUB_LOGIN_SLEEP"; exit "${STUB_LOGIN_RC:-0}" ;;
  debug)
    [[ -n ${STUB_MODELS_SLEEP:-} ]] && exec sleep "$STUB_MODELS_SLEEP"
    if [[ -n ${STUB_MODELS_RAW:-} ]]; then echo "$STUB_MODELS_RAW"; exit 0; fi
    printf '{"models":['; sep=""
    for m in ${STUB_MODELS:-gpt-6.2-sol gpt-6.2-astra}; do
      printf '%s{"slug":"%s","display_name":"%s","description":"decoy gpt-6.2-hidden","supported_reasoning_levels":[{"effort":"low"}]}' "$sep" "$m" "$m"
      sep=,
    done
    printf ']}\n'; exit 0 ;;
  exec) shift ;;
  *) exit 64 ;;
esac
args=("$@"); out=""; schema=0
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ ${args[i]} == -o ]] && out=${args[i + 1]}
  [[ ${args[i]} == --output-schema ]] && schema=1
done
d=$(dirname "$out")
{ echo exec; printf "%s\n" "${args[@]}"; } > "$d/stub.argv"
pwd > "$d/stub.cwd"
cat > "$d/stub.stdin"
[[ -L CT-DIFF.patch ]] && : > "$d/stub.ctlink"
[[ -f CT-DIFF.patch ]] && cp CT-DIFF.patch "$d/stub.ctdiff"
eval "${STUB_HOOK:-:}"
[[ -n ${STUB_SLEEP:-} ]] && sleep "$STUB_SLEEP"
[[ -n ${STUB_STDERR:-} ]] && echo "$STUB_STDERR" >&2
echo '{"type":"thread.started","thread_id":"t"}'
if [[ -n ${STUB_ERROR:-} ]]; then
  jq -nc --arg m "$STUB_ERROR" '{type:"error",message:$m}'
  jq -nc --arg m "$STUB_ERROR" '{type:"turn.failed",error:{message:$m}}'
fi
if [[ -n ${STUB_AGENT_TEXT:-} ]]; then
  jq -nc --arg t "$STUB_AGENT_TEXT" '{type:"item.completed",item:{id:"i",type:"agent_message",text:$t}}'
fi
if [[ ${STUB_EXIT:-0} == 0 ]]; then
  if [[ -n ${STUB_FINAL+x} ]]; then printf '%s' "$STUB_FINAL" > "$out"
  elif ((schema)); then printf '{"findings":[]}' > "$out"
  else printf 'built ok' > "$out"; fi
else
  : > "$out"
fi
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$T/bin/codex"
}

# make_path_without <tool>: a PATH dir with every /usr/bin tool except <tool> (the stub stays reachable).
make_path_without() {
  local f dir=$T/without-$1
  mkdir -p "$dir"
  for f in /usr/bin/*; do
    [[ ${f##*/} == "$1" ]] || ln -sf "$f" "$dir/${f##*/}"
  done
}

# A `git` shim: sleeps $SHIM_SLEEP seconds before a git call whose arguments hold $SHIM_ON.
make_git_shim() {
  mkdir -p "$T/shim"
  cat > "$T/shim/git" <<SHIM
#!/usr/bin/env bash
[[ -n "\${SHIM_VERSION:-}" && "\${1:-}" == --version ]] && { echo "git version \$SHIM_VERSION"; exit 0; }
[[ -n "\${SHIM_ON:-}" && " \$* " == *" \$SHIM_ON "* ]] && sleep "\${SHIM_SLEEP:-2}"
exec $(command -v git) "\$@"
SHIM
  chmod +x "$T/shim/git"
}

# ------------------------------------------------------------ test framework
begin() { CASE=$1; CASE_ERR=""; }
finish() {
  reap
  if [[ -z $CASE_ERR ]]; then echo "PASS $CASE"; PASS=$((PASS + 1))
  else echo "FAIL $CASE:$CASE_ERR"; FAILN=$((FAILN + 1)); fi
}
want()       { [[ $2 == "$3" ]] || CASE_ERR+=" [$1: got '${2:0:160}' want '${3:0:160}']"; }
want_ne()    { [[ $2 != "$3" ]] || CASE_ERR+=" [$1: values equal '${2:0:80}']"; }
want_has()   { [[ $2 == *"$3"* ]] || CASE_ERR+=" [$1: '$3' missing in '${2:0:200}']"; }
want_no()    { [[ $2 != *"$3"* ]] || CASE_ERR+=" [$1: unexpected '$3' in '${2:0:200}']"; }
want_true()  { local d=$1; shift; "$@" >/dev/null 2>&1 || CASE_ERR+=" [$d]"; }
want_false() { local d=$1; shift; "$@" >/dev/null 2>&1 && CASE_ERR+=" [$d]"; }
want_fail()  { [[ $2 != 0 ]] || CASE_ERR+=" [$1: exit code was 0]"; }

run_ct() { OUT=$(bash "$CT" "$@" 2>&1); RC=$?; }
calls()  { cat "$T/calls" 2>/dev/null; }
exec_calls() { grep -c '^exec ' "$T/calls" 2>/dev/null || true; }
env_val() { sed -n "s/^$1=//p" "$HERE/models.env"; }
sha_of() { sha256sum | cut -d' ' -f1; }
mode_of() { stat -c %a "$1"; }

procs_in() {  # processes whose cwd is $1 or below (a deleted cwd still counts)
  local n=0 p c
  for p in /proc/[0-9]*; do
    c=$(readlink "$p/cwd" 2>/dev/null) || continue
    c=${c% (deleted)}
    [[ $c == "$1" || $c == "$1"/* ]] && n=$((n + 1))
  done
  echo "$n"
}
stub_procs() { pgrep -fc "$T/bin/codex" || true; }
pid_up() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null && [[ $(ps -o stat= -p "$1" 2>/dev/null) != Z* ]]; }
pid_gone() { local i; for ((i = 0; i < 50; i++)); do pid_up "$1" || return 0; sleep 0.1; done; return 1; }

reap() {
  local p c
  for p in "${LPIDS[@]:-}"; do [[ -n $p ]] && kill -KILL "$p" 2>/dev/null; done
  pkill -KILL -f "$T/bin/codex" 2>/dev/null
  for p in /proc/[0-9]*; do
    c=$(readlink "$p/cwd" 2>/dev/null) || continue
    [[ $c == "$T"/home* ]] && kill -KILL "${p#/proc/}" 2>/dev/null
  done
  [[ -f $T/sleeper.pid ]] && kill -KILL "$(cat "$T/sleeper.pid")" 2>/dev/null
  rm -f "$T/sleeper.pid"
  LPIDS=()
  return 0
}

# --------------------------------------------------------------- repo helpers
mkrepo() {
  mkdir -p "$1" && cd "$1" || return 1
  git init -q -b main .
  seq -f 'line %g' 1 20 > a.txt
  mkdir dir; echo b > dir/b.txt
  echo spaced > "sp ace.txt"; echo old > old.txt
  printf '\000\001\002BIN' > bin.dat
  echo '*.log' > .gitignore
  git add -A && git commit -q -m init
}
fresh_repo() {
  NCASE=$((NCASE + 1))
  export CODEX_TASK_HOME=$T/home$NCASE
  : > "$T/calls"
  mkrepo "$T/r$NCASE"; R=$(pwd -P)
}
second_repo() { mkrepo "$T/r${NCASE}b"; R2=$(pwd -P); }

# launch <ct args>: start the wrapper in the background; sets RUN (when the first line is a path).
launch() {
  NOUT=$((NOUT + 1)); LOUT=$T/out.$NOUT; RUN=""
  bash "$CT" "$@" > "$LOUT" 2> "$LOUT.err" &
  LPID=$!; LPIDS+=("$LPID")
  local i
  for ((i = 0; i < 150; i++)); do
    [[ -s $LOUT ]] && break
    kill -0 "$LPID" 2>/dev/null || break
    sleep 0.1
  done
  FIRST=$(head -1 "$LOUT")
  [[ $FIRST == /* ]] && RUN=$FIRST
  return 0
}
wait_rc() { wait "$LPID" 2>/dev/null; LRC=$?; }
waitrun() {
  [[ -n $RUN ]] || return 1
  local i
  for ((i = 0; i < 300; i++)); do
    [[ -e $RUN/done || -e $RUN/failed || -e $RUN/cancelled ]] && break
    kill -0 "$LPID" 2>/dev/null || break
    sleep 0.1
  done
  wait_rc
  ST=$(bash "$CT" status "$RUN" 2>&1)
}
wait_state() {  # wait_state <prefix> [tries]
  local i s=""
  for ((i = 0; i < ${2:-100}; i++)); do
    s=$(bash "$CT" status "$RUN" 2>&1)
    [[ $s == "$1"* ]] && { ST=$s; return 0; }
    sleep 0.1
  done
  ST=$s; return 1
}
wait_file() {  # wait_file <path> [tries]: the stub hook writes the file when it is up
  local i
  for ((i = 0; i < ${2:-100}; i++)); do
    [[ -s $1 ]] && return 0
    sleep 0.1
  done
  return 1
}
# The stub is up when its hook wrote the marker and the wrapper recorded the group.
wait_up() { wait_file "$T/up$NCASE" && wait_file "$RUN/run.pgid"; }

P=$T/prompt.txt; A=$T/allowed.txt
HOOK_DEFAULT='echo "line 21" >> a.txt; echo new > new.txt; echo mod >> dir/b.txt'
ALLOW_DEFAULT=$'a.txt\nnew.txt\ndir/'
UP_HOOK() { echo "echo up > '$T/up$NCASE'"; }                  # marker for wait_up
SLEEPER_HOOK() { echo "setsid sleep 600 < /dev/null > /dev/null 2>&1 & echo \$! > '$T/sleeper.pid'"; }
start_build() {  # env STUB_* are passed through; $1 = hook, $2 = allowed text
  printf 'TASK-BODY-LINE\n' > "$P"
  printf '%s\n' "${2:-$ALLOW_DEFAULT}" > "$A"
  STUB_HOOK=${1:-$HOOK_DEFAULT} launch build "$P" "$A"
}
do_build() { start_build "$@"; waitrun; }

# ----------------------------------------------------------------------- main
# shellcheck source=/dev/null
for f in selftest-check.sh selftest-core.sh selftest-apply.sh selftest-run.sh; do source "$HERE/$f"; done

CASES=(files usage check_ok check_no_codex check_tools check_hang check_git_version check_login
  check_models effort_refused models_env_keys models_env_last_line argv_review argv_build argv_plan
  review_prompt env_beats_file
  snapshot snapshot_claude_ignored snapshot_claude_tracked snapshot_too_big no_commits rundir_layout stage_nofollow review_result review_schema
  result_not_review diff_sha diff_flags diff_too_large stale plan_base base_option limit_error
  limit_remember limit_forms limit_clear limit_only_on_error error_text timeout git_umask
  apply_happy apply_exit_nonzero apply_missing_done apply_sha_mismatch apply_allowed
  apply_base_changed apply_deleted_drift apply_check_fails apply_claude_path apply_guard_only
  apply_cancelled apply_modes apply_file_kinds apply_not_build apply_ignored_allowed
  apply_literal allowed_validation build_too_large attr_source
  limits limits_reviews wrapper_cleans retire_readonly retire_failed clean_other_home guard_saved
  cancel_after_done list_lost_run cancel cancel_repeat cancel_in_setup sigkill_orphan term_wrapper
  clean_kills_strays pid_reuse pgid_record pid_validate run_path_dotdot straggler cancel_leftover remove_dotdot guard clean
  git_pin fsmonitor post_checkout not_a_repo)

cleanup() { cd / || true; reap; chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

make_stub
make_path_without codex
make_git_shim
export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --file "$T/gitconfig" user.name selftest
git config --file "$T/gitconfig" user.email selftest@example.invalid
export STUB_CALLS=$T/calls
export PATH=$T/bin:$PATH
if [[ $(command -v codex) != "$T/bin/codex" ]]; then
  echo "refusing to run: codex does not resolve to the stub" >&2; exit 2
fi
: > "$T/calls"
printf 'PLAN TEXT\n' > "$T/plan.md"
printf 'TASK-BODY-LINE\n' > "$P"; printf 'a.txt\n' > "$A"

[[ -n ${SELFTEST_ONLY:-} ]] && read -r -a CASES <<< "$SELFTEST_ONLY"  # dev aid: run a subset
for c in "${CASES[@]}"; do "case_$c"; done
echo "----"
echo "$PASS passed, $FAILN failed"
((FAILN == 0))
