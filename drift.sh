#!/usr/bin/env bash
# What this machine has that the Brewfile does not declare, and the reverse.
#
# Usage:  ./drift.sh
#
# Deliberately NOT part of check.sh, and not run by CI. Every check in there has
# to mean the same thing on a runner as on your laptop, which is what makes a
# green tick worth trusting. This one cannot: a GitHub runner arrives with its
# own preinstalled packages, so "installed but undeclared" is always true there
# and never interesting. Putting it in check.sh would either break CI forever or
# force an `if [ -z "$CI" ]` around it -- a check that skips itself on the only
# machine that runs it automatically.
#
# So it lives here, next to bump-tools.sh, as something you run on the machine
# the Brewfile is supposed to describe.
#
# `brew bundle check` cannot answer this on its own. It asks whether everything
# declared is installed -- a question a subset always answers yes to. The gap it
# leaves is everything installed and never written down, which is the direction
# drift actually grows in.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

FAILED=0
GREEN=$'\033[32m'
RED=$'\033[31m'
DIM=$'\033[90m'
OFF=$'\033[0m'

# Entries of one kind from the Brewfile, sorted for comm.
declared() { grep -oE "^$1 \"[^\"]+\"" Brewfile | sed "s/^$1 \"//; s/\"\$//" | sort; }

report() {
  local title=$1 hint=$2 items=$3
  if [ -z "$items" ]; then
    printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$title"
  else
    printf '  %sDRIFT%s %s\n' "$RED" "$OFF" "$title"
    printf '%s\n' "$items" | sed 's/^/         /'
    printf '         %s%s%s\n' "$DIM" "$hint" "$OFF"
    FAILED=1
  fi
}

printf '\n%sInstalled but not declared%s\n' "$DIM" "$OFF"

# Only formulae installed on request. Dependencies are noise: they are here
# because something else needed them, not because anyone chose them, and listing
# them buries the handful that a person actually has to decide about.
report "formulae" "add to the Brewfile, or: brew uninstall <name>" \
  "$(comm -23 <(brew leaves --installed-on-request | sort) <(declared brew))"

report "casks" "add to the Brewfile, or: brew uninstall --cask <name>" \
  "$(comm -23 <(brew list --cask | sort) <(declared cask))"

# VS Code extensions are the third thing `brew bundle` manages and the easiest
# to accumulate by accident: they install from inside the editor, where nothing
# suggests writing them down.
if command -v code > /dev/null 2>&1; then
  report "vscode extensions" "add to the Brewfile, or uninstall in the editor" \
    "$(comm -23 <(code --list-extensions | tr '[:upper:]' '[:lower:]' | sort) \
      <(declared vscode | tr '[:upper:]' '[:lower:]'))"
else
  printf '  %sDRIFT%s vscode extensions %s(code not on PATH)%s\n' "$RED" "$OFF" "$DIM" "$OFF"
  FAILED=1
fi

printf '\n%sDeclared but not installed%s\n' "$DIM" "$OFF"

missing=$(brew bundle check --file=Brewfile --verbose 2>&1 | sed -n 's/^→ //p')
report "Brewfile is satisfied" "brew bundle install --file=Brewfile" "$missing"

printf '\n%sRuntimes%s\n' "$DIM" "$OFF"

# The README states this as a rule -- "Homebrew installs programs, mise installs
# runtimes" -- and until now nothing enforced it. A runtime from Homebrew is a
# single global version: whichever shell has mise activated gets the right one
# and everything else (scripts, launchd jobs, non-interactive shells) silently
# gets Homebrew's. The symptom appears far from the cause.
RUNTIMES="node deno bun go ruby rust php openjdk"
through_brew=""
for r in $RUNTIMES; do
  brew list --formula --versions "$r" > /dev/null 2>&1 &&
    through_brew+="$r ($(brew list --versions "$r" | awk '{print $2}'))"$'\n'
done
report "no runtime comes from Homebrew" \
  "install it with mise instead: brew uninstall <name> && mise use -g <name>@lts" \
  "${through_brew%$'\n'}"

# Running a version nobody patches anymore is not drift between two files: it is
# drift against a calendar, so no amount of reading this repo can detect it. A
# pin that was correct when it was written becomes wrong on a date, silently,
# and the only signal is that security fixes stop arriving.
#
# This is the one check here that needs the network. It is also why the whole
# file is run by hand: a check that fails because GitHub's DNS blinked has no
# business gating a commit.
#
# endoflife.date rather than nodejs.org's own schedule.json, which is
# first-party and would be the better source if node were the only thing pinned.
# It is not -- and endoflife.date returns the same shape for python, go and
# ruby, so covering another runtime is one line in the map below instead of a
# second parser for a second format.
eol_runtimes() {
  python3 - << 'PY'
import datetime
import json
import subprocess
import sys
import urllib.request

# A runtime missing from this map is reported, not skipped. An unchecked runtime
# reads exactly like a supported one, which is the failure this file exists for.
PRODUCTS = {
    'node': 'nodejs',
    'python': 'python',
    'go': 'go',
    'ruby': 'ruby',
    'rust': 'rust',
    'php': 'php',
    'bun': 'bun',
    'deno': 'deno',
}

problems = []
today = datetime.date.today()

current = json.loads(subprocess.run(
    ['mise', 'ls', '--current', '--json'],
    capture_output=True, text=True, check=True).stdout)

for tool, entries in sorted(current.items()):
    product = PRODUCTS.get(tool)
    if product is None:
        problems.append('%s: no end-of-life source mapped for it' % tool)
        continue
    try:
        url = 'https://endoflife.date/api/%s.json' % product
        with urllib.request.urlopen(url, timeout=20) as response:
            cycles = json.load(response)
    except Exception as err:
        problems.append('%s: could not reach endoflife.date (%s)' % (tool, err))
        continue

    for entry in entries:
        version = entry['version']
        # Longest matching cycle wins, so 3.13 is preferred over a bare 3.
        matches = [c for c in cycles
                   if version == c['cycle'] or version.startswith(c['cycle'] + '.')]
        if not matches:
            problems.append('%s %s: matches no known release cycle' % (tool, version))
            continue
        eol = max(matches, key=lambda c: len(c['cycle']))['eol']
        # Some products report a boolean instead of a date once it has passed.
        if eol is True:
            problems.append('%s %s: past end of life' % (tool, version))
        elif isinstance(eol, str) and datetime.date.fromisoformat(eol) <= today:
            problems.append('%s %s: end of life since %s' % (tool, version, eol))

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
}
report "no runtime is past end of life" \
  "upgrade it: mise use -g <tool>@<newer>" \
  "$(eol_runtimes)"

if [ "$FAILED" -eq 0 ]; then
  printf '\n%sNo drift: installed and declared match%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sDrift found%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
