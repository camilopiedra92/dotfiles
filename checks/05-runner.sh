# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: check.sh

# ── Runner ───────────────────────────────────────────────────────────────────
# check.sh itself: which sections a commit selects, and how a run reports
# them. Driven against a byte-identical copy of this check.sh in a scratch
# repository whose sections are fakes that only say they ran, so a case shows
# what the runner chose and nothing else. The copy cds to its own directory,
# so it never reads this repository's sections.
printf '\n%sRunner%s\n' "$DIM" "$OFF"

# Three fake sections: 10-a covers a/* and checks/fixture/*, 20-b covers b/*,
# b.txt and checks/*.sh (as a section that reads every section's text does,
# and which also matches checks/lib/), 30-c declares nothing. Plus the
# runner's other inputs, so a change to each can be staged.
runner_repo() {
  local dir=$1
  git init -q "$dir"
  cp -p check.sh "$dir/"
  mkdir -p "$dir/checks/lib" "$dir/checks/fixture" "$dir/checks/data" \
    "$dir/githooks" "$dir/a" "$dir/b"
  printf '# covers: a/* checks/fixture/*\ncheck "a ran" true\n' > "$dir/checks/10-a.sh"
  printf '# covers: b/*\n# covers: b.txt checks/*.sh\ncheck "b ran" true\n' > "$dir/checks/20-b.sh"
  printf 'check "c ran" true\n' > "$dir/checks/30-c.sh"
  echo 'helper() { :; }' > "$dir/checks/lib/helpers.sh"
  for f in a/x a/z b.txt checks/fixture/f checks/data/f githooks/pre-commit; do
    echo one > "$dir/$f"
  done
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m fixture
}

# Runs the copy with the given flags; sets OUT (colours removed), RC, and RAN,
# the fake sections that said they ran, in output order.
runner_run() {
  local dir=$1
  shift
  RC=0
  OUT=$(cd "$dir" && ./check.sh "$@" 2>&1) || RC=$?
  OUT=$(printf '%s\n' "$OUT" | sed $'s/\033\\[[0-9;]*m//g')
  RAN=$(printf '%s\n' "$OUT" | sed -n 's/^  ok   \([a-z]\) ran$/\1/p; s/^  FAIL \([a-z]\) ran$/\1/p' | tr '\n' ' ')
  RAN=${RAN% }
}

# expect_ran <case> <sections that must have run, in order>
expect_ran() {
  [ "$RAN" = "$2" ] || {
    echo "$1: expected [$2] to run, ran [$RAN]:"
    printf '%s\n' "$OUT"
    return 1
  }
}

# expect_line <case> <text the output must contain>
expect_line() {
  case "$OUT" in *"$2"*) ;; *)
    echo "$1: expected the line \"$2\" in:"
    printf '%s\n' "$OUT"
    return 1
    ;;
  esac
}

staged_selects_what_it_covers() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"

  echo two > "$tmp/r/a/x"
  git -C "$tmp/r" add a/x
  runner_run "$tmp/r" --staged
  expect_ran "a/x" "a c" || return 1
  expect_line "a/x" "Staged changes select 2 of 3 sections; not selected: 20-b" || return 1
  [ "$RC" -eq 0 ] || {
    echo "a/x: exit $RC from a passing selection"
    return 1
  }
  expect_line "a/x" "All checks passed" || return 1

  # A pattern's * crosses /, as bash's [[ == ]] does.
  git -C "$tmp/r" reset -q --hard
  mkdir -p "$tmp/r/a/deep"
  echo new > "$tmp/r/a/deep/f"
  git -C "$tmp/r" add a/deep/f
  runner_run "$tmp/r" --staged
  expect_ran "a/deep/f" "a c" || return 1

  # Several lines of one section's declaration are one union.
  git -C "$tmp/r" reset -q --hard
  echo two > "$tmp/r/b.txt"
  git -C "$tmp/r" add b.txt
  runner_run "$tmp/r" --staged
  expect_ran "b.txt" "b c" || return 1

  # A fixture under checks/ that a section declares selects that section.
  git -C "$tmp/r" reset -q --hard
  echo two > "$tmp/r/checks/fixture/f"
  git -C "$tmp/r" add checks/fixture/f
  runner_run "$tmp/r" --staged
  expect_ran "checks/fixture/f" "a c" || return 1

  # Without --staged, everything runs, and no selection line is printed.
  runner_run "$tmp/r"
  expect_ran "full run" "a b c" || return 1
  case "$OUT" in *"Staged changes"*)
    echo "full run: printed a selection line: $OUT"
    return 1
    ;;
  esac
}
check "--staged runs the sections the staged paths match, and every section that declares nothing" staged_selects_what_it_covers

staged_machinery_selects_everything() {
  local tmp path
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"
  # check.sh is touched by appending a comment, which the copy then runs.
  for path in check.sh githooks/pre-commit checks/lib/helpers.sh checks/data/f; do
    git -C "$tmp/r" reset -q --hard
    echo '# touched' >> "$tmp/r/$path"
    git -C "$tmp/r" add "$path"
    runner_run "$tmp/r" --staged
    expect_ran "$path" "a b c" || return 1
    expect_line "$path" "Staged changes select every section: $path is staged" || return 1
  done
}
check "--staged selects every section for check.sh, githooks/, checks/lib/ and an undeclared path under checks/" staged_machinery_selects_everything

staged_section_edits() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"

  # A change to a section's checks, its declaration untouched: that section.
  printf 'check "b also" true\n' >> "$tmp/r/checks/20-b.sh"
  git -C "$tmp/r" add checks/20-b.sh
  runner_run "$tmp/r" --staged
  expect_ran "section body" "b c" || return 1

  # A declaration changed: everything, since it changes what is selected.
  git -C "$tmp/r" reset -q --hard
  sed -i '' 's|^# covers: b.txt |# covers: b.md |' "$tmp/r/checks/20-b.sh"
  git -C "$tmp/r" add checks/20-b.sh
  runner_run "$tmp/r" --staged
  expect_ran "declaration" "a b c" || return 1
  expect_line "declaration" "every section: checks/20-b.sh is staged" || return 1

  # A new section, even one declaring nothing.
  git -C "$tmp/r" reset -q --hard
  printf 'check "d ran" true\n' > "$tmp/r/checks/40-d.sh"
  git -C "$tmp/r" add checks/40-d.sh
  runner_run "$tmp/r" --staged
  expect_ran "new section" "a b c d" || return 1

  # A deleted section, even one that declared nothing.
  git -C "$tmp/r" reset -q --hard
  git -C "$tmp/r" clean -qfd
  git -C "$tmp/r" rm -q checks/30-c.sh
  runner_run "$tmp/r" --staged
  expect_ran "deleted section" "a b" || return 1
  expect_line "deleted section" "every section: checks/30-c.sh is staged" || return 1
}
check "--staged runs an edited section, and every section when a declaration changes or a section comes or goes" staged_section_edits

staged_paths_edge_cases() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"

  # Nothing staged: only what declares nothing, and a pass, strict included.
  # The flags in either order.
  runner_run "$tmp/r" --staged --strict
  expect_ran "nothing staged" "c" || return 1
  expect_line "nothing staged" "Staged changes select 1 of 3 sections; not selected: 10-a 20-b" || return 1
  [ "$RC" -eq 0 ] || {
    echo "nothing staged: exit $RC; a section not selected is not a skip"
    return 1
  }

  # A rename is its old path and its new one: a/x is 10-a's, b/x is 20-b's.
  git -C "$tmp/r" mv a/x b/x
  runner_run "$tmp/r" --staged
  expect_ran "rename" "a b c" || return 1

  # A deleted path still selects what covered it. Were `a/*` expanded against
  # the tree while being read, it would name only a/x, and a/z would match
  # nothing.
  git -C "$tmp/r" reset -q --hard
  git -C "$tmp/r" rm -q a/z
  runner_run "$tmp/r" --staged
  expect_ran "deleted path" "a c" || return 1

  # The index read is the one being committed: git hands `commit -a` and
  # `commit <path>` a temporary one, and check.sh keeps it as THIS_INDEX.
  git -C "$tmp/r" reset -q --hard
  echo two > "$tmp/r/b.txt"
  echo two > "$tmp/r/a/x"
  git -C "$tmp/r" add a/x
  cp "$tmp/r/.git/index" "$tmp/other-index"
  GIT_INDEX_FILE=$tmp/other-index git -C "$tmp/r" reset -q -- a/x
  GIT_INDEX_FILE=$tmp/other-index git -C "$tmp/r" add b.txt
  RC=0
  OUT=$(cd "$tmp/r" && GIT_INDEX_FILE=$tmp/other-index ./check.sh --staged 2>&1) || RC=$?
  RAN=$(printf '%s\n' "$OUT" | sed $'s/\033\\[[0-9;]*m//g' | sed -n 's/^  ok   \([a-z]\) ran$/\1/p' | tr '\n' ' ')
  RAN=${RAN% }
  expect_ran "commit index" "b c" || return 1

  # A staged list git cannot read: everything, and the run says why.
  git -C "$tmp/r" reset -q --hard
  echo garbage > "$tmp/r/.git/index"
  runner_run "$tmp/r" --staged
  expect_ran "unreadable index" "a b c" || return 1
  expect_line "unreadable index" "Staged changes select every section: the staged paths could not be read" || return 1
}
check "--staged: nothing staged, renames, deletions, the commit's own index, and an index git cannot read" staged_paths_edge_cases

staged_failure_fails() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"
  printf '# covers: b/*\n# covers: b.txt checks/*.sh\ncheck "b ran" false\n' > "$tmp/r/checks/20-b.sh"
  git -C "$tmp/r" -c user.name=t -c user.email=t@t commit -qam "b fails"
  echo two > "$tmp/r/b.txt"
  git -C "$tmp/r" add b.txt
  runner_run "$tmp/r" --staged
  [ "$RC" -eq 1 ] || {
    echo "a failing selected section: exit $RC, not 1"
    return 1
  }
  expect_line "failing section" "Some checks failed" || return 1
  # And one that is not selected cannot fail the run.
  git -C "$tmp/r" reset -q --hard
  echo two > "$tmp/r/a/x"
  git -C "$tmp/r" add a/x
  runner_run "$tmp/r" --staged
  [ "$RC" -eq 0 ] || {
    echo "a failing section not selected: exit $RC, not 0"
    return 1
  }
}
check "--staged fails when a selected section fails, and only then" staged_failure_fails
