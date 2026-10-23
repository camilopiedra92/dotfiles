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
  # (signing, hooks) would make them behave as on this laptop. With
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

# ── One run at a time ────────────────────────────────────────────────────────
# One top-level run per user on this machine runs its sections at a time,
# whichever worktree or clone it was started in; a second waits for the first
# and says once for whom (specs/006-check-lock). Observed 2026-10-22: four
# suites from different worktrees overlapped, each over every CPU, the laptop
# ran hot for hours and one section failed under the contention alone.
#
# The turn is a flock(2) taken through macOS's /usr/bin/lockf on descriptor 9,
# open on a per-user file: the kernel drops it when the last holder of that
# open file closes it, on any exit, SIGKILL included, so a dead run blocks
# nobody and no age or pid decides staleness (probed 2026-10-22, research R2).
# The file's existence means nothing, and the `<pid> <path>` line the holder
# writes into it only words the waiting line, never makes anyone wait. It
# names the run that holds the turn, or nobody: the holder empties it as it
# exits, while the turn is still its own, and a waiter names nobody for a pid
# that is gone -- the record of a run killed outright, or stopped before its
# EXIT trap was set, which never emptied it. What remains: such a record
# whose pid is still taken -- by the dead run until its parent reaps it, or
# by another process the system has given it since -- read in the instant
# between the next holder taking the turn and writing its own, or while
# something other than a run (a bare lockf) holds it, names that pid (R4).
#
# The place is asked of the system with getconf and not read from TMPDIR: an
# environment variable a tool or sandbox may point elsewhere would give two
# runs two different locks, and they would overlap in silence (R6).
#
# A run started from within a run -- 05-runner's ~30 copies of this file, or
# anything a section starts -- is part of it: CHECK_SH_RUN, exported once the
# turn is taken, makes it skip all of this. Without that it would wait forever
# for the parent that waits for it. Exporting it by hand bypasses the lock.
#
# Taken after the arguments, so a usage error never waits, and before the
# selection, so a run that waited reads the index as it is when its turn comes
# and has printed nothing but its waiting line (R7).
if [ -z "${CHECK_SH_RUN:-}" ]; then
  lock=$(getconf DARWIN_USER_TEMP_DIR)dotfiles-check.lock
  # The braces keep bash's own message about a failed open off stderr while
  # the descriptor itself stays open in this shell.
  { exec 9>> "$lock"; } 2> /dev/null || {
    echo "check.sh: cannot take the run lock $lock" >&2
    exit 1
  }
  lock_status=0
  lockf -s -t 0 9 || lock_status=$?
  # 75 is EX_TEMPFAIL, "held by another process" (man lockf).
  if [ "$lock_status" -eq 75 ]; then
    holder_pid='' holder_path=''
    read -r holder_pid holder_path < "$lock"
    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2> /dev/null; then
      echo "check.sh: waiting for the run of pid $holder_pid in $holder_path to finish" >&2
    else
      echo "check.sh: waiting for another run to finish" >&2
    fi
    # The wait is a background lockf the runner `wait`s for, not a foreground
    # one: bash defers a trapped signal until its foreground child returns,
    # and `wait` returns as soon as one arrives (research R3). The lockf goes
    # with the runner: left behind, it would take the turn when the holder
    # ends (06-lock, "TERM while waiting", red that way 2026-10-22). It locks
    # the open file it shares with this shell, so this shell holds the turn
    # once it has exited. The traps are set first, so no signal lands between
    # the start and the trap; the runner's own come later, with the sections.
    lock_waiter=''
    trap 'kill "$lock_waiter" 2> /dev/null; exit 130' INT
    trap 'kill "$lock_waiter" 2> /dev/null; exit 143' TERM
    lockf -s 9 &
    lock_waiter=$!
    lock_status=0
    wait "$lock_waiter" || lock_status=$?
    trap - INT TERM
  fi
  [ "$lock_status" -eq 0 ] || {
    echo "check.sh: cannot take the run lock $lock" >&2
    exit 1
  }
  # Truncates the same inode: the lock on the open file stays.
  printf '%s %s\n' "$$" "$PWD" > "$lock"
  export CHECK_SH_RUN=$$
  # Emptied by the EXIT trap below. Set only here, so a nested run, which
  # holds nothing, empties nothing.
  lock_record=$lock
fi

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
  list=$(exec 9>&- && mktemp) || {
    echo "check.sh: cannot create a temporary file for the staged paths" >&2
    return 1
  }
  if ! this_repo_git diff --cached --name-status --no-renames -z > "$list" 9>&-; then
    ALL="the staged paths could not be read"
    rm -f "$list" 9>&-
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
          [ "$(exec 9>&- && this_repo_git show "HEAD:$path" | sed -n 's/^# covers://p')" != "$(exec 9>&- && this_repo_git show ":$path" | sed -n 's/^# covers://p')" ]; then
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
  rm -f "$list" 9>&-
}

COVERS=()
PICKED=()
ALL=
for i in "${!SECTIONS[@]}"; do
  COVERS[i]=$(exec 9>&- && sed -n 's/^# covers://p' "${SECTIONS[i]}")
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
#
# The EXIT trap goes in before the scratch directory is made, so a signal
# landing once RUN holds its path still removes it; with the trap after
# mktemp, one landing between the two left it (05-runner, "TERM right after
# the scratch directory is made", red that way 2026-10-22). What stays open is
# a signal inside mktemp itself: bash dies before assigning RUN, and the
# directory, made but never named, stays. RUN is emptied first so a value
# from the environment is never what the trap removes (05-runner, "TERM
# before the scratch directory spares a RUN from the environment", red
# without the emptying 2026-10-22). The run's record goes
# with it too (One run at a time, above). A run that stops before this trap
# leaves it, as a run killed outright does.
RUN=''
trap '[ -z "$RUN" ] || rm -rf "$RUN" 9>&-; [ -z "${lock_record:-}" ] || : > "$lock_record"' EXIT
RUN=$(exec 9>&- && mktemp -d) || {
  echo "check.sh: cannot create a temporary directory for the sections' output" >&2
  exit 1
}
JOBS=$(exec 9>&- && sysctl -n hw.ncpu) || JOBS=1

# The done marker is written after the section's last line: without it, the
# section stopped early -- an `exit`, a `return`, a syntax error, an unset
# variable under set -u -- which is a failure even when the status says 0.
run_section() {
  # Only the runner's own shell holds the run lock (descriptor 9, "One run at
  # a time" above): flock belongs to the open file, so any process that
  # inherited the descriptor keeps the turn while it lives. Probed 2026-10-22
  # (research R2): a child holding it kept the lock after its parent's
  # SIGKILL, one started after `exec 9>&-` did not. Closed here, at the top of
  # the background subshell this function runs in, and not only in the
  # section's own subshell below: this one waits for the section, so a runner
  # killed outright would otherwise leave it holding the turn as long as the
  # section ran (06-lock, "a run killed outright frees the turn", red that
  # way). A no-op in a nested run, which never opened it. The runner's own
  # commands after the turn is taken each carry `9>&-` for the same reason,
  # and each `$(...)` starts with `exec 9>&-`, which closes it in the fork the
  # substitution is, not in the runner: the fork holds the lock until its
  # command returns otherwise (research R8).
  exec 9>&-
  # The section runs from a copy of its own name with the marker appended, so
  # a `return` or a syntax error, which end a sourced file quietly with status
  # 0, leave the marker unwritten like an `exit` does.
  mkdir "$RUN/$1.d"
  local copy="$RUN/$1.d/${SECTIONS[$1]##*/}"
  {
    cat "${SECTIONS[$1]}"
    printf '\n: > "%s/%s.done"\n' "$RUN" "$1"
  } > "$copy"
  (
    FAILED=0
    # shellcheck source=/dev/null
    . "$copy"
    exit "$FAILED"
  ) > "$RUN/$1.out" 2>&1
  echo "$?" > "$RUN/$1.status"
  mv "$RUN/$1.status" "$RUN/$1.rc"
}

# INT or TERM stop the sections too, and what each started: a section's
# subshell, the checks it runs and their children would otherwise outlive the
# runner and write into a scratch directory that is gone. They are found
# through their parent pids, not a process group: `set -m` gave each section
# its own group, which took the terminal's ^C away from the runner and stopped
# any section that read stdin (SIGTTIN; without job control a background
# job's stdin is /dev/null); both seen 2026-10-22 in a pty.
kill_tree() {
  local child
  for child in $(exec 9>&- && pgrep -P "$1"); do kill_tree "$child"; done
  kill -TERM "$1" 2> /dev/null
}
stop_sections() {
  local job
  trap '' INT TERM
  for job in $(exec 9>&- && jobs -p); do kill_tree "$job"; done
  exit "$1"
}
trap 'stop_sections 130' INT
trap 'stop_sections 143' TERM

ORDER=()
for i in "${!SECTIONS[@]}"; do
  if [ -n "$ALL" ] || [ -n "${PICKED[i]:-}" ]; then ORDER+=("$i"); fi
done
started=0
shown=0
while [ "$shown" -lt "${#ORDER[@]}" ]; do
  finished=$(exec 9>&- && find "$RUN" -name '*.rc' | wc -l)
  while [ "$started" -lt "${#ORDER[@]}" ] && [ $((started - finished)) -lt "$JOBS" ]; do
    run_section "${ORDER[started]}" &
    started=$((started + 1))
  done
  i=${ORDER[shown]}
  if [ ! -e "$RUN/$i.rc" ]; then
    sleep 0.02 9>&-
    continue
  fi
  cat "$RUN/$i.out" 9>&-
  status=$(exec 9>&- && cat "$RUN/$i.rc")
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
