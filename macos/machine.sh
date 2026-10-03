#!/usr/bin/env bash
# Says which machine profile this Mac is, or records it.
#
# Usage:  macos/machine.sh dir         prints macos/machines/<profile>
#         macos/machine.sh set <name>  records <name> as this Mac's profile
#
# One repo serves more than one Mac, and what differs between them -- the
# Dock's apps, an app one of them does not have -- lives under
# macos/machines/<profile>/. Which profile a Mac is comes from a one-word file
# outside the repo, ~/.config/dotfiles/machine, that install.sh asks for once.
#
# Rejected: the hostname, which two Macs can share and a rename changes
# without anything saying so; and the hardware serial, which would put an
# identifier in a public repo and need an edit the day the Mac is replaced.
#
# dir exits 2 -- the broken-checker code every script here uses -- when the
# file is missing or names a profile with no directory, because the
# alternative to stopping is guessing, and a wrong guess applies one Mac's
# Dock to the other.
set -euo pipefail

MACHINES=${MACHINES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/machines}
MACHINE_FILE=${MACHINE_FILE:-$HOME/.config/dotfiles/machine}

profiles() {
  local d out=""
  for d in "$MACHINES"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    out="${out:+$out }${d##*/}"
  done
  printf '%s\n' "$out"
}

# A profile is a plain name with a directory of its own: lowercase letters,
# digits and dashes, which keeps a value like ../x from resolving outside
# machines/. Spelled out rather than [a-z]: in bash 3.2 a bracket range
# follows the locale's collation, and under en_US.UTF-8 it matches uppercase
# too -- which APFS, being case-insensitive, would then quietly resolve.
known() {
  case "$1" in
    "" | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
  esac
  [ -d "$MACHINES/$1" ]
}

case "${1:-}" in
  dir)
    [ -s "$MACHINE_FILE" ] || {
      echo "no machine profile in $MACHINE_FILE: write one of: $(profiles) (install.sh asks)" >&2
      exit 2
    }
    # The first line, without the whitespace around it; whitespace inside is
    # kept, and known() refuses it, rather than joining two words into one.
    name=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$MACHINE_FILE")
    known "$name" || {
      echo "unknown machine '$name' in $MACHINE_FILE: profiles are $(profiles)" >&2
      exit 2
    }
    printf '%s\n' "$MACHINES/$name"
    ;;
  set)
    known "${2:-}" || {
      echo "unknown machine '${2:-}': profiles are $(profiles)" >&2
      exit 2
    }
    mkdir -p "$(dirname "$MACHINE_FILE")"
    printf '%s\n' "$2" > "$MACHINE_FILE"
    ;;
  *)
    echo "usage: macos/machine.sh dir | set <name>" >&2
    exit 2
    ;;
esac
