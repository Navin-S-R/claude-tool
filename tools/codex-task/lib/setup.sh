# Arguments, roles, availability and small helpers. Sourced by codex-task.sh.

parse_review_args() {
  BASE=""; BASE_SHA=""; EXPECT=""; PLAN_FILE=""; TASK_FILE=""
  while (($#)); do
    [[ $# -ge 2 ]] || die "$1 needs a value"
    case $1 in
      --base) BASE=$2 ;;
      --expect-sha) EXPECT=$2 ;;
      --plan) PLAN_FILE=$2 ;;
      --prompt) TASK_FILE=$2 ;;
      *) die "unknown option: $1" ;;
    esac
    shift 2
  done
  check_review_args
}

check_review_args() {
  if [[ -n $PLAN_FILE ]]; then
    [[ -z $BASE ]] || die "--plan and --base cannot be used together"
    [[ -r $PLAN_FILE ]] || die "plan file not readable: $PLAN_FILE"
  else
    [[ -n $BASE ]] || die "review needs --base <ref> (or --plan <file>)"
    [[ $BASE != -* ]] || die "unknown base: $BASE"
    BASE_SHA=$(git rev-parse -q --verify "$BASE^{commit}") || die "unknown base: $BASE"
  fi
  [[ -z $TASK_FILE || -r $TASK_FILE ]] || die "prompt file not readable: $TASK_FILE"
}

validate_timeout() {
  [[ $CODEX_TIMEOUT =~ ^[0-9]+[smhd]?$ ]] \
    || die "CODEX_TASK_TIMEOUT '$CODEX_TIMEOUT' is not a duration (for example 45m)"
}

validate_allowed() {  # one exact repo-relative path or one "dir/" prefix per line; blank lines are skipped
  local line n=0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    allowed_entry_ok "$line" || die "the allowed file has a bad entry: '$line'"
    n=$((n + 1))
  done < "$1"
  ((n > 0)) || die "the allowed file has no entry"
}

allowed_entry_ok() {
  local e=$1 c; local -a parts
  [[ $e != *$'\r'* && $e != [[:blank:]]* && $e != *[[:blank:]] && $e != /* ]] || return 1
  [[ $e != .claude && $e != .claude/* ]] || return 1
  IFS=/ read -ra parts <<< "$e"
  for c in "${parts[@]}"; do [[ $c != .. && $c != . && $c != .git ]] || return 1; done
}

# ============================================================== role setup
load_models_env() {  # environment variables win over models.env; only the six role keys are read
  local k v
  [[ -r $TOOL_DIR/models.env ]] || return 0
  while IFS='=' read -r k v || [[ -n $k ]]; do  # the last line may have no newline
    case $k in
      REVIEW_MODEL|REVIEW_EFFORT|BUILD_MODEL|BUILD_EFFORT|PLAN_MODEL|PLAN_EFFORT) ;;
      *) continue ;;
    esac
    [[ -n ${!k+x} ]] || export "$k=$v"
  done < "$TOOL_DIR/models.env"
}

load_role() {  # sets ROLE MODEL EFFORT
  local p m e
  ROLE=$1
  load_models_env
  case $ROLE in
    review) p=REVIEW ;; build) p=BUILD ;; plan) p=PLAN ;;
    *) die "unknown role '$ROLE' (use review, build or plan)" ;;
  esac
  m=${p}_MODEL; e=${p}_EFFORT
  MODEL=${!m:-}; EFFORT=${!e:-}
  [[ -n $MODEL && -n $EFFORT ]] || die "$m / $e are not set (models.env)"
  case $EFFORT in
    low|medium|high|xhigh|max) ;;
    *) die "effort '$EFFORT' is refused (allowed: low medium high xhigh max)" ;;
  esac
}

why_unavailable() {  # prints the reason and returns 0 when Codex cannot be used; returns 1 when it can
  local t limit
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) \
    || { echo "bash 4.4 or newer is required"; return 0; }
  for t in codex jq flock timeout ps; do
    command -v "$t" > /dev/null 2>&1 || { echo "$t is not on PATH"; return 0; }
  done
  if limit=$(limited_until); then echo "usage limit until $limit"; return 0; fi
  if ! git_at_least 2 40; then echo "git 2.40 or newer is required (--attr-source, --path-format)"; return 0; fi
  timeout -k 5 "$CHECK_TIMEOUT" codex login status > /dev/null 2>&1 || { echo "codex login status failed"; return 0; }
  model_listed "$MODEL" || { echo "model $MODEL is not listed by codex debug models"; return 0; }
  return 1
}

model_listed() {  # exact slug match in the one-line JSON of `codex debug models`
  timeout -k 5 "$CHECK_TIMEOUT" codex debug models 2> /dev/null \
    | jq -e --arg m "$1" '[.models[].slug] | index($m)' > /dev/null 2>&1
}

limited_until() {  # prints the saved limit text while its end is still in the future
  local epoch text
  [[ -r $LIMIT_FILE ]] || return 1
  read -r epoch text < "$LIMIT_FILE"
  [[ $epoch =~ ^[0-9]+$ ]] && ((epoch > $(date +%s))) && echo "${text:-unknown}"
}

git_at_least() {  # git_at_least MAJOR MINOR
  local v maj min
  v=$(git --version 2> /dev/null | sed -nE 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/p')
  [[ -n $v ]] || return 1
  read -r maj min <<< "$v"
  ((maj > $1 || (maj == $1 && min >= $2)))
}

clear_limit() {  # check --clear-limit
  if [[ -e $LIMIT_FILE ]]; then rm -f -- "$LIMIT_FILE"; echo "limit cleared"; else echo "no limit saved"; fi
}

require_available() {
  local why
  if why=$(why_unavailable); then
    echo "not available: $why"
    exit 3
  fi
}

# ================================================================ helpers
require_repo() {
  REPO_ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  git rev-parse -q --verify 'HEAD^{commit}' > /dev/null 2>&1 || die "the repository has no commit"
}

new_run_id() {
  printf '%s-%s-%s' "$(date +%Y%m%d-%H%M%S)" "$1" "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
}

die() {  # a started run records the failure; a run that was never announced is dropped
  echo "codex-task: $*" >&2
  if [[ -n $RUN && -d $RUN ]]; then
    if ((ANNOUNCED)); then printf '%s\n' "$*" > "$RUN/failed"; else drop_claim; fi
  fi
  exit 1
}

refuse() {
  [[ -n $RUN && -d $RUN ]] && drop_claim
  echo "refused: $*"
  exit 4
}

drop_claim() {  # a start that fails before it prints its run dir leaves no run dir and no registry entry
  [[ -n $RUN_ID && ${RUN##*/} == "$RUN_ID" ]] && rm -rf -- "${RUN:?}" "${REG_DIR:?}/${RUN_ID:?}"
  RUN=""
}

put() { printf '%s\n' "$2" > "$RUN/$1"; }
sha_of_file() { sha256sum < "$1" | cut -d' ' -f1; }
