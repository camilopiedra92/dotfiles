#!/usr/bin/env bash
# Applies macos/handlers.txt -- the default app per file extension -- or
# reports where this machine differs.
#
# Usage:  macos/handlers.sh apply|check
#
# Same shape as defaults.sh: one script, two verbs, install.sh applies and
# drift.sh checks. A script of its own because Launch Services, not a
# `defaults` domain, owns these: the choices live in
# com.apple.launchservices.secure as an array of dictionaries keyed by UTI,
# which a `defaults.txt` line cannot hold. duti sets them through the Launch
# Services API rather than by editing that plist.
#
# A line names an extension rather than a UTI because the extension is what
# a person knows and what `duti -x` reads back; duti resolves it to the UTI
# Launch Services uses. Every line sets the role `all`, which includes
# `shell`: for a script, that is what makes a double-click open it instead of
# running it.
#
# Launch Services takes the change asynchronously. On 2026-10-03 a `check`
# run straight after `apply` still read the old handlers for `js` and `sh`;
# three seconds later `duti -x` read the new ones and `check` exited 0. On
# 2026-10-05 it took longer: the plist already held the new handlers (written
# 14:54:53-14:55:01), a drift.sh run after that still read Claude.app for
# `json`, `yaml` and `yml`, and `check` exited 0 at 14:56:50. The delay has
# no bound to wait for, so `apply` does not read back what it set --
# drift.sh's `check` is the verification, and runs long after.
#
# `check` compares the app `duti -x` reports as the default, which is the
# one Finder opens on a double-click; it does not read each role apart.
#
# Same rule as defaults.txt: only what differs from Apple's own choice. And
# the same contract as dock.sh for an app that is not installed: `apply`
# says so on stderr and moves on, `check` keeps reporting the line.
#
# The web browser and mail handlers (http, https, mailto) are not here.
# Apple documents that changing the default browser asks the user to
# confirm, so `apply` could not set it unattended -- not tested here -- and
# the browser offers to make itself the default on first launch anyway.
set -euo pipefail

if [ -n "${MANIFEST:-}" ]; then
  dir=$(cd "$(dirname "$MANIFEST")" 2> /dev/null && pwd) || {
    echo "no manifest at $MANIFEST" >&2
    exit 2
  }
  MANIFEST="$dir/$(basename "$MANIFEST")"
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

MODE=${1:-}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/handlers.sh apply|check" >&2
    exit 2
    ;;
esac
MANIFEST=${MANIFEST:-handlers.txt}

[ -r "$MANIFEST" ] || {
  echo "no manifest at $MANIFEST" >&2
  exit 2
}

# This Mac's own lines, read after the shared ones, from its profile under
# machines/. No profile is a broken checker: machine.sh says why on stderr
# and exits 2, and so does this, before anything is read or written.
MACHINE_DIR=$(./machine.sh dir) || exit 2
OVERLAY="$MACHINE_DIR/handlers.txt"
[ -f "$OVERLAY" ] || OVERLAY=/dev/null

# Without duti every line would read as unset and every write as failed:
# a broken checker, not a machine with no handlers.
command -v duti > /dev/null || {
  echo "duti is not installed; it is in the Brewfile" >&2
  exit 2
}

DIFFERENCES=0

# awk rather than sed into `while read`: read drops a last line with no
# newline after it -- most likely the overlay's, which comes last -- and awk
# always ends what it prints with one.
while read -r ext bundle; do
  [ -n "$ext" ] || continue
  # `duti -x` prints the app's name, path and bundle id, one per line, and
  # fails for an extension nothing claims.
  have=$(duti -x "$ext" 2> /dev/null | sed -n 3p) || have=""
  [ -n "$have" ] || have="unset"
  [ "$have" = "$bundle" ] && continue
  DIFFERENCES=1
  if [ "$MODE" = check ]; then
    echo "$ext: want $bundle, have $have"
    continue
  fi
  # duti's own message is kept: an app that is not installed is the usual
  # cause, but not the only one.
  if err=$(duti -s "$bundle" ".$ext" all 2>&1); then
    echo "$ext -> $bundle"
  else
    echo "$ext: could not set $bundle, left as is (duti: $err)" >&2
  fi
done < <(awk '{ sub(/#.*/, ""); print }' "$MANIFEST" "$OVERLAY")

if [ "$MODE" = check ]; then
  exit "$DIFFERENCES"
fi
