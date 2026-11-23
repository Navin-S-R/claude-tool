# Registry, processes and worktree removal. Sourced by codex-task.sh.

resolve_run() {  # a run dir or a run id -> RUN_D RUN_ID REG_F WT_D
  local arg=${1:-} reg_run
  [[ -n $arg ]] || die "missing run argument"
  [[ /$arg/ != */../* ]] || die "not a run: $arg"
  RUN_D=""
  if [[ -d $arg ]]; then RUN_D=$(cd "$arg" && pwd -P); RUN_ID=${RUN_D##*/}; else RUN_ID=$arg; fi
  [[ $RUN_ID =~ $RUN_ID_RE ]] || die "not a run: $arg"
  REG_F=$REG_DIR/$RUN_ID
  reg_run=$(reg_get "$REG_F" run)
  if [[ -n $reg_run ]]; then RUN_D=$reg_run; fi  # the registry entry wins over a path from the caller
  [[ -n $RUN_D ]] || die "unknown run: $arg"
  if [[ -d $RUN_D && ! -f $RUN_D/repo ]]; then die "not a run directory: $arg"; fi
  WT_D=$(reg_get "$REG_F" worktree)
  [[ -n $WT_D ]] || WT_D=$(cat "$RUN_D/worktree" 2> /dev/null)
}

reg_get() { sed -n "s/^$2=//p" "$1" 2> /dev/null | tail -1; }

# Records come from the run dir; when it is gone, from the registry file.
# A wrapper record is "PID STARTTIME"; a group record is "PGID LEADER-STARTTIME".
run_wrapper() { local v; v=$(cat "$1/wrapper.pid" 2> /dev/null) || true; echo "${v:-$(reg_get "$2" wrapper)}"; }
run_pgid() { local v; v=$(cat "$1/run.pgid" 2> /dev/null) || true; echo "${v:-$(reg_get "$2" pgid)}"; }
wt_common() { local v; v=$(cat "$1/common" 2> /dev/null) || true; echo "${v:-$(reg_get "$2" common)}"; }
wt_gitdir() { local v; v=$(cat "$1/gitdir" 2> /dev/null) || true; echo "${v:-$(reg_get "$2" gitdir)}"; }

run_busy() {  # the wrapper or the Codex process group still exists
  wrapper_alive "$(run_wrapper "$1" "$2")" || pgid_alive "$(run_pgid "$1" "$2")"
}

run_live() {  # counts toward the limits: busy and not yet finished
  local d=$1
  [[ -e $d/done || -e $d/failed || -e $d/cancelled || -e $d/applied ]] && return 1
  run_busy "$d" "$2"
}

# Returns 0 when the worktree is gone, 1 when it is not (the caller keeps the run and says so).
remove_worktree() {  # $1 = external worktree, $2 = repo (may be gone), $3 = common git dir, $4 = its admin dir
  local wt=$1 repo=$2 common=${3:-} gd=${4:-}
  [[ -e $wt ]] || return 0
  [[ -n $wt && $wt == "$CT_HOME"/* && /$wt/ != */../* ]] || return 1
  kill_by_cwd "$wt"
  if [[ -d $repo ]]; then git -C "$repo" worktree remove --force "$wt" 2> /dev/null; fi
  if [[ -e $wt && -d $common ]]; then git --git-dir="$common" worktree remove --force "$wt" 2> /dev/null; fi
  if [[ -e $wt ]]; then force_remove "$wt" "$repo" "$common" "$gd"; fi
  [[ ! -e $wt && ! -L $wt ]]
}

force_remove() {  # read-only dirs block rm; only this run's registration is dropped (no global prune)
  chmod -R u+rwX -- "$1" 2> /dev/null
  rm -rf -- "${1:?}"
  [[ ! -e $1 ]] || return 0
  if [[ -n $4 && -n $3 && $4 == "$3"/worktrees/* && /$4/ != */../* ]]; then rm -rf -- "${4:?}"
  elif [[ -d $2 ]]; then git -C "$2" worktree prune
  elif [[ -d $3 ]]; then git --git-dir="$3" worktree prune 2> /dev/null; fi
}

# ============================================================ processes
valid_pid() { [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#${1} > 1)); }  # never 0, 1 or a negative: kill -1 hits everything

proc_start() {  # start time (clock ticks since boot) of a pid: field 22 of /proc/PID/stat
  local s; local -a f
  read -r s 2> /dev/null < "/proc/$1/stat" || return 1
  read -ra f <<< "${s##*) }"
  echo "${f[19]}"
}

wrapper_alive() {  # "PID STARTTIME": alive, not a zombie, and the same process (not a reused pid)
  local pid st
  read -r pid st <<< "${1:-}"
  valid_pid "$pid" && kill -0 "$pid" 2> /dev/null || return 1
  [[ $(ps -o stat= -p "$pid" 2> /dev/null) != Z* ]] || return 1
  [[ -z $st || $(proc_start "$pid") == "$st" ]]
}

term_wrapper() { wrapper_alive "${1:-}" && kill -TERM "${1%% *}" 2> /dev/null; return 0; }

pgid_alive() {  # "PGID [LEADER-STARTTIME]": any non-zombie member; a live pid = pgid with another start is not ours
  local g st
  read -r g st <<< "${1:-}"
  valid_pid "$g" || return 1
  if [[ -n $st ]] && kill -0 "$g" 2> /dev/null && [[ $(proc_start "$g") != "$st" ]]; then return 1; fi
  ps -eo pgid=,stat= | awk -v g="$g" '$1 == g && $2 !~ /^Z/ {f = 1} END {exit !f}'
}

stop_group() {  # "PGID [START]": TERM the group, KILL after 10 s
  local g i
  read -r g _ <<< "${1:-}"
  valid_pid "$g" || return 0
  pgid_alive "$1" || return 0  # also checks the leader start time: a reused number is not our group
  kill -TERM -- "-$g" 2> /dev/null
  for ((i = 0; i < 100; i++)); do
    pgid_alive "$1" || return 0
    sleep 0.1
  done
  kill -KILL -- "-$g" 2> /dev/null
}

kill_by_cwd() {  # sandboxed commands may sit in other process groups; their cwd is the worktree
  local dir=${1:-} p c
  [[ -n $dir ]] || return 0
  for p in /proc/[0-9]*; do
    [[ ${p#/proc/} == "$$" ]] && continue
    c=$(readlink "$p/cwd" 2> /dev/null) || continue
    c=${c% (deleted)}
    if [[ $c == "$dir" || $c == "$dir"/* ]]; then kill -KILL "${p#/proc/}" 2> /dev/null; fi
  done
  return 0
}

wait_gone() {  # $1 = wrapper record; up to 15 s
  local i
  for ((i = 0; i < 150; i++)); do
    wrapper_alive "${1:-}" || return 0
    sleep 0.1
  done
}
