#!/usr/bin/env bash
# Blocks the git operations that destroy work, in the cases a permission rule
# cannot express.
#
# Rules fail here for two structural reasons. They match a command prefix, and
# git permutes flags: `git push origin main --force` never matches
# `Bash(git push --force *)`, so the rule reads as protection while granting
# none. And a deny rule carries no exceptions, so a rule blunt enough to stop
# `git clean -fdx` also stops `git clean -n` -- the dry run, which destroys
# nothing and is how you find out what the real one would do.
#
# Contract: the tool call arrives as JSON on stdin. Exit 2 blocks it and shows
# stderr to Claude; every other status falls through to the permission rules.
# A crashed guard therefore fails open, which is why the operations with no
# safe form at all -- filter-branch, filter-repo, reflog expire, gh repo
# delete -- stay in the deny list, where nothing can wave them through.

set -uo pipefail

# Branches whose history other clones and CI build on.
PROTECTED='main master'

block() {
  printf 'git-guard: %s\n' "$1" >&2
  exit 2
}

# `git clean` deletes untracked files outright. Nothing in git holds a copy --
# the reflog stores commits, and these were never committed -- so there is no
# recovering them. This is also where .env files live, kept out of git on
# purpose and destroyed by -x for exactly that reason.
guard_clean() {
  local a force=0 dry=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --force) force=1 ;;
      --*) ;;
      -*)
        [ "${a#*n}" != "$a" ] && dry=1
        [ "${a#*f}" != "$a" ] && force=1
        ;;
    esac
  done
  [ "$dry" -eq 1 ] && return 0
  [ "$force" -eq 1 ] &&
    block 'git clean deletes untracked files and nothing keeps a copy. Run it with -n first.'
  return 0
}

# --force overwrites whatever the remote had, including commits this clone
# never saw. --force-with-lease refuses when the remote moved, which makes it
# reasonable on a branch you own and still wrong on one others build on.
guard_push() {
  local a force=0 lease=0 positional=0 b
  for a in "$@"; do
    case "$a" in
      --force-with-lease | --force-with-lease=* | --force-if-includes) lease=1 ;;
      --force) force=1 ;;
      --*) ;;
      -*) [ "${a#*f}" != "$a" ] && force=1 ;;
      *) positional=$((positional + 1)) ;;
    esac
  done

  [ "$force" -eq 1 ] &&
    block 'git push --force discards remote commits unconditionally. Use --force-with-lease.'
  [ "$lease" -eq 1 ] || return 0

  for b in $PROTECTED; do
    for a in "$@"; do
      case "$a" in
        "$b" | *:"$b" | */"$b")
          block "force-pushing $b rewrites history other clones depend on."
          ;;
      esac
    done
  done

  # No refspec means the push targets the current branch, so the name to check
  # is not in the command at all.
  if [ "$positional" -eq 0 ]; then
    local head
    head=$(git symbolic-ref --quiet --short HEAD 2> /dev/null) || return 0
    for b in $PROTECTED; do
      [ "$head" = "$b" ] &&
        block "force-pushing $b rewrites history other clones depend on."
    done
  fi
  return 0
}

# `git reset --hard` throws away uncommitted work, and the reflog does not hold
# it: reflog stores commits, not a working tree. With nothing uncommitted it
# discards nothing, so blocking it there is friction that buys no safety --
# the distinction a deny rule has no way to draw.
guard_reset() {
  local dir=$1 a hard=0 dirty
  shift
  for a in "$@"; do
    [ "$a" = --hard ] && hard=1
  done
  [ "$hard" -eq 1 ] || return 0

  if [ -n "$dir" ]; then
    dirty=$(git -C "$dir" status --porcelain 2> /dev/null) || return 0
  else
    dirty=$(git status --porcelain 2> /dev/null) || return 0
  fi
  [ -n "$dirty" ] &&
    block "git reset --hard would discard uncommitted work: $(printf '%s' "$dirty" | head -3 | tr '\n' ' ')"
  return 0
}

inspect() {
  local -a tok
  read -ra tok <<< "$1"
  local n=${#tok[@]} i=0
  [ "$n" -gt 0 ] || return 0

  # Walk past the wrappers Claude Code does not strip before matching rules --
  # `mise exec -- git clean -fdx` is how a git command reaches the shell having
  # matched no git rule at all. The walk stops at the first word it does not
  # recognise, so `echo git clean -fdx` is not read as a git call.
  while [ "$i" -lt "$n" ]; do
    case "${tok[$i]}" in
      mise | devbox | docker | npx | env | timeout | time | nice | nohup | stdbuf | command | builtin | exec | run | --) ;;
      *=*) ;;
      [0-9]*) ;;
      git) break ;;
      *) return 0 ;;
    esac
    i=$((i + 1))
  done
  [ "$i" -lt "$n" ] || return 0

  # Skip git's own options so the subcommand is found wherever it sits, and
  # keep -C, because it decides which repository the reset would empty.
  i=$((i + 1))
  local repo_dir=''
  while [ "$i" -lt "$n" ]; do
    case "${tok[$i]}" in
      -C)
        repo_dir=${tok[$((i + 1))]:-}
        i=$((i + 2))
        ;;
      -c) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0

  local sub=${tok[$i]}
  local -a args=()
  [ "$((i + 1))" -lt "$n" ] && args=("${tok[@]:$((i + 1))}")

  case "$sub" in
    clean) guard_clean ${args[@]+"${args[@]}"} ;;
    push) guard_push ${args[@]+"${args[@]}"} ;;
    reset) guard_reset "$repo_dir" ${args[@]+"${args[@]}"} ;;
  esac
}

# One jq for everything out of the payload, as the statusline does it. A
# payload that is not a Bash call, or not JSON at all, leaves nothing to guard.
CMD=$(jq -r 'if .tool_name == "Bash" then .tool_input.command // "" else "" end' 2> /dev/null)
[ -n "$CMD" ] || exit 0

# Claude Code matches permission rules against each subcommand separately; the
# hook is handed the whole line and has to do the same. Splitting too eagerly
# is the safe direction: a stray fragment is inspected on its own and can only
# add scrutiny, never remove it.
FRAGMENTS=${CMD//&&/$'\n'}
FRAGMENTS=${FRAGMENTS//||/$'\n'}
FRAGMENTS=${FRAGMENTS//;/$'\n'}
FRAGMENTS=${FRAGMENTS//|/$'\n'}

while IFS= read -r fragment; do
  [ -n "$fragment" ] || continue
  inspect "$fragment"
done <<< "$FRAGMENTS"

exit 0
