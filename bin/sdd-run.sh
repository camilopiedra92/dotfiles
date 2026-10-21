#!/usr/bin/env bash
# Runs a feature through the sdd-routed Spec Kit workflow, each phase on the
# model its routing row names, every agent step a contained pass
# (specs/003-sdd-model-routing, contracts/sdd-run.md).
#
# Usage:  sdd-run start [--set <phase>.<field>=<value> ...] "<description>"
#         sdd-run start --from <feature dir>
#         sdd-run resume <run_id> [approve|reject|<option>|retry]
#         sdd-run abort <run_id>
#         sdd-run routing [--set <phase>.<field>=<value> ...] [--init-local]
#         sdd-run usage <run_id>
#
# The work is in sdd-run.py, on the system Python: the one interpreter whose
# path no repository or version manager can change. On macOS it is a stub
# until the Command Line Tools are installed, so it is checked here first.
set -euo pipefail

/usr/bin/python3 -I -c 'import sys' > /dev/null 2>&1 || {
  echo "sdd-run: /usr/bin/python3 does not run: install the Command Line Tools (xcode-select --install)" >&2
  exit 1
}
self=$(realpath "${BASH_SOURCE[0]}")
exec /usr/bin/python3 -I "$(dirname "$self")/sdd-run.py" "$@"
