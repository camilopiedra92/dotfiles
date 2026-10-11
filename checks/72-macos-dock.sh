# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── macOS Dock ───────────────────────────────────────────────────────────────
# macos/dock.sh rebuilds the Dock's app section from the machine's dock.txt through
# dockutil. The stub answers `--list` from $STATE in dockutil's own shape --
# label, percent-encoded file URL, section, plist, tab-separated -- and
# records every --add and --remove to $WRITES. The state always carries a
# Downloads stack under persistentOthers, which the script must neither count
# nor remove, and an app whose name has a space, so the URL has to be decoded
# rather than compared raw.
printf '\n%smacOS Dock%s\n' "$DIM" "$OFF"

dock_manifest() {
  local bad f
  ls macos/machines/*/dock.txt > /dev/null 2>&1 || {
    echo "no macos/machines/*/dock.txt at all"
    return 1
  }
  bad=$(for f in macos/machines/*/dock.txt; do
    sed 's/#.*//; s/[[:space:]]*$//' "$f" | awk -v f="$f" '
    NF == 0 { next }
    $0 !~ /^\/.*\.app$/ { print f":"NR": not an absolute path to an .app: "$0; next }
    seen[$0]++ { print f":"NR": listed twice: "$0 }
  '
  done)
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "every machine's dock.txt is one absolute .app path per line, none twice" dock_manifest

dock_stub() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/Applications/Google Chrome.app" "$dir/Applications/Ghostty.app" "$dir/Applications/Notes.app"
  cat > "$dir/bin/dockutil" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  --list)
    [ -z "${LIST_FAILS:-}" ] || { echo "dockutil stub: list failed" >&2; exit 1; }
    cat "$STATE" ;;
  --add | --remove) echo "$*" >> "$WRITES" ;;
  *) echo "dockutil stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  cat > "$dir/bin/killall" << 'STUB'
#!/usr/bin/env bash
echo "$1" >> "$KILLED"
STUB
  chmod +x "$dir/bin/dockutil" "$dir/bin/killall"
  machine_fixture "$dir"
  printf '%s/Applications/Google Chrome.app\n%s/Applications/Ghostty.app\n' "$dir" "$dir" > "$dir/machines/test/dock.txt"
  : > "$dir/writes"
  : > "$dir/killed"
}

# One line of `dockutil --list` for each app path given, in that order,
# followed by the Downloads stack.
dock_state() {
  local out=$1 app enc
  shift
  : > "$out"
  for app in "$@"; do
    enc=${app// /%20}
    printf '%s\tfile://%s/\tpersistentApps\t/Users/x/Library/Preferences/com.apple.dock.plist\n' \
      "$(basename "$app" .app)" "$enc" >> "$out"
  done
  printf 'Downloads\tfile:///Users/x/Downloads/\tpersistentOthers\t/Users/x/Library/Preferences/com.apple.dock.plist\n' >> "$out"
}

dock_run() {
  local tmp=$1
  shift
  STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh "$@"
}

dock_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  dock_run "$tmp" apply > "$tmp/out" 2>&1 || {
    cat "$tmp/out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "changed the Dock although it matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/killed" ] || {
    echo "restarted the Dock although nothing changed"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply leaves the Dock alone when it already matches" dock_apply_is_a_noop_when_matching

dock_apply_rebuilds_the_app_section() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  # Wrong order, plus an app the manifest does not declare.
  dock_state "$tmp/state" "$tmp/Applications/Ghostty.app" "$tmp/Applications/Notes.app" "$tmp/Applications/Google Chrome.app"
  dock_run "$tmp" apply > "$tmp/out" || return 1
  diff - "$tmp/writes" << EOF || return 1
--remove Ghostty --no-restart
--remove Notes --no-restart
--remove Google Chrome --no-restart
--add $tmp/Applications/Google Chrome.app --section apps --no-restart
--add $tmp/Applications/Ghostty.app --section apps --no-restart
EOF
  diff <(echo Dock) "$tmp/killed" || return 1
  diff <(echo "Dock -> Google Chrome, Ghostty") "$tmp/out" || return 1
}
check "apply rebuilds only the app section, in order, and restarts the Dock once" dock_apply_rebuilds_the_app_section

dock_check_reports_and_never_writes() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Ghostty.app" "$tmp/Applications/Google Chrome.app"
  if out=$(dock_run "$tmp" check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  diff - <(printf '%s\n' "$out") << 'EOF' || return 1
Dock: want Google Chrome, Ghostty
Dock: have Ghostty, Google Chrome
EOF
  [ ! -s "$tmp/writes" ] && [ ! -s "$tmp/killed" ] || {
    echo "check changed the Dock"
    return 1
  }
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  out=$(dock_run "$tmp" check) || {
    echo "check exited non-zero with the Dock matching: $out"
    return 1
  }
  [ -z "$out" ] || {
    echo "check printed with the Dock matching: $out"
    return 1
  }
}
check "check reports the difference, exits 0 on a match, and never writes" dock_check_reports_and_never_writes

# A declared app that is not installed -- the normal state of a fresh machine
# before the App Store has run -- must not stop install.sh, and must not
# vanish either: apply builds the Dock from what is there and says what it
# skipped, check keeps reporting it until it is installed or undeclared.
dock_handles_an_app_that_is_not_installed() {
  local tmp out rc
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  printf '%s/Applications/Missing.app\n' "$tmp" >> "$tmp/machines/test/dock.txt"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  dock_run "$tmp" apply > "$tmp/out" 2> "$tmp/err" || {
    echo "apply failed on a missing app"
    cat "$tmp/err"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "rebuilt the Dock although every installed app was already in place:"
    cat "$tmp/writes"
    return 1
  }
  diff <(echo "not installed, left out of the Dock: $tmp/Applications/Missing.app") "$tmp/err" || return 1
  rc=0
  out=$(dock_run "$tmp" check) || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "check exited $rc with a declared app missing, want 1"
    return 1
  }
  [ "$out" = "not installed: $tmp/Applications/Missing.app" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "a declared app that is not installed is skipped by apply and reported by check" dock_handles_an_app_that_is_not_installed

dock_refuses_a_missing_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state"
  rm "$tmp/machine"
  for verb in check apply; do
    rc=0
    out=$(dock_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or changed the Dock with no machine profile: $out"
      return 1
    }
  done
  case "$out" in
    *"no machine profile"*) ;;
    *)
      echo "did not say the profile is missing: $out"
      return 1
      ;;
  esac
}
check "no machine profile is a broken checker, and the Dock is left alone" dock_refuses_a_missing_profile

# `while read` drops a last line with no newline after it, and an editor that
# does not add one is common. The validator reads with awk, which keeps it,
# so the two would disagree in silence.
dock_reads_an_unterminated_last_line() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  printf '%s/Applications/Google Chrome.app\n%s/Applications/Ghostty.app' "$tmp" "$tmp" > "$tmp/machines/test/dock.txt"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app"
  if out=$(dock_run "$tmp" check); then
    echo "check ignored the last line, the one with no newline"
    return 1
  fi
}
check "the last line counts without a newline after it" dock_reads_an_unterminated_last_line

# dockutil missing, or failing to list, is a broken checker -- exit 2, which
# drift.sh reports as such -- and not an empty Dock that `apply` would then
# "fix". PATH is cut to the system directories so the real dockutil in
# Homebrew's cannot answer instead.
dock_refuses_a_missing_or_failing_dockutil() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  rm "$tmp/bin/dockutil"
  for verb in check apply; do
    rc=0
    out=$(STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:/usr/bin:/bin" \
      MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" /bin/bash macos/dock.sh "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "$verb exited $rc without dockutil, want 2: $out"
      return 1
    }
  done
  dock_stub "$tmp"
  rc=0
  out=$(LIST_FAILS=1 dock_run "$tmp" check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "check exited $rc when dockutil --list failed, want 2: $out"
    return 1
  }
  rc=0
  out=$(LIST_FAILS=1 dock_run "$tmp" apply 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] && [ ! -s "$tmp/killed" ] || {
    echo "apply exited $rc or changed the Dock when dockutil --list failed: $out"
    return 1
  }
}
check "a missing or failing dockutil is a broken checker, not an empty Dock" dock_refuses_a_missing_or_failing_dockutil

# Shapes the plain case does not cover. Observed with dockutil 3.1.3 on
# 2026-10-03: Safari, whose /Applications path is a symlink into the system
# cryptex, listed as that cryptex path, bare, with no file:// and no slash;
# and five fields, the bundle id last. Not observed, guarded against: an
# accented name stored decomposed (NFD) while the manifest is typed composed
# (NFC) -- macOS file APIs commonly hand back NFD, and the two would never
# compare equal as strings.
dock_matches_symlinked_and_accented_apps() {
  local tmp nfc
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  # "Cafe" with an acute e, written as bytes: composed (C3 A9) in the
  # manifest, decomposed (65 CC 81) and percent-encoded in the Dock's URL.
  nfc=$(printf 'Caf\xc3\xa9')
  mkdir -p "$tmp/Cryptex/Safari.app" "$tmp/Applications/$nfc.app"
  ln -s "$tmp/Cryptex/Safari.app" "$tmp/Applications/Safari.app"
  printf '%s/Applications/Safari.app\n%s/Applications/%s.app\n' "$tmp" "$tmp" "$nfc" > "$tmp/machines/test/dock.txt"
  {
    printf 'Safari\t%s/Cryptex/Safari.app\tpersistentApps\t/p.plist\tcom.apple.Safari\n' "$(cd -P "$tmp" && pwd)"
    printf '%s\tfile://%s/Applications/Cafe%%CC%%81.app/\tpersistentApps\t/p.plist\tcom.example.cafe\n' "$nfc" "${tmp// /%20}"
  } > "$tmp/state"
  dock_run "$tmp" check > "$tmp/out" 2>&1 || {
    echo "check reported a difference for the same two apps:"
    cat "$tmp/out"
    return 1
  }
  dock_run "$tmp" apply > "$tmp/out" 2>&1 || return 1
  [ ! -s "$tmp/writes" ] && [ ! -s "$tmp/out" ] || {
    echo "apply rebuilt a Dock that already matched:"
    cat "$tmp/writes" "$tmp/out"
    return 1
  }
}
check "a symlinked app and a decomposed accent match their manifest lines" dock_matches_symlinked_and_accented_apps

# A spacer in the app section has an empty label and an empty URL. The
# manifest cannot declare one, so it is drift: check names it, apply removes
# it. Two empty fields in a row are the trap -- split on IFS, tabs collapse
# and the section lands in the wrong field.
dock_reports_and_removes_a_spacer() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  printf '\t\tpersistentApps\t/p.plist\t\n' >> "$tmp/state"
  if out=$(dock_run "$tmp" check); then
    echo "check exited 0 with a spacer in the app section"
    return 1
  fi
  diff - <(printf '%s\n' "$out") << 'EOF' || return 1
Dock: want Google Chrome, Ghostty
Dock: have Google Chrome, Ghostty, spacer
EOF
  dock_run "$tmp" apply > /dev/null || return 1
  grep -qx -- '--remove spacer-tiles --no-restart' "$tmp/writes" || {
    echo "apply did not remove the spacer:"
    cat "$tmp/writes"
    return 1
  }
}
check "a spacer in the app section is reported by check and removed by apply" dock_reports_and_removes_a_spacer

# A Mac with a profile but no dock.txt in it has a Dock nobody declared: not
# a broken checker, but not a match either. check says so until one is
# written; apply leaves the Dock alone.
machine_without_a_dock_manifest_is_reported() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  rm "$tmp/machines/test/dock.txt"
  dock_state "$tmp/state" "$tmp/Applications/Ghostty.app"
  rc=0
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:$PATH" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh check) || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "check exited $rc with no dock.txt for this machine, want 1: $out"
    return 1
  }
  [ "$out" = "no dock.txt for machine test: the Dock is not declared" ] || {
    echo "unexpected report: $out"
    return 1
  }
  STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:$PATH" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh apply 2> /dev/null || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "apply changed a Dock no manifest declares"
    return 1
  }
  printf '%s/Applications/Ghostty.app\n' "$tmp" > "$tmp/machines/test/dock.txt"
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:$PATH" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh check) || {
    echo "check did not read the machine's dock.txt: $out"
    return 1
  }
}
check "the Dock is read from the machine's dock.txt, and its absence is reported" machine_without_a_dock_manifest_is_reported
