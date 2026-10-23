# shellcheck shell=bash
# Sourced by check.sh before the sections, never run on its own. Shared by
# checks/05-runner.sh and checks/06-lock.sh, which both drive scratch copies of
# this check.sh.

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

# fixture_mktemp <bin> <dir>: a mktemp in <bin> that makes everything in
# <dir>, for a fixture run put first on PATH. A runner killed outright runs no
# EXIT trap, so its scratch directory outlives it; made in <dir>, it goes
# with the case's own scratch instead of piling up in the system's. A stub,
# not TMPDIR: macOS's mktemp ignores TMPDIR for `mktemp -d`, and for `-t`
# too, preferring the per-user temporary directory (observed 2026-10-22,
# macOS 27.0.1); only -p moves it.
fixture_mktemp() {
  mkdir -p "$1" "$2"
  # shellcheck disable=SC2016  # expanded by the stub, not here
  printf '#!/bin/sh\nexec /usr/bin/mktemp -p "%s" "$@"\n' "$2" > "$1/mktemp"
  chmod +x "$1/mktemp"
}

# The check.sh scratch directories in the system's per-user temporary
# directory, one per line: those holding a section's `<n>.d`. One whose run
# was killed before its first section started is empty, has no shape to be
# told by, and is missed.
system_temp_runs() {
  local entry marks
  for entry in "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"*/; do
    marks=("$entry"[0-9]*.d)
    [ -e "${marks[0]}" ] && printf '%s\n' "${entry%/}"
  done
  return 0
}
