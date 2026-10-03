#!/usr/bin/env bash
# Turns on Touch ID for sudo, or reports that it is off.
#
# Usage:  macos/touchid.sh apply|check
#
# Apple's supported place for it is /etc/pam.d/sudo_local, which
# /etc/pam.d/sudo includes first and a system update leaves alone; Apple
# ships /etc/pam.d/sudo_local.template with the one line commented out.
# Editing /etc/pam.d/sudo itself was the other way and lost: an update
# rewrites that file and the change disappears without a word.
#
# Same shape as power.sh, for the same reason -- the write needs root.
# `check` only reads, so drift.sh never prompts; `apply` goes through sudo
# once, and only when the line is missing, so a second run asks for nothing.
# A sudo_local that already exists is kept, with the line added to it; one
# that does not is Apple's template with the line uncommented.
#
# Not covered: sudo inside tmux. pam_reattach's documentation says Touch ID
# needs the process attached to the GUI session, which a tmux server is
# not, so sudo there falls back to the password -- not tested here.
# pam_reattach is the module that fixes it, and is not installed.
set -euo pipefail

MODE=${1:-}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/touchid.sh apply|check" >&2
    exit 2
    ;;
esac

# PAM_DIR is overridable so check.sh can point it at a fixture.
PAM_DIR=${PAM_DIR:-/etc/pam.d}
LOCAL="$PAM_DIR/sudo_local"
TEMPLATE="$PAM_DIR/sudo_local.template"
LINE="auth       sufficient     pam_tid.so"

# What sudo_local holds now, or would start from: the file itself, else
# Apple's template. Neither is a broken checker -- exit 2 -- rather than a
# file to make up: without the template there is nothing saying this macOS
# still reads sudo_local at all.
if [ -f "$LOCAL" ]; then
  base=$(cat "$LOCAL")
elif [ -f "$TEMPLATE" ]; then
  base=""
else
  echo "neither $LOCAL nor $TEMPLATE exists" >&2
  exit 2
fi

enabled() {
  grep -Eq '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so' <<< "$1"
}

enabled "$base" && exit 0

if [ "$MODE" = check ]; then
  echo "Touch ID for sudo is off: no pam_tid.so line in $LOCAL"
  exit 1
fi

[ -f "$LOCAL" ] || base=$(cat "$TEMPLATE")
new=$(sed -E 's/^#[[:space:]]*(auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so)/\1/' <<< "$base")
enabled "$new" || new="$new"$'\n'"$LINE"
printf '%s\n' "$new" | sudo tee "$LOCAL" > /dev/null
echo "Touch ID for sudo -> on"
