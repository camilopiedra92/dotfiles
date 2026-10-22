# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: macos/power.sh

# ── macOS power ──────────────────────────────────────────────────────────────
# macos/power.sh is the one script here that writes through sudo, so the
# stubs prove two things the defaults tests do not have to: that `apply`
# reaches pmset only through sudo and only for a difference, and that
# `check` never reaches sudo at all. The `pmset` stub answers `-g custom`
# from $STATE, a file in the real command's output shape -- a "Battery
# Power:" section and an "AC Power:" section, one setting per line -- so a
# value under the wrong profile is a real trap the parser can fall into.
# The `sudo` stub records its arguments to $WRITES and runs nothing.
printf '\n%smacOS power%s\n' "$DIM" "$OFF"

power_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/pmset" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = -g ] && [ "$2" = custom ]; then
  cat "$STATE"
  exit 0
fi
echo "pmset stub: unexpected direct call: $*" >&2
exit 99
STUB
  cat > "$dir/bin/sudo" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WRITES"
STUB
  chmod +x "$dir/bin/pmset" "$dir/bin/sudo"
}

# What `pmset -g custom` printed on this machine on 2026-09-15 (womp from
# 2026-10-10), cut to the lines that matter, with the battery powermode as
# given and the Wake for network access (womp) of each profile as given, 0 by
# default. AC always reads powermode 1 here so a parser that ignores the
# section header cannot pass.
power_state() {
  cat > "$1" << EOF
Battery Power:
 Sleep On Power Button 1
 powermode            $2
 womp                 ${3:-0}
 displaysleep         2
AC Power:
 Sleep On Power Button 1
 powermode            1
 womp                 ${4:-0}
 displaysleep         10
EOF
}

power_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 1
  : > "$tmp/writes"
  STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh apply > "$tmp/out" || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "called sudo although everything matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply calls sudo for nothing when the machine already matches" power_apply_is_a_noop_when_matching

power_apply_writes_the_difference_through_sudo() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 0
  : > "$tmp/writes"
  STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh apply > "$tmp/out" || return 1
  diff <(echo "pmset -b powermode 1") "$tmp/writes" || return 1
  diff <(echo "battery powermode -> 1") "$tmp/out" || return 1
}
check "apply writes exactly the differing setting, through sudo, to the battery profile" power_apply_writes_the_difference_through_sudo

# womp is read per profile: each profile below holds the other's wrong value,
# so a parser that reads the first womp it finds fixes one profile and calls
# the other done.
power_womp_is_enforced_in_each_profile() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 1 1 0
  : > "$tmp/writes"
  STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh apply > "$tmp/out" || return 1
  diff <(echo "pmset -b womp 0") "$tmp/writes" || return 1
  power_state "$tmp/state" 1 0 1
  : > "$tmp/writes"
  STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh apply > "$tmp/out" || return 1
  diff <(echo "pmset -c womp 0") "$tmp/writes" || return 1
  diff <(echo "ac womp -> 0") "$tmp/out" || return 1
  power_state "$tmp/state" 1 1 1
  if out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check); then
    echo "check exited 0 with womp on in both profiles"
    return 1
  fi
  [ "$out" = "$(printf 'battery womp: want 0, have 1\nac womp: want 0, have 1')" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "apply and check enforce Wake for network access off in each profile separately" power_womp_is_enforced_in_each_profile

power_check_reports_and_never_sudos() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 0
  : > "$tmp/writes"
  if out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  [ "$out" = "battery powermode: want 1, have 0" ] || {
    echo "unexpected report: $out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check called sudo:"
    cat "$tmp/writes"
    return 1
  }
  power_state "$tmp/state" 1
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check) || {
    echo "check exited non-zero with the machine matching"
    return 1
  }
  [ -z "$out" ] || {
    echo "check printed with the machine matching: $out"
    return 1
  }
}
check "check reports the difference, exits 0 on a match, and never calls sudo" power_check_reports_and_never_sudos

# A `pmset -g custom` with no Battery Power section -- a desktop, or a
# pmset that failed -- must not read as "matches", the same contract
# defaults.sh keeps for a missing manifest: 0 and 1 are check's own answers,
# anything else is a broken checker for drift.sh to surface.
power_check_refuses_a_missing_battery_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  printf 'AC Power:\n powermode            1\n' > "$tmp/state"
  : > "$tmp/writes"
  rc=0
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc without a Battery Power profile, want 2"
    echo "$out"
    return 1
  }
  case "$out" in
    *"Battery Power"*) ;;
    *)
      echo "did not name the missing profile: $out"
      return 1
      ;;
  esac
}
check "check refuses a pmset output with no battery profile instead of reading it as a match" power_check_refuses_a_missing_battery_profile
