#!/usr/bin/env bash
# Applies the power settings this machine is expected to have, or reports
# where it differs. The settings `pmset` owns and `defaults` cannot reach.
#
# Usage:  macos/power.sh apply|check
#
# Same shape as defaults.sh -- one script, two verbs, install.sh applies and
# drift.sh checks -- and a separate script rather than more lines in
# defaults.txt because the tool is different and so is the cost: pmset
# writes need root, and defaults.txt promises nothing in it does. Keeping the
# two apart keeps that promise true by construction. `check` reads through
# `pmset -g custom`, which needs no privilege, so drift.sh stays free of
# password prompts; only `apply` goes through sudo, and only for a setting
# that actually differs, so a second run asks for nothing.
#
# The same rule as defaults.txt applies to what is declared: only values that
# differ from Apple's own, each with a reason. Everything else pmset shows --
# display sleep, standby, hibernate mode, Power Nap, TCP keepalive -- is left
# at what Apple ships, because a default written down is a default frozen.
#
# What is declared:
#
#   Energy Mode on battery = Low Power. powermode 0 is Automatic, 1 Low
#   Power, 2 High Power; System Settings -> Battery -> Energy Mode writes the
#   same key, "LowPowerMode" in /Library/Preferences/com.apple.PowerManagement
#   .<uuid>.plist, per profile. It is the one software lever left with a
#   runtime gain worth a line: it caps CPU and GPU clocks and the display
#   refresh rate. Declared for battery only (-b), so plugged in stays
#   Automatic and a build or a call is not throttled at the desk. The key is
#   not in `man pmset` on macOS 26.6.2; it is what `pmset -g custom` prints
#   and what the plist holds, which is how it was found.
set -euo pipefail

MODE=${1:-}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/power.sh apply|check" >&2
    exit 2
    ;;
esac

# profile setting value -- profile is `battery` or `ac`, the two sections
# `pmset -g custom` prints and the -b / -c flags it takes on write.
SETTINGS='
battery  powermode  1
'

profile_flag() {
  case "$1" in
    battery) echo -b ;;
    ac) echo -c ;;
    *)
      echo "unknown profile $1" >&2
      exit 2
      ;;
  esac
}

profile_header() {
  case "$1" in
    battery) echo "Battery Power:" ;;
    ac) echo "AC Power:" ;;
  esac
}

# The current value of a setting under a profile, as `pmset -g custom` shows
# it: sections start with a header ending in a colon, settings are indented
# "name value" lines beneath. Read once, before the loop, so every setting
# compares against the same snapshot.
CUSTOM=$(pmset -g custom)

DIFFERENCES=0

while read -r profile setting value; do
  [ -n "$profile" ] || continue
  header=$(profile_header "$profile")
  # A missing profile is not "unset": on a machine with no battery, or from
  # a pmset that printed nothing, apply would write to a profile that does
  # not exist and check would report every setting as drift. Neither is the
  # truth, so it is a broken checker -- exit 2, which drift.sh reports as
  # such rather than as a match or a difference.
  case "$CUSTOM" in
    *"$header"*) ;;
    *)
      echo "pmset -g custom has no '$header' section" >&2
      exit 2
      ;;
  esac
  have=$(printf '%s\n' "$CUSTOM" | awk -v h="$header" -v s="$setting" '
    /:$/ { in_section = ($0 == h); next }
    in_section && $1 == s { print $2; exit }
  ')
  [ -n "$have" ] || have="unset"
  [ "$have" = "$value" ] && continue
  DIFFERENCES=1
  if [ "$MODE" = check ]; then
    echo "$profile $setting: want $value, have $have"
    continue
  fi
  echo "$profile $setting -> $value"
  sudo pmset "$(profile_flag "$profile")" "$setting" "$value"
done <<< "$SETTINGS"

if [ "$MODE" = check ]; then
  exit "$DIFFERENCES"
fi
