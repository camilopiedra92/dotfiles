# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Application firewall ─────────────────────────────────────────────────────
# macos/firewall.sh keeps the firewall on and in stealth mode. Same contract
# as power.sh and touchid.sh: check never reaches sudo, apply reaches it once
# per differing setting. SOCKETFILTERFW points both at a stub that prints
# what socketfilterfw prints (strings as macOS 27.0 prints them, read
# 2026-10-10) and keeps its state in two files, so a set really changes what
# the next get reads.
printf '\n%sApplication firewall%s\n' "$DIM" "$OFF"

firewall_stub() {
  local dir=$1 global=$2 stealth=$3
  mkdir -p "$dir/bin"
  printf '%s\n' "$global" > "$dir/global"
  printf '%s\n' "$stealth" > "$dir/stealth"
  : > "$dir/writes"
  cat > "$dir/bin/sudo" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WRITES"
exec "$@"
STUB
  cat > "$dir/bin/socketfilterfw" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  --getglobalstate)
    if [ "$(cat "$STATE/global")" = on ]; then
      echo "Firewall is enabled. (State = 1)"
    else
      echo "Firewall is disabled. (State = 0)"
    fi
    ;;
  --getstealthmode) echo "Firewall stealth mode is $(cat "$STATE/stealth")" ;;
  --setglobalstate) echo "$2" > "$STATE/global" ;;
  --setstealthmode) echo "$2" > "$STATE/stealth" ;;
  *) exit 64 ;;
esac
STUB
  chmod +x "$dir/bin/sudo" "$dir/bin/socketfilterfw"
}

firewall_run() {
  local tmp=$1
  shift
  STATE="$tmp" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    SOCKETFILTERFW="$tmp/bin/socketfilterfw" bash macos/firewall.sh "$@"
}

firewall_check_reports_and_never_sudos() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  firewall_stub "$tmp" on off
  rc=0
  out=$(firewall_run "$tmp" check) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "stealthmode: want on, have off" ] || {
    echo "check exited $rc with stealth off: $out"
    return 1
  }
  firewall_stub "$tmp" off on
  rc=0
  out=$(firewall_run "$tmp" check) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "globalstate: want on, have off" ] || {
    echo "check exited $rc with the firewall off: $out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check called sudo:"
    cat "$tmp/writes"
    return 1
  }
  firewall_stub "$tmp" on on
  firewall_run "$tmp" check > /dev/null || {
    echo "check did not exit 0 on a match"
    return 1
  }
}
check "check reports each differing firewall setting, exits 0 on a match, and never calls sudo" firewall_check_reports_and_never_sudos

firewall_apply_writes_only_the_difference() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  firewall_stub "$tmp" on off
  out=$(firewall_run "$tmp" apply) || return 1
  diff <(echo "$tmp/bin/socketfilterfw --setstealthmode on") "$tmp/writes" || return 1
  [ "$out" = "stealthmode -> on" ] || {
    echo "apply printed: $out"
    return 1
  }
  # The second run finds nothing to do, so it must not reach sudo again.
  : > "$tmp/writes"
  firewall_run "$tmp" apply > /dev/null || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "a matching machine still called sudo:"
    cat "$tmp/writes"
    return 1
  }
}
check "apply writes exactly the differing setting, through sudo, and nothing once it matches" firewall_apply_writes_only_the_difference

firewall_refuses_output_it_cannot_read() {
  local tmp rc out verb
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  firewall_stub "$tmp" on garbled
  for verb in check apply; do
    rc=0
    out=$(firewall_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or called sudo on unreadable stealth output: $out"
      return 1
    }
  done
}
check "unreadable socketfilterfw output is a broken checker, not a difference" firewall_refuses_output_it_cannot_read
