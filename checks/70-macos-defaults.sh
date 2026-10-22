# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: macos/defaults.sh macos/defaults.txt macos/machine.sh macos/machines/*

# ── macOS defaults ───────────────────────────────────────────────────────────
# macos/defaults.txt is the fourth manifest here and the only one whose
# consumer is a script of this repo's own. So the parsing is where the bugs
# would be, and it is exercised against a stub `defaults` that records what
# it was asked and answers `read` from a fixture: the real one writes to this
# machine's preferences, which a check must never do.
printf '\n%smacOS defaults%s\n' "$DIM" "$OFF"

macos_manifest() {
  local bad f
  # sed's "No such file" goes to its own stderr, not into $bad, so a missing
  # manifest would otherwise feed awk nothing and read as zero problems.
  [ -f macos/defaults.txt ] || {
    echo "macos/defaults.txt missing"
    return 1
  }
  # A machine's overlay is applied on top of the shared file, so a key in
  # both would be written twice with two values, and which one wins would
  # depend on the order of the loop rather than on anything written down.
  for f in macos/machines/*/defaults.txt; do
    [ -f "$f" ] || continue
    bad=$(cat macos/defaults.txt "$f" | sed 's/#.*//' | awk 'NF { print $1, $2 }' | sort | uniq -d)
    [ -z "$bad" ] || {
      echo "$f declares a key the shared manifest already does: $bad"
      return 1
    }
  done
  # `host:` is the one prefix defaults.sh interprets (it strips it and adds
  # `-currentHost`), so it is the one place a typo'd or unknown prefix has to
  # be refused here -- otherwise `hots:NSGlobalDomain` reads as a plain
  # domain and `defaults` would happily create a plist literally named that.
  bad=$(for f in macos/defaults.txt macos/machines/*/defaults.txt; do
    [ -f "$f" ] && sed 's/#.*//' "$f" | awk -v f="$f" '
    NF == 0 { next }
    NF < 4 { print f":"NR": fewer than four fields"; next }
    $1 ~ /:/ && $1 !~ /^host:./ { print f":"NR": unknown domain prefix "$1; next }
    NF > 4 && $3 != "string" { print f":"NR": extra fields"; next }
    $3 !~ /^(bool|int|float|string)$/ { print f":"NR": unknown type "$3; next }
    $3 == "bool" && $4 !~ /^(true|false)$/ { print f":"NR": bool must be true or false" }
    $3 == "int" && $4 !~ /^-?[0-9]+$/ { print f":"NR": int must be an integer" }
    $3 == "float" && $4 !~ /^-?[0-9]+(\.[0-9]+)?$/ { print f":"NR": float must be a number" }
  '
  done)
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "every defaults manifest has domain key type value per line, no key twice" macos_manifest

# The stub answers `read` from $STATE (lines of "domain key value"), records
# every `write` to $WRITES, and every killall to $KILLED. `defaults read` on a
# key that is not set exits 1 and prints to stderr, which is what the stub
# reproduces so the "unset" path is the real one. A leading `-currentHost`
# (defaults.sh's own way of addressing the per-host ByHost file) switches the
# stub to a separate $STATE_HOST/$WRITES_HOST pair, so a test can prove a
# `host:` manifest line never touches the plain domain's state and vice
# versa.
macos_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/defaults" << 'STUB'
#!/usr/bin/env bash
state=$STATE
writes=$WRITES
if [ "$1" = -currentHost ]; then
  shift
  state=$STATE_HOST
  writes=$WRITES_HOST
fi
case "$1" in
  read)
    v=$(awk -v d="$2" -v k="$3" '$1 == d && $2 == k { print $3; exit }' "$state")
    [ -n "$v" ] || { echo "does not exist" >&2; exit 1; }
    echo "$v" ;;
  write)
    echo "$2 $3 $4 $5" >> "$writes" ;;
esac
STUB
  cat > "$dir/bin/killall" << 'STUB'
#!/usr/bin/env bash
echo "$1" >> "$KILLED"
STUB
  chmod +x "$dir/bin/defaults" "$dir/bin/killall"
  machine_fixture "$dir"
}

# A manifest of three keys whose read-back forms differ from their written
# forms: a bool reads back as 1/0, a float as a bare number, a string with ~
# has to compare against the expanded HOME.
macos_fixture_manifest() {
  cat > "$1" << 'EOF'
# comment line
com.apple.finder    ShowPathbar    bool    true    # trailing comment
com.apple.dock      autohide-delay float   0
com.apple.screencapture location  string  ~/Screenshots
EOF
}

macos_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  macos_fixture_manifest "$tmp/defaults.txt"
  printf 'com.apple.finder ShowPathbar 1\ncom.apple.dock autohide-delay 0\ncom.apple.screencapture location %s/Screenshots\n' "$tmp/home" > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > "$tmp/out" || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "wrote although everything matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/killed" ] || {
    echo "restarted an app although nothing changed"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply writes nothing when the machine already matches" macos_apply_is_a_noop_when_matching

macos_apply_writes_only_the_difference() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  macos_fixture_manifest "$tmp/defaults.txt"
  # Finder matches; the dock key is unset; the screenshot path is wrong.
  printf 'com.apple.finder ShowPathbar 1\ncom.apple.screencapture location /elsewhere\n' > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > "$tmp/out" || return 1
  diff <(printf 'com.apple.dock autohide-delay -float 0\ncom.apple.screencapture location -string %s/Screenshots\n' "$tmp/home") "$tmp/writes" || return 1
  # Only the Dock changed; Finder must not be restarted for it.
  diff <(echo Dock) "$tmp/killed" || return 1
  diff <(printf 'com.apple.dock autohide-delay -> 0\ncom.apple.screencapture location -> ~/Screenshots\nrestarted: Dock\nother apps read the new values when they next launch; keyboard and trackpad changes need a log out and back in\n') "$tmp/out" || return 1
}
check "apply writes exactly the differing keys and restarts only their app" macos_apply_writes_only_the_difference

macos_check_reports_and_fails() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  macos_fixture_manifest "$tmp/defaults.txt"
  printf 'com.apple.finder ShowPathbar 0\ncom.apple.dock autohide-delay 0\ncom.apple.screencapture location %s/Screenshots\n' "$tmp/home" > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  if out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  [ "$out" = "com.apple.finder ShowPathbar: want true, have 0" ] || {
    echo "unexpected report: $out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check wrote to defaults"
    return 1
  }
}
check "check reports each difference and never writes" macos_check_reports_and_fails

# A `host:` line must go through `-currentHost` on both read and write, and a
# plain line in the same manifest must not gain it by accident -- the two
# states below are disjoint, so either script touching the wrong one shows up
# as a wrong report or a write on the wrong side.
macos_host_lines_use_currenthost() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  cat > "$tmp/defaults.txt" << 'EOF'
host:NSGlobalDomain    com.apple.mouse.tapBehavior    int    1
NSGlobalDomain         KeyRepeat                       int    2
EOF
  printf 'NSGlobalDomain com.apple.mouse.tapBehavior 0\n' > "$tmp/state_host"
  printf 'NSGlobalDomain KeyRepeat 2\n' > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/writes_host"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" STATE_HOST="$tmp/state_host" \
    WRITES="$tmp/writes" WRITES_HOST="$tmp/writes_host" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > "$tmp/out" || return 1
  diff <(echo "NSGlobalDomain com.apple.mouse.tapBehavior -int 1") "$tmp/writes_host" || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "a host: line wrote to the plain domain:"
    cat "$tmp/writes"
    return 1
  }
  diff <(printf 'host:NSGlobalDomain com.apple.mouse.tapBehavior -> 1\nother apps read the new values when they next launch; keyboard and trackpad changes need a log out and back in\n') "$tmp/out" || return 1

  : > "$tmp/writes_host"
  if out=$(HOME="$tmp/home" STATE="$tmp/state" STATE_HOST="$tmp/state_host" \
    WRITES="$tmp/writes" WRITES_HOST="$tmp/writes_host" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  [ "$out" = "host:NSGlobalDomain com.apple.mouse.tapBehavior: want 1, have 0" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "a host: line reads and writes -currentHost, a plain line does not" macos_host_lines_use_currenthost

# A missing manifest must not read as "the machine matches" -- drift.sh's
# own contract for `check` is 0 (matches) or 1 (differences); anything else
# it treats as a broken checker rather than a clean run, but only if this
# script actually reports it that way instead of exiting 0 on an empty read.
macos_refuses_a_missing_manifest() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  : > "$tmp/writes"
  : > "$tmp/killed"
  rc=0
  out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/does-not-exist.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc on a missing manifest, want 2"
    echo "$out"
    return 1
  }
  case "$out" in
    *"no manifest"*) ;;
    *)
      echo "missing manifest did not mention 'no manifest': $out"
      return 1
      ;;
  esac
  [ ! -s "$tmp/writes" ] || {
    echo "wrote although the manifest could not be read"
    return 1
  }
}

# A MANIFEST override whose directory does not exist either (not just the
# file) is a second way to reach the same bug: the `cd` inside the
# resolution has to be its own command substitution, or a failing `cd` is
# swallowed by `set -e` and the readability check further down catches it
# only by accident, against a garbage path it constructs instead of the one
# asked for. Asserting the message names the path as given is what tells the
# two apart: the accident path can only ever report a mangled one.
macos_refuses_a_manifest_in_a_missing_directory() {
  local tmp rc out want
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  : > "$tmp/writes"
  : > "$tmp/killed"
  want="$tmp/no-such-dir/x.txt"
  rc=0
  out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$want" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc on a manifest in a missing directory, want 2"
    echo "$out"
    return 1
  }
  case "$out" in
    *"$want"*) ;;
    *)
      echo "did not name the requested path ($want): $out"
      return 1
      ;;
  esac
  [ ! -s "$tmp/writes" ] || {
    echo "wrote although the manifest could not be read"
    return 1
  }
}
check "check refuses a missing manifest instead of reading it as a match" macos_refuses_a_missing_manifest
check "check names the requested path when its directory is missing too" macos_refuses_a_manifest_in_a_missing_directory

# The machine's own defaults.txt is read after the shared one, and a missing
# machine profile stops the run before anything is written.
macos_applies_the_machine_overlay() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  printf 'com.apple.finder ShowPathbar bool true\n' > "$tmp/defaults.txt"
  # No newline at the end, and a space in the value: the two ways the last
  # line of a hand-written overlay has gone missing or been cut short.
  printf 'pl.maketheweb.cleanshotx exportPath string ~/My Shots' > "$tmp/machines/test/defaults.txt"
  : > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > /dev/null || return 1
  diff - "$tmp/writes" << EOF || return 1
com.apple.finder ShowPathbar -bool true
pl.maketheweb.cleanshotx exportPath -string $tmp/home/My Shots
EOF
  [ -d "$tmp/home/My Shots" ] || {
    echo "the folder exportPath names was not created whole: $(ls "$tmp/home")"
    return 1
  }
  rm "$tmp/machine"
  : > "$tmp/writes"
  rc=0
  out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
    echo "apply exited $rc or wrote with no machine profile: $out"
    return 1
  }
}
check "the machine's defaults.txt is applied after the shared one, last line and folder included, and is required" macos_applies_the_machine_overlay
