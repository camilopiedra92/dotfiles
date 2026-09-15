#!/usr/bin/env bash
# Applies macos/defaults.txt to this machine, or reports where it differs.
#
# Usage:  macos/defaults.sh apply|check
#
# One file reads the manifest for both verbs on purpose: install.sh applies
# it and drift.sh checks it, and if each had its own parser the two would
# disagree about what a line means the first time one of them was edited.
# The manifest is data and this is the only code that knows its shape.
#
# The obvious alternative is the shape every "macos.sh" on the internet has --
# a script of bare `defaults write` lines -- and it was rejected because it
# cannot be verified: nothing can read it back without parsing shell. The
# other one, `defaults import` of a plist per domain, was rejected because it
# replaces the whole domain, taking with it every key the app wrote for
# itself.
#
# Nothing here needs sudo, and nothing touches a domain Jamf manages on this
# machine. cfprefsd is never killed: `defaults` already goes through it, and
# killing it is the folk remedy that produces the stale-preferences bug it is
# supposed to cure.
set -euo pipefail

# MANIFEST is overridable so check.sh can point it at a fixture, and resolved
# here, before the `cd` below, so a relative override means what it looks
# like it means -- relative to the caller -- rather than to macos/. The `cd`
# is its own command substitution, assigned to `dir` alone, so its failure
# -- a directory that does not exist -- is the exit status bash checks under
# `set -e`, and is caught here rather than left to accidentally also fail
# the readability check further down against whatever garbage path a
# concatenated substitution would have produced.
if [ -n "${MANIFEST:-}" ]; then
  dir=$(cd "$(dirname "$MANIFEST")" 2> /dev/null && pwd) || {
    echo "no manifest at $MANIFEST" >&2
    exit 2
  }
  MANIFEST="$dir/$(basename "$MANIFEST")"
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

# No default verb: install.sh always means apply and drift.sh always means
# check, so a bare invocation is a mistake worth an error, not a guess.
MODE=${1:-}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/defaults.sh apply|check" >&2
    exit 2
    ;;
esac
MANIFEST=${MANIFEST:-defaults.txt}

# A manifest that cannot be read -- missing, a bad override, a typo'd rename
# -- must not read as "the machine matches". drift.sh treats any exit other
# than `check`'s own 0 (matches) or 1 (differences) as a broken checker, and
# surfaces it as drift rather than as a clean run.
[ -r "$MANIFEST" ] || {
  echo "no manifest at $MANIFEST" >&2
  exit 2
}

# What `defaults read` prints for a declared value, so the two can be
# compared as strings. Bools read back as 1/0; floats read back as bare
# numbers, so 0.0 and 0 are the same value; a leading ~ in a path is ours,
# `defaults` would store it literally.
canonical() {
  local type=$1 value=$2
  case "$type" in
    bool)
      if [ "$value" = true ]; then echo 1; else echo 0; fi
      ;;
    float) awk -v v="$value" 'BEGIN { printf "%g\n", v }' ;;
    string) printf '%s\n' "${value/#\~\//$HOME/}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# Which running app owns a domain and has to be restarted to read it again.
# Everything else picks the new value up on its next launch, or at the next
# login for the ones the window server reads (keyboard, trackpad).
owner() {
  case "$1" in
    com.apple.finder | com.apple.desktopservices) echo Finder ;;
    com.apple.dock) echo Dock ;;
  esac
}

DIFFERENCES=0
RESTART=""

while read -r domain key type value; do
  [ -n "$domain" ] || continue
  want=$(canonical "$type" "$value")
  have=$(defaults read "$domain" "$key" 2> /dev/null) || have="unset"
  # Floats come back from `defaults read` in whatever form they were written,
  # so both sides go through the same formatting before comparing.
  [ "$type" = float ] && [ "$have" != unset ] && have=$(canonical float "$have")
  [ "$have" = "$want" ] && continue
  DIFFERENCES=1
  if [ "$MODE" = check ]; then
    echo "$domain $key: want $value, have $have"
    continue
  fi
  echo "$domain $key -> $value"
  case "$type" in
    string) defaults write "$domain" "$key" -string "$(canonical string "$value")" ;;
    *) defaults write "$domain" "$key" "-$type" "$value" ;;
  esac
  app=$(owner "$domain")
  [ -z "$app" ] || case " $RESTART " in *" $app "*) ;; *) RESTART="$RESTART $app" ;; esac
done < <(sed 's/#.*//' "$MANIFEST")

if [ "$MODE" = check ]; then
  exit "$DIFFERENCES"
fi

# The screenshot directory has to exist or screencapture falls back to the
# Desktop without saying so. Created every run: mkdir -p is the no-op.
mkdir -p "$HOME/Screenshots"

# ~/Library is hidden by a flag, not a preference, so it has no line in the
# manifest. Developers live in it; the flag is cleared here and only here.
# Skipped under check.sh, whose HOME is a temporary directory with no Library.
[ -d "$HOME/Library" ] && chflags nohidden "$HOME/Library"

# An app being restarted is an optimisation, not a promise: over SSH, or with
# Finder quit, it is simply not running, and that must not abort the writes
# already made.
for app in $RESTART; do killall "$app" || true; done
[ -z "$RESTART" ] || echo "restarted:$RESTART"
[ "$DIFFERENCES" -eq 0 ] || echo "other apps read the new values when they next launch; keyboard and trackpad changes need a log out and back in"
