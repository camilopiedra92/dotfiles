#!/usr/bin/env bash
# Applies this Mac's macos/machines/<profile>/dock.txt to the Dock's app
# section, or reports where it differs.
#
# Usage:  macos/dock.sh apply|check
#
# Same shape as defaults.sh -- one script, two verbs, install.sh applies and
# drift.sh checks -- and a script of its own because the Dock's app list is
# one ordered value, not a set of keys: `persistent-apps` in com.apple.dock is
# an array of dictionaries carrying per-machine data (file references, GUIDs),
# which a `defaults.txt` line cannot hold and a saved copy of the plist would
# carry from machine to machine. The manifest is the part a person decides --
# which apps, in which order -- and dockutil writes the rest.
#
# Only the app section is managed. Folders and stacks (persistentOthers, the
# right of the divider) are left alone and are not compared, so a Downloads
# stack added by hand is neither removed nor reported. The one exception is
# spacer tiles, below.
#
# A declared app that is not installed is skipped by `apply`, with a line on
# stderr, and reported by `check`. That is the normal state of a fresh
# machine for any app the Brewfile does not install, so failing would stop
# install.sh halfway every time; silence would let the Dock drift from the
# manifest without anything saying so.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MODE=${1:-}
case "$MODE" in
  apply | check) ;;
  *)
    echo "usage: macos/dock.sh apply|check" >&2
    exit 2
    ;;
esac
# The Dock is all per machine, so unlike defaults.sh and handlers.sh there is
# no shared manifest and no MANIFEST override: the only file is dock.txt in
# this Mac's profile, and a fixture is a profile (MACHINES, MACHINE_FILE).
# No profile is a broken checker -- machine.sh says why, exit 2. A profile
# with no dock.txt is a Dock nobody has declared yet: not broken, and not a
# match either, so check says so and apply leaves the Dock alone.
MACHINE_DIR=$(./machine.sh dir) || exit 2
MANIFEST="$MACHINE_DIR/dock.txt"
[ -f "$MANIFEST" ] || {
  if [ "$MODE" = check ]; then
    echo "no dock.txt for machine ${MACHINE_DIR##*/}: the Dock is not declared"
    exit 1
  fi
  echo "no dock.txt for machine ${MACHINE_DIR##*/}: leaving the Dock as it is" >&2
  exit 0
}

# Missing or failing, dockutil is a broken checker (exit 2), not an empty
# Dock: an empty list would read as drift, and `apply` would "fix" it.
command -v dockutil > /dev/null || {
  echo "dockutil is not installed; it is in the Brewfile" >&2
  exit 2
}
LIST=$(dockutil --list) || {
  echo "dockutil --list failed" >&2
  exit 2
}

# One form for a path on both sides of the comparison: symlinks resolved and
# Unicode composed. Safari's /Applications path is a symlink into the system
# cryptex, which is the path the Dock stores (observed 2026-10-03). And an
# accented name may come back decomposed (NFD) where a manifest is typed
# composed (NFC) -- not observed in this Dock, which has no accented app, but
# a string comparison would fail on it silently. `iconv -f UTF-8-MAC` is
# macOS's own NFD-to-NFC conversion.
canonical() {
  local path=$1
  [ ! -d "$path" ] || path=$(cd -P "$path" && pwd)
  printf '%s\n' "$path" | iconv -f UTF-8-MAC -t UTF-8
}

# The app section now, in order, one canonical path per line, and `spacer`
# for a spacer tile. dockutil prints label, URL, section, plist and bundle
# id, tab-separated. The URL is usually file://, percent-encoded, with a
# trailing slash, but a bare path for an app in the cryptex; a spacer has an
# empty label and URL. Split by awk rather than `IFS=$'\t' read`: tab is IFS
# whitespace, so two empty fields in a row would collapse and shift the
# section into the wrong field.
current_paths() {
  local url
  while IFS= read -r url; do
    if [ -z "$url" ]; then
      echo spacer
      continue
    fi
    url=${url#file://}
    url=${url%/}
    canonical "$(printf '%b' "${url//%/\\x}")"
  done < <(awk -F'\t' '$3 == "persistentApps" { print $2 }' <<< "$LIST")
}

# The labels of the apps in the same section, which is what `dockutil
# --remove` takes. Spacers have none and are removed separately.
current_labels() {
  awk -F'\t' '$3 == "persistentApps" && $1 != "" { print $1 }' <<< "$LIST"
}

names() {
  local path out=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    out="${out:+$out, }$(basename "$path" .app)"
  done
  printf '%s\n' "$out"
}

DECLARED=()
MISSING=()
# awk rather than sed into `while read`: read drops a last line with no
# newline after it, and awk always ends what it prints with one.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ -d "$path" ]; then
    DECLARED+=("$path")
  else
    MISSING+=("$path")
  fi
done < <(awk '{ sub(/#.*/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }' "$MANIFEST")

# bash 3.2, which macOS ships, treats "${arr[@]}" on an empty array as unbound
# under `set -u`; the ${arr[@]+...} form expands to nothing instead.
want=""
for path in ${DECLARED[@]+"${DECLARED[@]}"}; do
  want="${want:+$want
}$(canonical "$path")"
done
have=$(current_paths)

DIFFERENCES=0

if [ "$MODE" = check ]; then
  for path in ${MISSING[@]+"${MISSING[@]}"}; do
    echo "not installed: $path"
    DIFFERENCES=1
  done
  if [ "$want" != "$have" ]; then
    echo "Dock: want $(names <<< "$want")"
    echo "Dock: have $(names <<< "$have")"
    DIFFERENCES=1
  fi
  exit "$DIFFERENCES"
fi

for path in ${MISSING[@]+"${MISSING[@]}"}; do
  echo "not installed, left out of the Dock: $path" >&2
done

[ "$want" != "$have" ] || exit 0

# Rebuilt rather than patched: moving items one at a time to reach an order
# is a sorting problem for no benefit, and removing every app and adding the
# declared ones back gives the declared order by construction. --no-restart
# on every call, then one restart, so the Dock redraws once.
while IFS= read -r label; do
  [ -n "$label" ] || continue
  dockutil --remove "$label" --no-restart > /dev/null
done < <(current_labels)
# A manifest cannot declare a spacer, so one in the app section is drift.
# dockutil can only remove spacers all at once, so this also removes any in
# the folder section -- the one place this script reaches past the apps.
if grep -qx spacer <<< "$have"; then
  dockutil --remove spacer-tiles --no-restart > /dev/null
fi
for path in ${DECLARED[@]+"${DECLARED[@]}"}; do
  dockutil --add "$path" --section apps --no-restart > /dev/null
done
echo "Dock -> $(names <<< "$want")"
killall Dock || true
