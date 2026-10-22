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
