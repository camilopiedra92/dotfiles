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

# What the system's temporary directory holds of check.sh's scratch before
# the cases, compared after them at the end of this file.
RUNNER_TEMP_BEFORE=$(system_temp_runs)

# Three fake sections: 10-a covers a/* and checks/fixture/*, 20-b covers b/*,
# b.txt and checks/[0-9][0-9]-*.sh (as a section that reads every section's
# text does), 30-c declares nothing. Plus the runner's other inputs, so a
# change to each can be staged.
runner_repo() {
  local dir=$1
  git init -q "$dir"
  cp -p check.sh "$dir/"
  mkdir -p "$dir/checks/lib" "$dir/checks/fixture" "$dir/checks/data" \
    "$dir/githooks" "$dir/a" "$dir/b"
  printf '# covers: a/* checks/fixture/*\ncheck "a ran" true\n' > "$dir/checks/10-a.sh"
  printf '# covers: b/*\n# covers: b.txt checks/[0-9][0-9]-*.sh\ncheck "b ran" true\n' > "$dir/checks/20-b.sh"
  printf 'check "c ran" true\n' > "$dir/checks/30-c.sh"
  echo 'helper() { :; }' > "$dir/checks/lib/helpers.sh"
  for f in a/x a/z b/y b.txt checks/fixture/f checks/data/f checks/data/f.sh githooks/pre-commit; do
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

# What a review of the selection found (2026-10-22), each case red before its fix.
staged_review_findings() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"

  # A section's body edit also selects the sections that read every section
  # (20-b), not only itself: it continued past the pattern loop.
  printf 'check "a also" true\n' >> "$tmp/r/checks/10-a.sh"
  git -C "$tmp/r" add checks/10-a.sh
  runner_run "$tmp/r" --staged
  expect_ran "section body edit" "a b c" || return 1

  # A declaration change inside a diff far larger than a pipe buffer: a
  # `git diff | grep -q` dies of SIGPIPE under pipefail and misses it. In
  # 20-b, because there "a declaration changed" (every section) and "a body
  # changed" (20-b and what has none) differ; in 10-a they would not.
  git -C "$tmp/r" reset -q --hard
  sed -i '' 's|^# covers: b.txt |# covers: b.md |' "$tmp/r/checks/20-b.sh"
  awk 'BEGIN { for (i = 0; i < 8000; i++) print "# padding line " i " of a large diff" }' >> "$tmp/r/checks/20-b.sh"
  git -C "$tmp/r" add checks/20-b.sh
  runner_run "$tmp/r" --staged
  expect_ran "large diff" "a b c" || return 1

  # A repository whose config colours every diff.
  git -C "$tmp/r" reset -q --hard
  git -C "$tmp/r" config color.diff always
  sed -i '' 's|^# covers: b.txt |# covers: b.md |' "$tmp/r/checks/20-b.sh"
  git -C "$tmp/r" add checks/20-b.sh
  runner_run "$tmp/r" --staged
  expect_ran "coloured diff" "a b c" || return 1
  git -C "$tmp/r" config --unset color.diff

  # `checks/[0-9][0-9]-*.sh` is a section; a .sh in a subdirectory is not, and
  # nobody declares it, so it selects every section.
  git -C "$tmp/r" reset -q --hard
  echo '# touched' >> "$tmp/r/checks/data/f.sh"
  git -C "$tmp/r" add checks/data/f.sh
  runner_run "$tmp/r" --staged
  expect_ran "script in a subdirectory" "a b c" || return 1
}
check "--staged: a section edit reaches the sections that read it, a large or coloured diff hides no declaration, a nested script is no section" staged_review_findings

# A scratch directory that cannot be made is said, in both modes. macOS's
# mktemp falls back to its own directory when TMPDIR is unusable (observed
# 2026-10-22), so the failure is a stub answering 1.
runner_without_scratch() {
  local tmp mode
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"
  echo two > "$tmp/r/a/x"
  git -C "$tmp/r" add a/x
  mkdir "$tmp/bin"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/mktemp"
  chmod +x "$tmp/bin/mktemp"
  for mode in "" --staged; do
    RC=0
    # shellcheck disable=SC2086  # $mode is empty or one flag
    OUT=$(cd "$tmp/r" && PATH="$tmp/bin:$PATH" ./check.sh $mode 2>&1) || RC=$?
    [ "$RC" -ne 0 ] || {
      echo "no scratch directory${mode:+ ($mode)}: exit 0"
      return 1
    }
    case "$OUT" in *"cannot create a temporary"*) ;; *)
      echo "no scratch directory${mode:+ ($mode)}: no reason given, got: $OUT"
      return 1
      ;;
    esac
  done
}
check "a run that cannot make its scratch directory says so" runner_without_scratch

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
  printf '# covers: b/*\n# covers: b.txt checks/[0-9][0-9]-*.sh\ncheck "b ran" false\n' > "$tmp/r/checks/20-b.sh"
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

# sections_repo, the repository of fake sections below, is in checks/lib/runner.sh.

# Sections finishing in the reverse of file order: each prints a header and
# two lines with a pause between, so output written as it happens would
# interleave. A sequential run's output is the reference.
parallel_output_in_order() {
  local tmp lines
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" \
    '10-a:printf "\nA\n"; sleep 0.6; check a1 true; sleep 0.1; check a2 true' \
    '20-b:printf "\nB\n"; sleep 0.3; check b1 true; sleep 0.1; check b2 true' \
    '30-c:printf "\nC\n"; check c1 true; sleep 0.1; check c2 true'
  runner_run "$tmp/r"
  lines=$(printf '%s\n' "$OUT" | grep -E '^(A|B|C)$|^  ok   [abc][12]$' | tr -s ' ' | tr '\n' '|')
  [ "$lines" = "A| ok a1| ok a2|B| ok b1| ok b2|C| ok c1| ok c2|" ] || {
    echo "expected each section whole, in file order; got: $lines"
    printf '%s\n' "$OUT"
    return 1
  }
  [ "$RC" -eq 0 ] || {
    echo "exit $RC from passing sections"
    return 1
  }
  expect_line "passing" "All checks passed" || return 1

  # One failing section: the run fails, its output whole in its place.
  printf '%s\n' 'printf "\nB\n"; sleep 0.3; check b1 false; sleep 0.1; check b2 true' > "$tmp/r/checks/20-b.sh"
  runner_run "$tmp/r"
  lines=$(printf '%s\n' "$OUT" | grep -E '^(A|B|C)$|^  (ok|FAIL) [ abc]*[abc][12]$' | tr -s ' ' | tr '\n' '|')
  [ "$lines" = "A| ok a1| ok a2|B| FAIL b1| ok b2|C| ok c1| ok c2|" ] || {
    echo "one failing section: expected its output whole in place; got: $lines"
    return 1
  }
  [ "$RC" -eq 1 ] || {
    echo "one failing section: exit $RC, not 1"
    return 1
  }
  expect_line "failing" "Some checks failed" || return 1
}
check "a run prints each section whole and in file order, whatever finishes first, with one verdict" parallel_output_in_order

# Each section runs in a shell of its own: a function another section defines
# is not there, and a section that stops early is a failed section, not a
# dead or a green run.
sections_stand_alone() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  # shellcheck disable=SC2016  # expanded by the fake section, not here
  sections_repo "$tmp/r" \
    '10-a:a_only() { :; }; check "a ran" true' \
    '20-b:check "b uses a_only" a_only' \
    '30-c:check "c ran" true; exit 0; check "c after exit" true' \
    '40-d:check "d ran" true; echo "$NOT_SET_ANYWHERE"; check "d after unset" true' \
    '50-e:check "e ran" true'
  runner_run "$tmp/r"
  expect_line "hidden dependency" "  FAIL b uses a_only" || return 1
  expect_line "exit" "  FAIL 30-c stopped before its last line (exit 0)" || return 1
  expect_line "unset variable" "  FAIL 40-d stopped before its last line (exit" || return 1
  expect_line "after them" "  ok   e ran" || return 1
  case "$OUT" in *"after exit"* | *"after unset"*)
    echo "a section went on past its own stop: $OUT"
    return 1
    ;;
  esac
  [ "$RC" -eq 1 ] || {
    echo "exit $RC, not 1"
    return 1
  }
}
check "each section runs alone: another's function is not there, and stopping early fails it" sections_stand_alone

strict_skip_still_fails() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" '10-a:skip "tool" "brew install tool"' '20-b:check "b ran" true'
  CI='' runner_run "$tmp/r"
  [ "$RC" -eq 0 ] || {
    echo "a skip by hand: exit $RC, not 0"
    return 1
  }
  CI='' runner_run "$tmp/r" --strict
  [ "$RC" -eq 1 ] || {
    echo "a skip under --strict: exit $RC, not 1"
    return 1
  }
  expect_line "strict skip" "  FAIL tool (not installed: brew install tool)" || return 1
}
check "a skip fails the run under --strict, and only then" strict_skip_still_fails

# At most as many sections at once as sysctl reports CPUs, here a stub
# answering 2: each section registers itself in $LIVE under its own file name
# (a subshell's $$ is its parent's, so every section would collide), records
# how many are registered, and leaves. Two at once proves they overlap; three, the cap broken.
sections_capped_at_cpus() {
  local tmp body max
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin" "$tmp/live"
  printf '#!/bin/sh\necho 2\n' > "$tmp/bin/sysctl"
  chmod +x "$tmp/bin/sysctl"
  # shellcheck disable=SC2016  # expanded by the fake section, not here
  body='me=$LIVE/${BASH_SOURCE[0]##*/}; mkdir "$me"; ls "$LIVE" | wc -l >> "$LIVE.counts"; sleep 0.4; rmdir "$me"'
  sections_repo "$tmp/r" "10-a:$body" "20-b:$body" "30-c:$body" "40-d:$body" "50-e:$body"
  LIVE=$tmp/live PATH="$tmp/bin:$PATH" runner_run "$tmp/r"
  max=$(sort -n "$tmp/live.counts" | tail -n1 | tr -d ' ')
  [ "$max" = 2 ] || {
    echo "with 2 CPUs, expected at most and at least 2 sections at once, saw ${max:-none}:"
    printf '%s\n' "$OUT"
    return 1
  }
}
check "sections run at the same time, no more at once than the CPUs" sections_capped_at_cpus

# US3: the reader is checks/lib/declarations.sh, run on this repository by
# checks/07-declarations.sh.
declared_patterns_match_something() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"
  out=$(git -C "$tmp/r" ls-files | declaration_misses "$tmp/r")
  [ -z "$out" ] || {
    echo "a fixture whose patterns all match something reported: $out"
    return 1
  }
  # A typo in one pattern of a line that has others that match.
  sed -i '' 's|^# covers: b.txt |# covers: b.tx |' "$tmp/r/checks/20-b.sh"
  out=$(git -C "$tmp/r" ls-files | declaration_misses "$tmp/r")
  [ "$out" = "20-b: b.tx" ] || {
    echo "expected exactly \"20-b: b.tx\", got: $out"
    return 1
  }
}
check "a declared pattern that matches no tracked file is reported, with its section" declared_patterns_match_something

# What the second review found (2026-10-22), each case red before its fix.

# A section that stops by `return`, or on a syntax error, is as failed as one
# that exits. Nothing else fails here, so the verdict is the stop's alone.
early_stops_alone_fail() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" \
    '10-a:check "a ran" true; return 3; check "a after return" true' \
    $'20-b:check "b ran" true\nif then fi\ncheck "b after syntax error" true' \
    '30-c:check "c ran" true'
  runner_run "$tmp/r"
  expect_line "return" "  FAIL 10-a stopped before its last line" || return 1
  expect_line "syntax error" "  FAIL 20-b stopped before its last line" || return 1
  expect_line "after them" "  ok   c ran" || return 1
  [ "$RC" -eq 1 ] || {
    echo "exit $RC, not 1, when only early stops fail"
    return 1
  }
  expect_line "verdict" "Some checks failed" || return 1
}
check "a section that returns or hits a syntax error fails the run, alone" early_stops_alone_fail

# The contract's exit 2 on a flag it does not know, and no scratch left behind.
runner_usage_and_cleanup() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" '10-a:check "a ran" true'
  runner_run "$tmp/r" --bogus
  [ "$RC" -eq 2 ] || {
    echo "a flag it does not know: exit $RC, not 2"
    return 1
  }
  expect_line "usage" "usage: ./check.sh [--strict] [--staged]" || return 1
  # macOS's mktemp ignores TMPDIR when given no template (observed
  # 2026-10-22), so the scratch is found through a stub that makes everything
  # under one directory.
  mkdir "$tmp/scratch" "$tmp/bin"
  # shellcheck disable=SC2016  # expanded by the stub, not here
  printf '#!/bin/sh\np=$SCRATCH/m$(ls "$SCRATCH" | wc -l | tr -d " ")\nif [ "$1" = -d ]; then mkdir "$p"; else : > "$p"; fi\necho "$p"\n' > "$tmp/bin/mktemp"
  chmod +x "$tmp/bin/mktemp"
  SCRATCH=$tmp/scratch PATH="$tmp/bin:$PATH" runner_run "$tmp/r"
  [ "$RC" -eq 0 ] || {
    echo "the run with the stub mktemp: exit $RC"
    return 1
  }
  [ -z "$(ls -A "$tmp/scratch")" ] || {
    echo "a run left files behind: $(ls -A "$tmp/scratch")"
    return 1
  }
}
check "an unknown flag exits 2 with the usage line, and a run leaves no scratch behind" runner_usage_and_cleanup

# A section removed from the index but still in the tree is a section that
# goes: only the status says so, since the file is still there to read.
staged_removal_from_index() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"
  git -C "$tmp/r" rm -q --cached checks/30-c.sh
  runner_run "$tmp/r" --staged
  expect_ran "git rm --cached" "a b c" || return 1
  expect_line "git rm --cached" "every section: checks/30-c.sh is staged" || return 1
}
check "--staged selects every section when a section leaves the index but not the tree" staged_removal_from_index

# INT or TERM to the runner takes the running sections, and what they started,
# with it: they would otherwise go on writing into a scratch directory that
# is gone. The sleeps carry a length nothing else uses, to find them by.
signals_stop_sections() {
  local tmp pid left
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"; pkill -f "sleep 31.7" 2>/dev/null' RETURN
  sections_repo "$tmp/r" '10-a:sleep 31.7; check "a ran" true' '20-b:sleep 31.7; check "b ran" true'
  # A TERM that lands before the runner has set its EXIT trap leaves its scratch.
  fixture_mktemp "$tmp/bin" "$tmp/scratch"
  (cd "$tmp/r" && PATH="$tmp/bin:$PATH" exec ./check.sh > /dev/null 2>&1) &
  pid=$!
  sleep 0.6
  kill -TERM "$pid"
  wait "$pid" 2> /dev/null
  sleep 0.3
  left=$(pgrep -f "sleep 31.7" | wc -l | tr -d ' ')
  [ "$left" -eq 0 ] || {
    echo "after TERM to the runner, $left sleeps from its sections are still running"
    return 1
  }
}
check "TERM to the runner stops its sections and what they started" signals_stop_sections

# The declaration check is its own section, declaring nothing, so it runs in
# every commit. Inside 05-runner, which declares check.sh, a commit that renamed
# a declared file never reached it (found by review, 2026-10-22).
declarations_run_in_the_hook() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  runner_repo "$tmp/r"
  cp -p checks/07-declarations.sh "$tmp/r/checks/"
  cp -p checks/lib/declarations.sh "$tmp/r/checks/lib/"
  git -C "$tmp/r" add -A
  git -C "$tmp/r" -c user.name=t -c user.email=t@t commit -q -m declarations
  git -C "$tmp/r" mv b.txt b2.txt
  runner_run "$tmp/r" --staged
  expect_line "stale pattern" "20-b: b.txt" || return 1
  [ "$RC" -eq 1 ] || {
    echo "a rename that strands a declared pattern: exit $RC, not 1"
    return 1
  }
}
check "a staged rename that strands a declared pattern fails the hook's tier" declarations_run_in_the_hook

# What the second review found (2026-10-22): `set -m` gave each section the
# terminal as stdin, so one that reads it stopped on SIGTTIN, and gave each
# foreground child of the runner the terminal's SIGINT, so ^C missed the
# runner. Both need a terminal: `script` and a pty from python provide one.
# Neither is looked for first: macOS ships /usr/bin/script and
# /usr/bin/python3, and a missing one fails its case rather than passing it
# unrun.
section_stdin_is_not_the_terminal() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" '10-a:check "stdin is not a terminal" test ! -t 0'
  out=$(cd "$tmp/r" && script -q /dev/null ./check.sh < /dev/null 2>&1 | tr -d '\r')
  case "$out" in *"ok"*"stdin is not a terminal"*) ;; *)
    echo "a section run from a terminal has the terminal as stdin: $out"
    return 1
    ;;
  esac
}
check "a section run from a terminal does not get the terminal as stdin" section_stdin_is_not_the_terminal

# ^C reaches the runner as the terminal sends it, to its foreground group. The
# pty stays open until the runner is gone: closing it hangs up the whole group
# and the sections die whether or not the runner's INT trap works (a review
# removed the trap and this case stayed green, 2026-10-22). So the case wants
# the trap's own work: exit 130, and no section left while the pty is open.
# One attempt hits the runner between two children about one time in six on
# the old runner, so three go in, 0.4 s apart.
ctrl_c_stops_sections() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"; pkill -f "sleep 31.7" 2>/dev/null' RETURN
  sections_repo "$tmp/r" '10-a:sleep 31.7; check "a ran" true'
  # Its runner is killed outright when ^C does not stop it.
  fixture_mktemp "$tmp/bin" "$tmp/scratch"
  out=$(
    PATH="$tmp/bin:$PATH" python3 -I - "$tmp/r" << 'PY'
import os, pty, select, signal, subprocess, sys, time
pid, fd = pty.fork()
if pid == 0:
    # a section runs as a background job, which ignores INT, and exec keeps that
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.chdir(sys.argv[1])
    os.execv('/bin/bash', ['bash', './check.sh'])
def drain(seconds):
    # a pty nobody reads keeps the process that wrote to it from exiting
    end = time.time() + seconds
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                os.read(fd, 4096)
            except OSError:
                return
drain(1.0)
done = None
for _ in range(3):
    os.write(fd, b'\x03')
    drain(0.4)
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
if not done:
    print('the runner was still running after three ^C')
    os.kill(pid, 9)
    sys.exit(1)
left = subprocess.run(['pgrep', '-f', 'sleep 31.7'], capture_output=True, text=True).stdout.split()
if not (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 130):
    print('the runner ended with wait status %d, not exit 130' % status)
    sys.exit(1)
if left:
    print('%d sections still running after the runner ended' % len(left))
    sys.exit(1)
PY
  ) || {
    echo "^C from a terminal: $out"
    return 1
  }
}
check "^C from a terminal stops the sections" ctrl_c_stops_sections

# The status is the shell's: 128 plus the signal. TERM only: a process started
# with & by a non-interactive shell ignores INT, so only a terminal's ^C (the
# case above) reaches the runner's INT trap.
signal_statuses() {
  local tmp pid
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"; pkill -f "sleep 31.7" 2>/dev/null' RETURN
  sections_repo "$tmp/r" '10-a:sleep 31.7'
  # As in signals_stop_sections.
  fixture_mktemp "$tmp/bin" "$tmp/scratch"
  (cd "$tmp/r" && PATH="$tmp/bin:$PATH" exec ./check.sh > /dev/null 2>&1) &
  pid=$!
  sleep 0.6
  kill -TERM "$pid"
  RC=0
  wait "$pid" 2> /dev/null || RC=$?
  [ "$RC" -eq 143 ] || {
    echo "TERM to the runner: exit $RC, not 143"
    return 1
  }
}
check "TERM ends the runner with 143" signal_statuses

# A signal right after the runner's scratch directory exists, before anything
# else runs, still takes the directory with it. Landed there by a DEBUG trap
# from BASH_ENV, which bash runs before each command of the runner's own shell
# (its subshells do not inherit it): the first command once RUN is set sends
# TERM to the runner itself. From outside, a signal lands either inside
# mktemp, where bash dies before the assignment and no order of the trap
# helps, or there by timing alone (both probed 2026-10-22). Red with the EXIT
# trap set after mktemp, as 004 had it.
signal_after_scratch_removes_it() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" '10-a:check "a ran" true'
  fixture_mktemp "$tmp/bin" "$tmp/scratch"
  # shellcheck disable=SC2016  # expanded by the runner, not here
  printf '%s\n' 'trap '\''[ -z "${RUN:-}" ] || [ -n "${fired:-}" ] || { fired=1; kill -TERM $$; }'\'' DEBUG' > "$tmp/env.sh"
  RC=0
  (cd "$tmp/r" && BASH_ENV="$tmp/env.sh" PATH="$tmp/bin:$PATH" ./check.sh > /dev/null 2>&1) || RC=$?
  [ "$RC" -eq 143 ] || {
    echo "TERM right after the scratch directory: exit $RC, not 143"
    return 1
  }
  [ -z "$(ls -A "$tmp/scratch")" ] || {
    echo "TERM right after the scratch directory was made left it behind"
    return 1
  }
}
check "TERM right after the scratch directory is made removes it" signal_after_scratch_removes_it

# The trap is in before RUN is the runner's own, so a RUN from the
# environment must never be what it removes: TERM just before mktemp, landed
# the same way, with RUN naming a directory the run did not make.
signal_before_scratch_spares_inherited_run() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sections_repo "$tmp/r" '10-a:check "a ran" true'
  mkdir "$tmp/inherited"
  # shellcheck disable=SC2016  # expanded by the runner, not here
  printf '%s\n' 'trap '\''case $BASH_COMMAND in "RUN=\$(mktemp -d 9>&-)") kill -TERM $$ ;; esac'\'' DEBUG' > "$tmp/env.sh"
  RC=0
  (cd "$tmp/r" && RUN="$tmp/inherited" BASH_ENV="$tmp/env.sh" ./check.sh > /dev/null 2>&1) || RC=$?
  [ "$RC" -eq 143 ] || {
    echo "TERM just before the scratch directory: exit $RC, not 143"
    return 1
  }
  [ -d "$tmp/inherited" ] || {
    echo "TERM just before the scratch directory removed the RUN it inherited"
    return 1
  }
}
check "TERM before the scratch directory spares a RUN from the environment" signal_before_scratch_spares_inherited_run

# Last: no case left a runner's scratch directory in the system's temporary
# directory. A runner killed outright runs no EXIT trap, and its scratch
# outlives it. On 2026-10-22 ~180 of this section's were there, nearly all
# from revisions before 004 merged, which left every fixture's (a clean run
# of this revision leaves none); four, by their shape, from the ^C case
# killing a runner that did not stop. The cases that can end a runner
# without its EXIT trap make its scratch with fixture_mktemp. Compared by
# name with the list taken before the cases; an unlocked suite of another
# branch running at the same moment could show here, which the lock (006)
# rules out once every branch has it.
runner_temp_untouched() {
  local new
  new=$(comm -13 <(printf '%s\n' "$RUNNER_TEMP_BEFORE" | sort) <(system_temp_runs | sort))
  [ -z "$new" ] || {
    printf 'left in the system temporary directory:\n%s\n' "$new"
    return 1
  }
}
check "no case left a run's scratch in the system temporary directory" runner_temp_untouched
