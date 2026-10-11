#!/usr/bin/env bash
# Every check this repo runs, in one place.
#
# You run it by hand, the pre-commit hook runs it, and CI runs it. That is the
# point: checks written twice drift, and the moment local and CI disagree you
# stop trusting either one. CI installs what is missing and then calls this
# file, so a green tick means exactly what a clean run here means.
#
# Usage:  ./check.sh [--strict]
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
}
drop_hook_git_env
this_repo_git() {
  if [ -n "$THIS_INDEX" ]; then GIT_INDEX_FILE=$THIS_INDEX git "$@"; else git "$@"; fi
}

# Every CI system sets CI, so the strict path needs no wiring in the workflow
# and cannot be forgotten there. --strict reproduces it locally, which is the
# only way to test this behaviour without pushing.
STRICT=0
[ -n "${CI:-}" ] && STRICT=1
case "${1:-}" in
  "") ;;
  --strict) STRICT=1 ;;
  *)
    echo "usage: ./check.sh [--strict]" >&2
    exit 2
    ;;
esac

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

# The sections, in file-name order, sourced into this shell so they share
# FAILED, STRICT and the helpers above. Sourcing rather than running each as a
# process is the point: one verdict, one strictness, one summary. The files are
# linted directly (see Lint), so shellcheck has nothing to follow here.
# shellcheck source=/dev/null
for section in checks/*.sh; do
  . "$section"
done

# ── Result ───────────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  printf '\n%sAll checks passed%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sSome checks failed%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
