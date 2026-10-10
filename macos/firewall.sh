#!/usr/bin/env bash
# Keeps the application firewall on and in stealth mode, or reports where it
# differs.
#
# Usage:  macos/firewall.sh apply|check
#
# Same shape as power.sh, for the same reason -- the write needs root, and
# defaults.txt promises nothing in it does. The settings live in
# /Library/Preferences/com.apple.alf.plist, root-owned; `socketfilterfw` is
# the tool that writes them and reads them back without privilege. `check`
# only reads, so drift.sh never prompts; `apply` goes through sudo once per
# setting that differs, so a second run asks for nothing.
#
# What is declared:
#
#   globalstate on. Stealth mode does nothing while the firewall is off.
#   stealthmode on. Meant to make the Mac ignore ICMP and probes to closed
#   ports instead of answering them (Apple's description; the behaviour was
#   not tested here, only that the setting reads back as on). CIS is said to
#   list it as a Level 1 control and to warn it can be unwanted on a trusted
#   LAN -- from memory of that guidance, the CIS PDF was not read.
#
# Not supported: "Block all incoming connections". Its globalstate output
# was not observed, so it reads as unrecognised output (exit 2) rather than
# as on; turn it off, or extend `current` once someone has seen the output.
#
# Not tested: a Mac whose firewall a configuration profile manages -- the
# write would read back as applied and be overruled.
set -euo pipefail

MODE=${1:-}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/firewall.sh apply|check" >&2
    exit 2
    ;;
esac

# SOCKETFILTERFW is overridable so check.sh can point it at a stub.
FW=${SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}

# setting value -- the name is socketfilterfw's flag without its prefix.
SETTINGS='
globalstate  on
stealthmode  on
'

# What socketfilterfw reports for a setting, as on or off. Output this does
# not recognise is a broken checker -- exit 2, which drift.sh reports as
# such -- rather than a difference: apply would write over a state it never
# understood.
current() {
  local out
  out=$("$FW" "--get$1" < /dev/null) || {
    echo "socketfilterfw --get$1 failed" >&2
    exit 2
  }
  case "$1:$out" in
    globalstate:*"State = 1"*) echo on ;;
    globalstate:*"State = 0"*) echo off ;;
    stealthmode:*"stealth mode is on"*) echo on ;;
    stealthmode:*"stealth mode is off"*) echo off ;;
    *)
      echo "cannot read $1 from: $out" >&2
      exit 2
      ;;
  esac
}

DIFFERENCES=0

while read -r setting value; do
  [ -n "$setting" ] || continue
  have=$(current "$setting")
  [ "$have" = "$value" ] && continue
  DIFFERENCES=1
  if [ "$MODE" = check ]; then
    echo "$setting: want $value, have $have"
    continue
  fi
  echo "$setting -> $value"
  sudo "$FW" "--set$setting" "$value" < /dev/null
done <<< "$SETTINGS"

if [ "$MODE" = check ]; then
  exit "$DIFFERENCES"
fi
