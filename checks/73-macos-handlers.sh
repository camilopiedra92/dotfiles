# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── macOS file handlers ──────────────────────────────────────────────────────
# macos/handlers.sh sets the default app per file extension through duti. The
# stub answers `-x ext` from $STATE ("ext bundle_id" lines) in duti's
# three-line shape, failing like the real one for an extension with no
# handler, records every `-s` to $WRITES, and fails a `-s` for any bundle id
# listed in $MISSING -- what the real duti does for an app that is not
# installed (error -50, exit 2, seen here on 2026-10-03).
printf '\n%smacOS file handlers%s\n' "$DIM" "$OFF"

handlers_manifest() {
  local bad f
  [ -f macos/handlers.txt ] || {
    echo "macos/handlers.txt missing"
    return 1
  }
  # Checked per pair, shared plus one machine, which is what a machine reads:
  # an extension in both would be set twice, and the last write would win.
  bad=$(for f in macos/handlers.txt macos/machines/*/handlers.txt; do
    [ -f "$f" ] || continue
    if [ "$f" = macos/handlers.txt ]; then
      set -- macos/handlers.txt
    else
      set -- macos/handlers.txt "$f"
    fi
    awk '
    { sub(/#.*/, "") }
    NF == 0 { next }
    NF != 2 { print FILENAME":"FNR": want two fields, extension and bundle id"; next }
    $1 !~ /^[a-z0-9]+$/ { print FILENAME":"FNR": extension is lowercase, without the dot: "$1; next }
    $2 !~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/ { print FILENAME":"FNR": not a bundle id: "$2; next }
    seen[$1]++ { print FILENAME":"FNR": "$1" is also in an earlier file, or twice in this one" }
  ' "$@"
  done)
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "every handlers manifest is extension and bundle id per line, none in two" handlers_manifest

handlers_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/duti" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  -x)
    b=$(awk -v e="$2" '$1 == e { print $2; exit }' "$STATE")
    [ -n "$b" ] || { echo "Failed to get default application for extension '$2'" >&2; exit 2; }
    printf 'Some App\n/Applications/Some App.app\n%s\n' "$b" ;;
  -s)
    if grep -qx "$2" "$MISSING" 2> /dev/null; then
      echo "failed to set $2 as handler for x (error -50)" >&2
      exit 2
    fi
    echo "$*" >> "$WRITES" ;;
  *) echo "duti stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$dir/bin/duti"
  cat > "$dir/handlers.txt" << 'EOF'
# comment
md    abnerworks.Typora     # trailing comment
sh    com.microsoft.VSCode
EOF
  : > "$dir/writes"
  : > "$dir/missing"
  machine_fixture "$dir"
}

handlers_run() {
  local tmp=$1
  shift
  STATE="$tmp/state" WRITES="$tmp/writes" MISSING="$tmp/missing" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/handlers.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/handlers.sh "$@"
}

handlers_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  handlers_run "$tmp" apply > "$tmp/out" 2>&1 || {
    cat "$tmp/out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "set a handler although everything matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply sets nothing when every handler already matches" handlers_apply_is_a_noop_when_matching

handlers_apply_sets_only_the_difference() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  # md matches; sh opens in a terminal, which runs the script.
  printf 'md abnerworks.Typora\nsh com.mitchellh.ghostty\n' > "$tmp/state"
  handlers_run "$tmp" apply > "$tmp/out" || return 1
  diff <(echo "-s com.microsoft.VSCode .sh all") "$tmp/writes" || return 1
  diff <(echo "sh -> com.microsoft.VSCode") "$tmp/out" || return 1
}
check "apply sets exactly the differing extensions, for every role" handlers_apply_sets_only_the_difference

handlers_check_reports_and_never_writes() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  # sh has a different handler; md has none at all.
  printf 'sh com.mitchellh.ghostty\n' > "$tmp/state"
  if out=$(handlers_run "$tmp" check); then
    echo "check exited 0 with differences present"
    return 1
  fi
  diff - <(printf '%s\n' "$out") << 'EOF' || return 1
md: want abnerworks.Typora, have unset
sh: want com.microsoft.VSCode, have com.mitchellh.ghostty
EOF
  [ ! -s "$tmp/writes" ] || {
    echo "check set a handler"
    return 1
  }
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  out=$(handlers_run "$tmp" check) || {
    echo "check exited non-zero with every handler matching: $out"
    return 1
  }
  [ -z "$out" ] || {
    echo "check printed with every handler matching: $out"
    return 1
  }
}
check "check reports each difference, exits 0 on a match, and never writes" handlers_check_reports_and_never_writes

# Same contract as the Dock: an app that is not installed yet must not stop
# install.sh, and must not be silent either. The other lines still apply.
handlers_apply_survives_an_app_that_is_not_installed() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  echo abnerworks.Typora > "$tmp/missing"
  printf 'md com.apple.TextEdit\nsh com.mitchellh.ghostty\n' > "$tmp/state"
  handlers_run "$tmp" apply > "$tmp/out" 2> "$tmp/err" || {
    echo "apply failed on an app that is not installed"
    cat "$tmp/err"
    return 1
  }
  diff <(echo "-s com.microsoft.VSCode .sh all") "$tmp/writes" || return 1
  diff <(echo "sh -> com.microsoft.VSCode") "$tmp/out" || return 1
  diff <(echo "md: could not set abnerworks.Typora, left as is (duti: failed to set abnerworks.Typora as handler for x (error -50))") "$tmp/err" || return 1
}
check "apply skips a handler whose app is not installed and sets the rest" handlers_apply_survives_an_app_that_is_not_installed

handlers_refuses_a_missing_manifest() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  rc=0
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" MISSING="$tmp/missing" PATH="$tmp/bin:$PATH" \
    MANIFEST="$tmp/nope/handlers.txt" bash macos/handlers.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc on a missing manifest, want 2: $out"
    return 1
  }
  case "$out" in
    *"no manifest at $tmp/nope/handlers.txt"*) ;;
    *)
      echo "did not name the missing manifest: $out"
      return 1
      ;;
  esac
}
check "check refuses a missing manifest instead of reading it as a match" handlers_refuses_a_missing_manifest

handlers_refuses_a_missing_duti() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  rm "$tmp/bin/duti"
  printf 'md abnerworks.Typora\n' > "$tmp/state"
  for verb in check apply; do
    rc=0
    out=$(STATE="$tmp/state" WRITES="$tmp/writes" MISSING="$tmp/missing" PATH="$tmp/bin:/usr/bin:/bin" \
      MANIFEST="$tmp/handlers.txt" MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" \
      /bin/bash macos/handlers.sh "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "$verb exited $rc without duti, want 2: $out"
      return 1
    }
  done
}
check "a missing duti is a broken checker, not every handler unset" handlers_refuses_a_missing_duti

handlers_reads_the_machine_overlay() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'pdf com.adobe.Acrobat.Pro\n' > "$tmp/machines/test/handlers.txt"
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  if out=$(handlers_run "$tmp" check); then
    echo "check exited 0 with the machine's line unmet"
    return 1
  fi
  [ "$out" = "pdf: want com.adobe.Acrobat.Pro, have unset" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "the machine's handlers.txt is read after the shared one" handlers_reads_the_machine_overlay

handlers_refuses_a_missing_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'md com.apple.TextEdit\n' > "$tmp/state"
  rm "$tmp/machine"
  for verb in check apply; do
    rc=0
    out=$(handlers_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or set a handler with no machine profile: $out"
      return 1
    }
  done
}
check "no machine profile is a broken checker, and no handler is set" handlers_refuses_a_missing_profile

handlers_reads_an_unterminated_last_line() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'pdf com.adobe.Acrobat.Pro' > "$tmp/machines/test/handlers.txt"
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  if out=$(handlers_run "$tmp" check); then
    echo "check ignored the machine's last line, the one with no newline"
    return 1
  fi
}
check "the last line counts without a newline after it" handlers_reads_an_unterminated_last_line
