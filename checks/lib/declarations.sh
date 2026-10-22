# shellcheck shell=bash
# Sourced by check.sh before the sections, never run on its own. Used by
# checks/07-declarations.sh on this repository and by checks/05-runner.sh on
# scratch ones.

# A declared pattern that matches no tracked path is a section that has
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
