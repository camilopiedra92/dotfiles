#!/usr/bin/env bash
# Every check this repo runs, in one place.
#
# You run it by hand, the pre-commit hook runs it, and CI runs it. That is the
# point: checks written twice drift, and the moment local and CI disagree you
# stop trusting either one. CI installs what is missing and then calls this
# file, so a green tick means exactly what a clean run here means.
#
# Usage:  ./check.sh [--strict] [--staged]
#
# This file is the runner: arguments, strict mode, the helpers every check
# shares, and the verdict. The checks are in checks/, one file per area, run in
# file-name order; a new area is a new file, and nothing here lists it.
#
# This repo targets macOS only, so every check here applies everywhere it runs
# and none of them are conditional on the platform.
#
# A skipped check is a hole in coverage, not a neutral outcome: the tool was
# missing, nothing ran, and the run still ends green. That is not theoretical —
# it is how this repo reported success while never once validating the Ghostty
# config. Strict mode turns a skip into a failure, so coverage cannot shrink
# without the run going red. It is on automatically under CI and in the
# pre-commit hook, which is what makes CI's promise ("green here means a clean
# run there") true by construction rather than by a list somebody remembers to
# update. Both are gates: they decide whether something lands, so a run that
# checked nothing must not read as one that passed. Invoked by hand it is a
# report and not a gate, and there an amber skip is the useful answer.
#
# Every check here is a function invoked indirectly, by name, through check().
# The linter cannot see that, and would report all of them as unused code, or
# their bodies as unreachable. Both codes are listed because which one you get
# depends on the shellcheck version: 0.11 reports SC2329, older ones SC2317.
# shellcheck disable=SC2329,SC2317
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# git hands a hook GIT_INDEX_FILE -- the relative .git/index for a plain commit
# from the main checkout, an absolute path otherwise -- and, run from a linked
# worktree, GIT_DIR; `git -c` and `--literal-pathspecs` add GIT_CONFIG_PARAMETERS
# and GIT_LITERAL_PATHSPECS (all measured with git 2.55, hooks that printed
# their environment). Most checks build throwaway repositories, and an inherited
# GIT_DIR sends their git calls to this one: committed from a worktree, the
# sdd-init check committed into the branch being committed and its `git init`
# set core.bare in this repository's config. So no GIT_ variable reaches the
# checks -- every one of them, not a list, since a list is what missed GIT_DIR.
# The index is kept in THIS_INDEX for the two calls about this repository,
# which must read what is being committed (this_repo_git).
drop_hook_git_env() {
  local name
  THIS_INDEX=${GIT_INDEX_FILE:-}
  for name in $(compgen -e); do
    case "$name" in GIT_*) unset "$name" ;; esac
  done
  # Nor does this machine's git config: the checks build throwaway
  # repositories meant to behave as on a CI runner, and the global config
  # (signing, hooks, fsmonitor) would make them behave as on this laptop. With
  # commit.gpgsign on and an empty ssh-agent, every scratch `git commit`
  # failed (observed 2026-10-13: 2 failures, "failed to write commit object").
  # Set here, after the loop above would have erased them, and not at the call
  # site, so the order cannot drift. A check that needs a global config of its
  # own points GIT_CONFIG_GLOBAL at a file in its scratch HOME.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}
drop_hook_git_env
this_repo_git() {
  if [ -n "$THIS_INDEX" ]; then GIT_INDEX_FILE=$THIS_INDEX git "$@"; else git "$@"; fi
}

# Every CI system sets CI, so the strict path needs no wiring in the workflow
# and cannot be forgotten there. --strict reproduces it locally, which is the
# only way to test this behaviour without pushing.
#
# --staged runs only the sections the staged paths select (see Selection
# below). It is the pre-commit hook's tier; without it every section runs,
# which is what CI does and what the merge gate rests on.
STRICT=0
STAGED=0
[ -n "${CI:-}" ] && STRICT=1
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --staged) STAGED=1 ;;
    *)
      echo "usage: ./check.sh [--strict] [--staged]" >&2
      exit 2
      ;;
  esac
done

# Report every failure in one run rather than dying on the first. When you are
# about to commit, knowing there are three problems beats finding them one
# restart at a time.
FAILED=0
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
DIM=$'\033[90m'
OFF=$'\033[0m'

check() {
  local name=$1
  shift
  local out
  if out=$("$@" 2>&1); then
    printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$name"
  else
    printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$name"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/       /'
    FAILED=1
  fi
}

# A tool that belongs on this machine is missing, so the check never ran. On
# your laptop that is a nudge to install it; under strict it is a failure,
# because a check that did not run must never read the same as one that passed.
skip() {
  if [ "$STRICT" -eq 1 ]; then
    printf '  %sFAIL%s %s %s(not installed: %s)%s\n' "$RED" "$OFF" "$1" "$DIM" "$2" "$OFF"
    FAILED=1
  else
    printf '  %sskip%s %s %s(%s)%s\n' "$YELLOW" "$OFF" "$1" "$DIM" "$2" "$OFF"
  fi
}

# ── Selection ────────────────────────────────────────────────────────────────
# A section says which paths its checks exercise in lines of its own,
# `# covers: <pattern> [<pattern>...]`, bash patterns over a repository path
# in which * also crosses /. A section with no such line runs for every
# change. Under --staged, a section runs when a staged path matches one of
# its patterns, and on any doubt every section runs: a staged change to the
# runner, the hooks, the helpers in checks/lib/, a declaration, a section
# that comes or goes, or a path under checks/ nobody declares. CI runs
# everything, so what this tier misses is caught before it can merge.
SECTIONS=(checks/*.sh)

# Sets PICKED[i]=1 for each section to run, or ALL to the reason every
# section runs. The staged list goes through a file because it is
# NUL-separated, which a command substitution cannot hold.
select_staged() {
  local list status path i p hit
  list=$(mktemp) || {
    echo "check.sh: cannot create a temporary file for the staged paths" >&2
    return 1
  }
  if ! this_repo_git diff --cached --name-status --no-renames -z > "$list"; then
    ALL="the staged paths could not be read"
    rm -f "$list"
    return 0
  fi
  for i in "${!SECTIONS[@]}"; do
    [ -n "${COVERS[i]}" ] || PICKED[i]=1
  done
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$path" in
      check.sh | githooks/* | checks/lib/*)
        ALL="$path is staged"
        break
        ;;
      checks/[0-9][0-9]-*.sh)
        hit=
        for i in "${!SECTIONS[@]}"; do
          [ "${SECTIONS[i]}" = "$path" ] && hit=$i
        done
        # A declaration is compared as the two versions' lines, not read out
        # of a diff: `git diff | grep -q` dies of SIGPIPE under pipefail
        # once the diff outgrows a pipe buffer, and a coloured diff hides it.
        if [ "$status" = A ] || [ "$status" = D ] || [ -z "$hit" ] ||
          [ "$(this_repo_git show "HEAD:$path" | sed -n 's/^# covers://p')" != "$(this_repo_git show ":$path" | sed -n 's/^# covers://p')" ]; then
          ALL="$path is staged"
          break
        fi
        # The section itself, and below, whatever declares it as a path.
        PICKED[hit]=1
        ;;
    esac
    # Globbing is off while the patterns are split: `macos/*` expanded
    # against the tree would name only the files there now, and a staged
    # deletion would match nothing.
    hit=0
    set -f
    for i in "${!SECTIONS[@]}"; do
      # shellcheck disable=SC2086  # split on purpose, globbing off
      for p in ${COVERS[i]}; do
        # shellcheck disable=SC2053  # the right side is a pattern on purpose
        if [[ $path == $p ]]; then
          PICKED[i]=1
          hit=1
        fi
      done
    done
    set +f
    case "$path" in checks/*) [ "$hit" -eq 1 ] || {
      ALL="$path is staged"
      break
    } ;;
    esac
  done < "$list"
  rm -f "$list"
}

COVERS=()
PICKED=()
ALL=
for i in "${!SECTIONS[@]}"; do
  COVERS[i]=$(sed -n 's/^# covers://p' "${SECTIONS[i]}")
done
if [ "$STAGED" -eq 0 ]; then
  ALL=everything
else
  select_staged || exit 1
  if [ -n "$ALL" ]; then
    printf '\n%sStaged changes select every section: %s%s\n' "$DIM" "$ALL" "$OFF"
  else
    unpicked=
    for i in "${!SECTIONS[@]}"; do
      [ -n "${PICKED[i]:-}" ] && continue
      name=${SECTIONS[i]#checks/}
      unpicked="$unpicked ${name%.sh}"
    done
    printf '\n%sStaged changes select %s of %s sections' "$DIM" "${#PICKED[@]}" "${#SECTIONS[@]}"
    [ -n "$unpicked" ] && printf '; not selected:%s' "$unpicked"
    printf '%s\n' "$OFF"
  fi
fi

# ── Sections ─────────────────────────────────────────────────────────────────
# The helpers more than one section uses are sourced here, once; then each
# section runs in a subshell of its own, so it sees STRICT, the helpers above
# and those in checks/lib/, and nothing another section defines -- a section
# that leaned on another's function would pass only in file order, and did
# (three of them, found 2026-10-21). The files are linted directly (see
# Lint), so shellcheck has nothing to follow here.
# shellcheck source=/dev/null
for lib in checks/lib/*.sh; do
  . "$lib"
done

# Several sections at once, one per CPU, because the slow ones are slow on
# waiting rather than on computing: the run takes about as long as its
# slowest section instead of their sum. Each section's output goes to a file
# and is printed whole once it and every section before it have finished, so
# what you read is a sequential run's output, in file order; FAILED is the OR
# of the sections' statuses, so the verdict and strictness are a sequential
# run's too. bash 3.2 has no `wait -n`, so the loop polls, every 20 ms: at
# 100 ms the runner's own checks, ~30 runs of instant fake sections, took 2.4 s
# longer (measured 2026-10-22). Waiting on the oldest section instead would
# leave CPUs idle behind a slow one.
RUN=$(mktemp -d) || {
  echo "check.sh: cannot create a temporary directory for the sections' output" >&2
  exit 1
}
trap 'rm -rf "$RUN"' EXIT
JOBS=$(sysctl -n hw.ncpu) || JOBS=1

# The done marker is written after the section's last line: without it, the
# section stopped early -- an `exit`, an unset variable under set -u -- which
# is a failure even when the status says 0.
run_section() {
  (
    FAILED=0
    # shellcheck source=/dev/null
    . "${SECTIONS[$1]}"
    : > "$RUN/$1.done"
    exit "$FAILED"
  ) > "$RUN/$1.out" 2>&1
  echo "$?" > "$RUN/$1.status"
  mv "$RUN/$1.status" "$RUN/$1.rc"
}

ORDER=()
for i in "${!SECTIONS[@]}"; do
  if [ -n "$ALL" ] || [ -n "${PICKED[i]:-}" ]; then ORDER+=("$i"); fi
done
started=0
shown=0
while [ "$shown" -lt "${#ORDER[@]}" ]; do
  finished=$(find "$RUN" -name '*.rc' | wc -l)
  while [ "$started" -lt "${#ORDER[@]}" ] && [ $((started - finished)) -lt "$JOBS" ]; do
    run_section "${ORDER[started]}" &
    started=$((started + 1))
  done
  i=${ORDER[shown]}
  if [ ! -e "$RUN/$i.rc" ]; then
    sleep 0.02
    continue
  fi
  cat "$RUN/$i.out"
  status=$(cat "$RUN/$i.rc")
  if [ ! -e "$RUN/$i.done" ]; then
    name=${SECTIONS[i]#checks/}
    printf '  %sFAIL%s %s stopped before its last line (exit %s)\n' "$RED" "$OFF" "${name%.sh}" "$status"
    FAILED=1
  elif [ "$status" -ne 0 ]; then
    FAILED=1
  fi
  shown=$((shown + 1))
done
wait

# ── Result ───────────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  printf '\n%sAll checks passed%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sSome checks failed%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
