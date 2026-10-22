# shellcheck shell=bash
# Helpers more than one section uses. check.sh sources every file here once,
# before the sections, so each section's shell has them; a section never
# relies on a function another section defines, because each runs in a shell
# of its own. A change here runs every section in the pre-commit hook too.

# Every extraction of an install.sh step ends at the header of the next step,
# and this is the check that it took exactly one. A step extracted up to a
# prose comment once swallowed the step added after it: that step ran for
# real, against this machine's HOME and the real CLI, inside a test that had
# stubbed only `uv`. Used by the install and machine-profile sections.
one_step_only() {
  local steps=$1 n
  # The range is inclusive, so its last line is the next step's header (or the
  # closing log line): that one is the boundary, not a step that was taken.
  n=$(sed '$d' "$steps" | grep -c '^# --- [0-9]')
  [ "$n" -eq 1 ] || {
    echo "extraction took $n steps from install.sh, not one:"
    sed '$d' "$steps" | grep '^# --- [0-9]'
    return 1
  }
}

# A profile directory named `test` with nothing in it, and a machine file
# naming it. Shared by every test that runs a per-machine script: the machine
# profile, defaults, Dock and file-handler sections.
machine_fixture() {
  mkdir -p "$1/machines/test"
  echo test > "$1/machine"
}
