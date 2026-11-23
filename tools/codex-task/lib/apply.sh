# The checks before `apply` writes a build's patch into the working tree. Sourced by codex-task.sh.

apply_check_run() {
  local d=$1 rc sha
  [[ -s $d/done ]] || die "refused: the run is not finished"
  read -r rc sha < "$d/done"
  [[ $rc == 0 ]] || die "refused: the Codex exit code is $rc"
  [[ -f $d/patch.diff && $(sha_of_file "$d/patch.diff") == "$sha" ]] \
    || die "refused: the patch sha does not match the recorded sha"
}

apply_check_paths() {
  local d=$1 p snap; snap=$(cat "$d/snapshot")
  mapfile -d '' -t PATHS < <(patch_paths "$d/patch.diff")
  ((${#PATHS[@]})) || die "refused: the patch is empty"
  for p in "${PATHS[@]}"; do
    path_allowed "$p" "$d/allowed" || die "refused: $p is not in the allowed list"
  done
  for p in "${PATHS[@]}"; do
    [[ $p == .claude || $p == .claude/* ]] && die "refused: $p is under .claude/"
  done
  refuse_special_modes "$d/patch.diff"
  [[ $(guard_now "$d") == ok ]] || die "refused: guard changed"
  for p in "${PATHS[@]}"; do
    base_unchanged "$snap" "$p" || die "refused: base changed ($p differs from the snapshot)"
  done
}

refuse_special_modes() {  # a symlink (120000) or a submodule (160000) entry is never applied
  local hit
  hit=$(grep -aEm1 '^(new file mode|deleted file mode|old mode|new mode|index [0-9a-f]+\.\.[0-9a-f]+) (120000|160000)$' "$1") \
    || return 0
  die "refused: the patch has a symlink or submodule entry (mode ${hit##* })"
}

patch_paths() {  # NUL-separated repo-relative paths; numstat -z fields are added<TAB>deleted<TAB>path
  local e
  git apply --numstat -z "$1" | while IFS= read -r -d '' e; do
    e=${e#*$'\t'}
    printf '%s\0' "${e#*$'\t'}"
  done
}

path_allowed() {  # exact path, or a directory prefix that ends in "/"
  local a
  while IFS= read -r a || [[ -n $a ]]; do
    [[ -n $a ]] || continue
    [[ $1 == "$a" ]] && return 0
    [[ $a == */ && $1 == "$a"* ]] && return 0
  done < "$2"
  return 1
}

base_unchanged() {  # the working tree file still equals its snapshot blob (absent for a new file)
  local want have
  if want=$(git rev-parse -q --verify "$1:$2" 2> /dev/null); then
    if [[ -L $2 ]]; then have=$(readlink -- "$2" | tr -d '\n' | git hash-object --stdin)
    elif [[ -f $2 ]]; then have=$(git hash-object -- "$2")
    else return 1; fi
    [[ $have == "$want" ]]
  else
    [[ ! -e $2 && ! -L $2 ]]
  fi
}
