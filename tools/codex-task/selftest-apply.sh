# Selftest cases: build, apply and its refusals, the allowed list.
# Sourced by selftest.sh (it holds the framework and the stub).

case_apply_happy() {
  begin apply_happy; fresh_repo
  do_build
  want status "$ST" "done exit=0 | guard ok"
  local head; head=$(git rev-parse HEAD)
  cd dir || return
  run_ct apply "$RUN"
  cd "$R" || return
  want "apply rc (run from a subdirectory)" "$RC" 0
  want "a.txt" "$(tail -1 a.txt)" "line 21"; want "new.txt" "$(cat new.txt)" new
  want "b.txt" "$(tail -1 dir/b.txt)" mod
  want_true "nothing staged" git diff --cached --quiet
  want "HEAD unchanged" "$(git rev-parse HEAD)" "$head"
  want_has "unstaged edit" "$(git status --porcelain)" " M a.txt"
  want_no "no undo hints" "$OUT" "git "; want_no "no undo word" "$OUT" undo
  want_true "applied marker" test -e "$RUN/applied"
  want_has "status applied" "$(bash "$CT" status "$RUN")" "applied"
  run_ct apply "$RUN"; want_fail "second apply" "$RC"; want_has "second apply text" "$OUT" "already applied"
  finish
}

case_apply_exit_nonzero() {
  begin apply_exit_nonzero; fresh_repo
  STUB_EXIT=3 do_build
  want_has "status" "$ST" "done exit=3"
  run_ct apply "$RUN"
  want_fail "rc" "$RC"; want_has "text" "$OUT" "exit"
  want_false "nothing applied" test -e new.txt
  finish
}

case_apply_missing_done() {
  begin apply_missing_done; fresh_repo
  STUB_SLEEP=600 start_build "$HOOK_DEFAULT; $(UP_HOOK)"
  want_true running wait_state running
  run_ct apply "$RUN"
  want_fail rc "$RC"; want_has text "$OUT" "not finished"
  want_false "nothing applied" test -e new.txt
  bash "$CT" cancel "$RUN" > /dev/null 2>&1
  finish
}

case_apply_sha_mismatch() {
  begin apply_sha_mismatch; fresh_repo
  do_build
  echo "# tampered" >> "$RUN/patch.diff"
  run_ct apply "$RUN"
  want_fail rc "$RC"; want_has text "$OUT" "sha"
  want_false "nothing applied" test -e new.txt
  finish
}

case_apply_allowed() {
  begin apply_allowed; fresh_repo
  do_build "" "a.txt"
  run_ct apply "$RUN"
  want_fail "outside allowed list" "$RC"; want_has text "$OUT" "allowed"
  want "a.txt untouched" "$(tail -1 a.txt)" "line 20"; want_false "new.txt absent" test -e new.txt
  do_build "echo mod >> dir/b.txt" "dir"
  run_ct apply "$RUN"
  want_fail "a prefix needs a trailing slash" "$RC"
  do_build "echo mod >> dir/b.txt" "dir/"
  run_ct apply "$RUN"
  want "directory prefix with slash" "$RC" 0
  finish
}

case_apply_base_changed() {
  begin apply_base_changed; fresh_repo
  do_build
  sed -i '1s/.*/changed line/' a.txt
  run_ct apply "$RUN"
  want_fail "modified file (hunks do not overlap)" "$RC"; want_has text "$OUT" "base changed"
  want "a.txt not patched" "$(tail -1 a.txt)" "line 20"; want_false "new.txt absent" test -e new.txt
  git checkout -q -- a.txt; echo mine > new.txt
  run_ct apply "$RUN"
  want_fail "new file already present" "$RC"; want_has "text 2" "$OUT" "base changed"
  finish
}

case_apply_deleted_drift() {  # the patch deletes a file; the owner edited that file after the snapshot
  begin apply_deleted_drift; fresh_repo
  do_build 'rm old.txt' 'old.txt'
  want status "$ST" "done exit=0 | guard ok"
  echo drift >> old.txt
  run_ct apply "$RUN"
  want_fail "edited file" "$RC"; want_has "text" "$OUT" "base changed"
  want_true "old.txt kept" grep -q drift old.txt
  rm old.txt
  run_ct apply "$RUN"
  want_fail "file already gone" "$RC"; want_has "text 2" "$OUT" "base changed"
  finish
}

case_apply_check_fails() {
  begin apply_check_fails; fresh_repo
  do_build "echo 'line 21' >> a.txt" "a.txt"
  sed -i 's/^ line 19$/ line XX/' "$RUN/patch.diff"
  printf '0 %s\n' "$(sha_of < "$RUN/patch.diff")" > "$RUN/done"
  run_ct apply "$RUN"
  want_fail rc "$RC"; want_has text "$OUT" "does not apply"
  want "a.txt untouched" "$(tail -1 a.txt)" "line 20"
  finish
}

case_apply_claude_path() {
  begin apply_claude_path; fresh_repo
  do_build 'mkdir -p .claude; echo x > .claude/x; echo n > new.txt' 'new.txt'
  printf '.claude/\n' >> "$RUN/allowed"  # the start refuses such an entry; apply must refuse it too
  want_has "guard changed" "$ST" "guard changed"
  run_ct apply "$RUN"
  want_fail rc "$RC"; want_has text "$OUT" ".claude"
  want_false "new.txt not applied" test -e new.txt
  want_false ".claude not applied" test -e .claude/x
  finish
}

case_apply_guard_only() {  # an empty .claude/ in the worktree: no patch path, only the guard can refuse
  begin apply_guard_only; fresh_repo
  do_build 'mkdir -p .claude; echo n > new.txt' 'new.txt'
  want_has "guard changed" "$ST" "guard changed"
  want_false "no .claude path in the patch" grep -q '\.claude' "$RUN/patch.diff"
  run_ct apply "$RUN"
  want_fail rc "$RC"; want_has text "$OUT" "guard changed"
  want_false "new.txt not applied" test -e new.txt
  finish
}

case_apply_cancelled() {  # a run with a cancel marker is never applied, even with a good done file
  begin apply_cancelled; fresh_repo
  do_build
  want status "$ST" "done exit=0 | guard ok"
  : > "$RUN/cancelled"
  run_ct apply "$RUN"
  want_fail rc "$RC"; want_has text "$OUT" "cancelled"
  want_false "new.txt not applied" test -e new.txt
  want_no "not marked applied" "$(bash "$CT" status "$RUN")" "applied"
  finish
}

case_apply_modes() {  # symlinks (120000) and submodules (160000) never go through apply
  begin apply_modes; fresh_repo
  ln -s a.txt existing-link; git add existing-link; git commit -q -m link
  do_build 'ln -s /etc/passwd lnk; echo n > new.txt' $'lnk\nnew.txt'
  run_ct apply "$RUN"
  want_fail "new symlink" "$RC"; want_has "new symlink text" "$OUT" "120000"
  want_false "nothing applied (new.txt)" test -e new.txt; want_false "no link" test -L lnk
  do_build 'ln -sfn dir/b.txt existing-link; echo n > new.txt' $'existing-link\nnew.txt'
  run_ct apply "$RUN"
  want_fail "changed symlink" "$RC"; want_has "changed symlink text" "$OUT" "120000"
  want "link kept" "$(readlink existing-link)" a.txt
  do_build 'git init -q sub; git -C sub commit -q --allow-empty -m x; echo n > new.txt' $'sub\nnew.txt'
  want_has "the patch holds a gitlink" "$(cat "$RUN/patch.diff")" "160000"
  run_ct apply "$RUN"
  want_fail "submodule" "$RC"; want_has "submodule text" "$OUT" "160000"
  want_false "nothing applied (sub)" test -e sub; want_false "nothing applied (new.txt 2)" test -e new.txt
  finish
}

case_apply_file_kinds() {
  begin apply_file_kinds; fresh_repo
  do_build 'printf "\377\000\377\001" > bin.dat; rm old.txt; mv "sp ace.txt" "sp ace renamed.txt"; echo n > "new sp.txt"' \
    $'bin.dat\nold.txt\nsp ace.txt\nsp ace renamed.txt\nnew sp.txt'
  run_ct apply "$RUN"
  want rc "$RC" 0
  want "binary" "$(od -An -tx1 bin.dat | tr -d ' \n')" "ff00ff01"
  want_false "deleted" test -e old.txt
  want_false "rename: old name gone" test -e "sp ace.txt"
  want "rename: new name" "$(cat "sp ace renamed.txt")" spaced
  want "space in path" "$(cat "new sp.txt")" n
  finish
}

case_apply_not_build() {
  begin apply_not_build; fresh_repo
  launch review --base main; waitrun
  run_ct apply "$RUN"; want_fail "apply refuses a review run" "$RC"
  finish
}

case_apply_ignored_allowed() {  # an allowed exact path that git ignores is kept, in the snapshot and in the patch
  begin apply_ignored_allowed; fresh_repo
  echo keep > keep.log
  do_build 'echo more >> keep.log; echo out > out.log; echo n > new.txt' $'keep.log\nout.log\nnew.txt'
  want status "$ST" "done exit=0 | guard ok"
  want_true "new ignored file in the patch" grep -q 'out.log' "$RUN/patch.diff"
  want_true "existing ignored file in the patch" grep -q 'keep.log' "$RUN/patch.diff"
  run_ct apply "$RUN"
  want rc "$RC" 0
  want "out.log" "$(cat out.log)" out
  want "keep.log" "$(cat keep.log)" "$(printf 'keep\nmore')"
  finish
}

case_allowed_validation() {  # a bad allowed file fails before the claim
  begin allowed_validation; fresh_repo
  local bad
  : > "$A"; run_ct build "$P" "$A"
  want "empty file: rc" "$RC" 1; want_has "empty file: text" "$OUT" "allowed"
  for bad in '/etc/passwd' '../x' 'a/../b' '..' '.claude/x' '.claude/' '.claude' ' lead' 'trail ' $'cr\r' \
             '.' './' './a.txt' 'a/./b' '.git/config' 'a/.git/x' '.git'; do
    printf 'ok.txt\n%s\n' "$bad" > "$A"
    run_ct build "$P" "$A"
    want "'$bad': rc" "$RC" 1; want_has "'$bad': text" "$OUT" "allowed"
  done
  want "codex never started" "$(exec_calls)" 0
  want_false "no run dir" test -e "$R/.claude"
  want "registry empty" "$(ls "$CODEX_TASK_HOME/registry" 2>/dev/null | wc -l)" 0
  printf 'a.txt\n\ndir/\n' > "$A"; run_ct build "$P" "$A"
  want "a good file (with a blank line) starts" "$RC" 0
  finish
}

case_apply_literal() {  # an allowed exact path is a literal path: no glob may pull in other ignored files
  begin apply_literal; fresh_repo
  echo keep > 'a*b.log'; echo other > aXb.log
  do_build "echo more >> 'a*b.log'; ls > '$T/list$NCASE'" 'a*b.log'
  want status "$ST" "done exit=0 | guard ok"
  want_has "the literal file is in the snapshot" "$(cat "$T/list$NCASE")" 'a*b.log'
  want_no "the glob match is not" "$(cat "$T/list$NCASE")" aXb.log
  finish
}

case_build_too_large() {  # the build output is measured before add; the patch is capped too
  begin build_too_large; fresh_repo
  CODEX_TASK_MAX_BUILD_BYTES=1000 do_build 'head -c 5000 /dev/zero | tr "\0" x > big.txt' 'big.txt'
  want_has "output over the cap" "$ST" "failed build output too large"
  want_false "no patch is built" test -e "$RUN/patch.diff"
  CODEX_TASK_MAX_BUILD_BYTES=1000 do_build 'head -c 900 /dev/urandom > rnd.bin' 'rnd.bin'
  want_has "a patch over the cap" "$ST" "failed build patch too large"
  do_build 'echo small > s.txt' 's.txt'
  want "a small build is fine" "$ST" "done exit=0 | guard ok"
  finish
}

case_attr_source() {  # a .gitattributes planted by Codex must not make the wrapper run configured drivers
  begin attr_source; fresh_repo
  printf '#!/bin/sh\necho ran >> "%s/filt.mark"\nif [ -n "${1:-}" ]; then cat "$1"; else cat; fi\n' "$T" > "$T/filter.sh"
  chmod +x "$T/filter.sh"
  git config --file "$T/gitconfig" filter.evil.clean "$T/filter.sh"
  git config --file "$T/gitconfig" diff.evil.textconv "$T/filter.sh"
  cat > "$T/hook$NCASE.sh" <<EOF
printf '* filter=evil diff=evil\n' > .gitattributes
echo n > new.txt
GIT_INDEX_FILE='$T/ctl.idx' git add -A > /dev/null 2>&1
GIT_INDEX_FILE='$T/ctl.idx' git diff --cached > /dev/null 2>&1
[ -e '$T/filt.mark' ] && mv '$T/filt.mark' '$T/filt.control'
EOF
  rm -f "$T/filt.mark" "$T/filt.control"
  do_build "bash '$T/hook$NCASE.sh'" 'new.txt'
  git config --file "$T/gitconfig" --remove-section filter.evil
  git config --file "$T/gitconfig" --remove-section diff.evil
  want_true "control: the planted attributes run the driver for an unhardened call" test -e "$T/filt.control"
  want_false "the wrapper never ran the driver" test -e "$T/filt.mark"
  want "run is done" "$ST" "done exit=0 | guard ok"
  finish
}
