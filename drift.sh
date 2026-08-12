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

if [ "$FAILED" -eq 0 ]; then
  printf '\n%sNo drift: installed and declared match%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sDrift found%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
