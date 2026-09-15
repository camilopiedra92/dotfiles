#!/usr/bin/env bash
# Applies macos/defaults.txt to this machine, or reports where it differs.
#
# Usage:  macos/defaults.sh [apply|check]
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

cd "$(dirname "${BASH_SOURCE[0]}")"

MODE=${1:-apply}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/defaults.sh [apply|check]" >&2
    exit 2
    ;;
esac
# Overridable so check.sh can point it at a fixture.
MANIFEST=${MANIFEST:-defaults.txt}

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
LOGOUT=0

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
  case "$domain" in NSGlobalDomain | com.apple.AppleMultitouchTrackpad | com.apple.driver.AppleBluetoothMultitouch.trackpad) LOGOUT=1 ;; esac
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

for app in $RESTART; do killall "$app"; done
[ -z "$RESTART" ] || echo "restarted:$RESTART"
[ "$LOGOUT" -eq 0 ] || echo "log out and back in for the keyboard and trackpad changes to take effect"
