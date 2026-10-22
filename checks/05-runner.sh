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
# as the section that reads every section's text does), 30-c declares nothing. Plus the
# runner's other inputs, so a change to each can be staged.
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

# A repository of fake sections for how a run executes them. Each argument is
# "<name>:<body>", written to checks/<name>.sh; every run starts from its own.
sections_repo() {
  local dir=$1 spec
  shift
  git init -q "$dir"
  cp -p check.sh "$dir/"
  mkdir -p "$dir/checks/lib"
  echo 'helper() { :; }' > "$dir/checks/lib/helpers.sh"
  for spec in "$@"; do
    printf '%s\n' "${spec#*:}" > "$dir/checks/${spec%%:*}.sh"
  done
}

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

# US3: a declared pattern that matches no tracked path is a section that has
# silently stopped being selected. Reads patterns as check.sh does (the
# `# covers:` lines, split with globbing off, matched with [[ == ]]), over the
# tracked paths on stdin; prints "<section>: <pattern>" for each miss.
declaration_misses() {
  local dir=$1 paths section name patterns pattern path hit
  paths=$(cat)
  for section in "$dir"/checks/[0-9][0-9]-*.sh; do
    name=${section##*/}
    patterns=$(sed -n 's/^# covers://p' "$section")
    set -f
    # shellcheck disable=SC2086  # split on purpose, globbing off
    for pattern in $patterns; do
      hit=
      while IFS= read -r path; do
        # shellcheck disable=SC2053  # the right side is a pattern on purpose
        if [[ $path == $pattern ]]; then
          hit=1
          break
        fi
      done <<< "$paths"
      [ -n "$hit" ] || printf '%s: %s\n' "${name%.sh}" "$pattern"
    done
    set +f
  done
}

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

# This repository's own declarations.
this_repo_declarations() {
  local out
  out=$(this_repo_git ls-files | declaration_misses .)
  [ -z "$out" ] || {
    echo "declared patterns matching no tracked file:"
    printf '%s\n' "$out"
    return 1
  }
}
check "every pattern this repository's sections declare matches a tracked file" this_repo_declarations
