# Snapshot, external worktree, diff and build artefacts. Sourced by codex-task.sh.

make_snapshot() {  # never touches the real index, worktree or HEAD
  local tree
  export GIT_AUTHOR_NAME=codex-task GIT_AUTHOR_EMAIL=codex-task@localhost
  export GIT_COMMITTER_NAME=codex-task GIT_COMMITTER_EMAIL=codex-task@localhost
  snap_git read-tree HEAD || die "the repository has no commit"
  snap_git add -A -- . || die "snapshot: add failed"
  drop_claude_dir || die "snapshot: cannot drop .claude/"
  if [[ $ROLE == build ]]; then
    force_add_allowed "$REPO_ROOT" snap_git || die "snapshot: cannot add the allowed ignored paths"
  fi
  tree=$(snap_git write-tree) || die "snapshot: write-tree failed"
  SNAP=$(ugit -C "$REPO_ROOT" commit-tree "$tree" -p HEAD -m "codex-task snapshot") || die "snapshot: commit-tree failed"
  SNAP_TREE=$tree
  put snapshot "$SNAP"
}

ugit() { ( umask "$USER_UMASK"; exec git "$@" ); }  # git under the caller's umask (objects, worktree admin)

snap_git() { GIT_INDEX_FILE=$RUN/index ugit -C "$REPO_ROOT" "$@"; }

# An exclude pathspec makes add exit 1 ("paths are ignored") when .claude/ is ignored, so add everything,
# then put .claude/ back to HEAD: tracked files keep their HEAD content, nothing else of it is in.
drop_claude_dir() {
  snap_git rm -r --cached -q --ignore-unmatch -- .claude || return 1
  if snap_git rev-parse -q --verify 'HEAD:.claude' > /dev/null 2>&1; then
    snap_git read-tree --prefix=.claude/ 'HEAD:.claude'
  fi
}

# git calls in the Codex-controlled worktree. Codex can rewrite the .git pointer there, so the git
# dir recorded before Codex ran is pinned; config that runs commands (fsmonitor, hooks) is off; and
# attributes come from the snapshot, not from a .gitattributes Codex wrote (filter / textconv drivers).
wt_git() {  # $1 = git dir, $2 = worktree, $3 = snapshot
  local gd=$1 wt=$2 snap=$3
  shift 3
  GIT_DIR=$gd GIT_WORK_TREE=$wt GIT_OPTIONAL_LOCKS=0 GIT_ATTR_NOSYSTEM=1 \
    ugit -C "$wt" --attr-source="$snap" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

art_git() { GIT_INDEX_FILE=$RUN/index2 wt_git "$WT_GITDIR" "$WT" "$SNAP" "$@"; }

force_add_allowed() {  # $1 = tree root, rest = a git function. Ignored allowed paths are dropped by add -A.
  local root=$1 paths=()
  shift
  mapfile -d '' -t paths < <(allowed_exact_existing "$RUN/allowed" "$root")
  ((${#paths[@]} == 0)) || GIT_LITERAL_PATHSPECS=1 "$@" add -f -- "${paths[@]}"
}

allowed_exact_existing() {  # NUL-separated exact allowed entries that exist as files or links under $2
  local a
  while IFS= read -r a || [[ -n $a ]]; do
    [[ -n $a && $a != */ ]] || continue
    if [[ -f $2/$a || -L $2/$a ]]; then printf '%s\0' "$a"; fi
  done < "$1"
}

add_worktree() {
  mkdir -p "$CT_HOME"
  ugit -C "$REPO_ROOT" -c core.hooksPath=/dev/null worktree add --detach -q "$WT" "$SNAP" > /dev/null 2> "$RUN/stderr.setup" \
    || die "worktree add failed: $(head -1 "$RUN/stderr.setup")"
  record_gitdir
}

record_gitdir() {  # before Codex runs: the pointer in the worktree is still ours
  local common
  WT_GITDIR=$(wt_rev_parse --absolute-git-dir) || die "cannot read the worktree git dir"
  common=$(wt_rev_parse --path-format=absolute --git-common-dir) || die "cannot read the common git dir"
  put gitdir "$WT_GITDIR"
  put common "$common"
  printf 'common=%s\ngitdir=%s\n' "$common" "$WT_GITDIR" >> "$REG_DIR/$RUN_ID"
}

wt_rev_parse() { git -C "$WT" -c core.fsmonitor=false -c core.hooksPath=/dev/null rev-parse "$@"; }

# $RUN/diff.txt is the text Codex reads and the text that is hashed (the /review-loop recipe).
prepare_diff() {
  local got
  if [[ -n $PLAN_FILE ]]; then
    cp -- "$PLAN_FILE" "$RUN/diff.txt" || die "cannot copy the plan file"
  else
    repo_diff > "$RUN/diff.txt" || die "cannot write the diff"
  fi
  (($(stat -c %s "$RUN/diff.txt") <= MAX_DIFF_BYTES)) || refuse "diff too large (limit $MAX_DIFF_BYTES bytes)"
  got=$(sha_of_file "$RUN/diff.txt")
  put diff-sha "$got"
  [[ -n $EXPECT ]] || return 0
  [[ $EXPECT == "$got" ]] || refuse "stale (expected $EXPECT, saw $got)"
  put expect-sha "$EXPECT"
}

repo_diff() {
  local -a range
  diff_range
  git -C "$REPO_ROOT" "${DIFF_CFG[@]}" diff "${DIFF_OPT[@]}" "${range[@]}" --
}

# The one rule: if the snapshot tree differs from HEAD's tree, or any untracked file outside .claude/
# exists, two-dot "<base> <snapshot>"; else three-dot. The snapshot holds every untracked file that git
# does not ignore, so an untracked file already makes the trees differ: the two conditions are one.
diff_range() {
  if [[ $(git -C "$REPO_ROOT" rev-parse "HEAD^{tree}") == "$SNAP_TREE" ]]; then
    range=("$BASE_SHA...$SNAP")
  else
    range=("$BASE_SHA" "$SNAP")
  fi
}

stage_review() {  # a tracked symlink or dir named CT-DIFF.patch must not redirect the write out of the worktree
  local f=$WT/CT-DIFF.patch
  rm -f -- "$f" 2> /dev/null
  [[ ! -e $f && ! -L $f ]] || die "cannot stage CT-DIFF.patch: the path is in the way"
  cp --no-dereference -- "$RUN/diff.txt" "$f" || die "cannot write CT-DIFF.patch"
}

write_build_artefacts() {  # patch = snapshot..worktree, new files included, .claude/ included on purpose
  local bytes
  rm -f -- "$RUN/index2"
  bytes=$(build_output_bytes)
  ((bytes <= MAX_BUILD_BYTES)) || { put failed "build output too large ($((bytes / 1024)) KB, limit $((MAX_BUILD_BYTES / 1024)) KB)"; return 1; }
  art_git read-tree "$SNAP" \
    && art_git add -A \
    && force_add_allowed "$WT" art_git \
    && art_git "${DIFF_CFG[@]}" diff --cached "${DIFF_OPT[@]}" --no-textconv --binary --no-renames "$SNAP" -- > "$RUN/patch.diff" \
    && art_git "${DIFF_CFG[@]}" diff --cached --no-textconv --no-renames --name-only -z "$SNAP" -- > "$RUN/files.z" \
    || { put failed "cannot build the patch"; return 1; }
  (($(stat -c %s "$RUN/patch.diff") <= MAX_BUILD_BYTES)) || { put failed "build patch too large (limit $((MAX_BUILD_BYTES / 1024)) KB)"; return 1; }
}

build_output_bytes() {  # size of what Codex added or changed (the worktree's own index has the checkout stat data)
  wt_git "$WT_GITDIR" "$WT" "$SNAP" ls-files -z -m -o --exclude-standard 2> /dev/null \
    | (cd "$WT" && xargs -0 -r stat -c %s -- 2> /dev/null) | awk '{s += $1} END {print s + 0}'
}

compose_prompt() { { printf '%s\n' "$GUARD_TEXT"; cat -- "$1"; } > "$RUN/prompt.txt"; }

write_review_task() {
  if [[ -n $TASK_FILE ]]; then cp -- "$TASK_FILE" "$RUN/task.txt"; return; fi
  if [[ -n $PLAN_FILE ]]; then
    cat > "$RUN/task.txt" <<'TEXT'
Review the plan in the file CT-DIFF.patch in the current directory.
Find gaps, wrong assumptions and risks that make the plan fail. Read the repository files the plan names.
Report each real problem as one finding: dimension, severity (BLOCKER, MAJOR, MINOR or NIT), file, line, summary, scenario, fix.
Return JSON that matches the output schema. Return {"findings":[]} if you find nothing.
TEXT
  else
    cat > "$RUN/task.txt" <<'TEXT'
Review the change in the file CT-DIFF.patch in the current directory (a unified diff; the working tree is the state after the change).
Find real defects only: wrong behavior, security problems, data loss, missing tests, broken edge cases. Do not report style.
Report each defect as one finding: dimension, severity (BLOCKER, MAJOR, MINOR or NIT), file, line, summary, scenario, fix.
Return JSON that matches the output schema. Return {"findings":[]} if you find nothing.
TEXT
  fi
}

refuse_if_untracked_too_big() {
  local bytes
  bytes=$(untracked_bytes)
  ((bytes <= MAX_UNTRACKED_MB * 1048576)) || refuse "untracked files add $((bytes / 1048576)) MB (limit $MAX_UNTRACKED_MB MB)"
}

untracked_bytes() {
  git -C "$REPO_ROOT" ls-files -z -o --exclude-standard -- . ':(exclude).claude' \
    | (cd "$REPO_ROOT" && xargs -0 -r stat -c %s -- 2> /dev/null) | awk '{s += $1} END {print s + 0}'
}
