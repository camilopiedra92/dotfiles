# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Machine profile ──────────────────────────────────────────────────────────
# One repo, more than one Mac. macos/machine.sh says which profile under
# macos/machines/ this Mac is, from a one-word file outside the repo, and the
# per-machine manifests hang off that answer. No profile, or one that names a
# directory that does not exist, has to be a broken checker (exit 2) for
# every script that asks: guessing would apply one Mac's Dock to the other.
printf '\n%sMachine profile%s\n' "$DIM" "$OFF"

# A profile directory named `test` with nothing in it, and a machine file
# naming it. Shared by every test below that runs a per-machine script.
machine_fixture() {
  mkdir -p "$1/machines/test"
  echo test > "$1/machine"
}

machine_run() {
  local tmp=$1
  shift
  MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/machine.sh "$@"
}

machine_requires_a_known_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/machines/personal" "$tmp/machines/work"
  rc=0
  out=$(machine_run "$tmp" dir 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "dir exited $rc with no machine file, want 2: $out"
    return 1
  }
  case "$out" in
    *"$tmp/machine"*"personal work"*) ;;
    *)
      echo "did not name the file and the profiles to choose from: $out"
      return 1
      ;;
  esac
  echo nope > "$tmp/machine"
  rc=0
  out=$(machine_run "$tmp" dir 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "dir exited $rc for an unknown profile, want 2: $out"
    return 1
  }
  case "$out" in
    *"unknown machine 'nope'"*) ;;
    *)
      echo "did not name the unknown profile: $out"
      return 1
      ;;
  esac
}
check "dir refuses a missing machine file and an unknown profile" machine_requires_a_known_profile

machine_set_validates_then_writes() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  # $tmp/etc exists, so only the name check can refuse ../etc.
  mkdir -p "$tmp/machines/personal" "$tmp/etc"
  rc=0
  out=$(machine_run "$tmp" set ../etc 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
    echo "set accepted a profile that does not exist (exit $rc): $out"
    return 1
  }
  machine_run "$tmp" set personal || return 1
  [ "$(cat "$tmp/machine")" = personal ] || {
    echo "set wrote: $(cat "$tmp/machine")"
    return 1
  }
  out=$(machine_run "$tmp" dir) || return 1
  [ "$out" = "$tmp/machines/personal" ] || {
    echo "dir printed $out"
    return 1
  }
}
check "set refuses an unknown profile, writes a known one, and dir finds it" machine_set_validates_then_writes

# A profile name is lowercase letters, digits and dashes, matched byte by
# byte. A bracket range follows the locale's collation in bash 3.2, so
# [a-z] lets uppercase through under en_US.UTF-8 -- and APFS, being
# case-insensitive, would then resolve `Personal` to personal/ on one Mac
# and not on a case-sensitive volume. Inner whitespace is not trimmed into
# a different, valid name either.
machine_names_are_exact() {
  local tmp rc name
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/machines/personal"
  for name in Personal "per sonal"; do
    rc=0
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 machine_run "$tmp" set "$name" 2> /dev/null || rc=$?
    [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
      echo "set accepted '$name' (exit $rc)"
      return 1
    }
    printf '%s\n' "$name" > "$tmp/machine"
    rc=0
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 machine_run "$tmp" dir > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "dir accepted a machine file saying '$name' (exit $rc)"
      return 1
    }
    rm "$tmp/machine"
  done
}
check "a profile name matches exactly: no uppercase, no inner space" machine_names_are_exact

# install.sh's own step for the profile: silent when one is recorded, and
# when none is and nobody is at a terminal to answer -- CI, a piped run -- it
# stops with machine.sh's reason instead of waiting on a prompt or carrying
# on into steps that would then fail one by one. Extracted the same way the
# idempotence check extracts the symlink steps, and run against a fixture.
install_machine_step() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 8\. Machine profile/,/^# --- 8a\./p' install.sh
  } > "$tmp/step.sh"
  grep -qF 'machine.sh' "$tmp/step.sh" || {
    echo "could not extract step 8 from install.sh"
    return 1
  }
  one_step_only "$tmp/step.sh" || return 1
  mkdir -p "$tmp/machines/personal"
  rc=0
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" \
    bash -euo pipefail "$tmp/step.sh" < /dev/null 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
    echo "without a terminal or a profile the step exited $rc, want 2: $out"
    return 1
  }
  case "$out" in
    *"no machine profile"*) ;;
    *)
      echo "did not say why it stopped: $out"
      return 1
      ;;
  esac
  echo personal > "$tmp/machine"
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" \
    bash -euo pipefail "$tmp/step.sh" < /dev/null 2>&1) || {
    echo "the step failed with a profile recorded: $out"
    return 1
  }
  [ "$out" = "==> Machine profile: personal" ] || {
    echo "unexpected output with a profile recorded: $out"
    return 1
  }
}
check "install.sh stops when there is no profile and nobody to ask" install_machine_step

# The prompt itself, through a real terminal: expect(1), which macOS ships,
# allocates one and answers it. A wrong name asks again rather than ending
# the install; end of input stops it with a reason rather than in silence.
install_machine_prompt() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 8\. Machine profile/,/^# --- 8a\./p' install.sh
  } > "$tmp/step.sh"
  mkdir -p "$tmp/machines/personal"
  rc=0
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" expect -c "
    set timeout 10
    spawn bash -euo pipefail $tmp/step.sh
    expect {Profile for this Mac: }
    send nope\r
    expect {Profile for this Mac: }
    send personal\r
    expect eof
    exit [lindex [wait] 3]
  " 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$tmp/machine" 2> /dev/null)" = personal ] || {
    echo "a wrong answer then a right one did not record personal (exit $rc): $out"
    return 1
  }
  rm "$tmp/machine"
  rc=0
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" expect -c "
    set timeout 10
    spawn bash -euo pipefail $tmp/step.sh
    expect {Profile for this Mac: }
    send \004
    expect eof
    exit [lindex [wait] 3]
  " 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
    echo "end of input at the prompt exited $rc, want 2: $out"
    return 1
  }
  case "$out" in
    *"no profile given"*) ;;
    *)
      echo "end of input did not say why it stopped: $out"
      return 1
      ;;
  esac
}
check "install.sh asks again after a wrong name, and stops with a reason on end of input" install_machine_prompt

# Step 8a installs the packages only this Mac wants, from its profile's own
# Brewfile. Run against a stub brew that records its arguments: installing is
# Homebrew's job, what is ours is which file it is pointed at, and that a
# profile with no Brewfile installs nothing and still succeeds.
install_machine_brewfile_step() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 8a\. Machine Brewfile/,/^# --- 8b\./p' install.sh
  } > "$tmp/step.sh"
  grep -qF 'brew bundle' "$tmp/step.sh" || {
    echo "could not extract step 8a from install.sh"
    return 1
  }
  one_step_only "$tmp/step.sh" || return 1
  mkdir -p "$tmp/bin" "$tmp/with" "$tmp/without"
  printf '#!/bin/sh\necho "$@" >> "%s/brew.log"\n' "$tmp" > "$tmp/bin/brew"
  chmod +x "$tmp/bin/brew"
  echo 'cask "rectangle"' > "$tmp/with/Brewfile"

  PATH="$tmp/bin:$PATH" machine_dir="$tmp/without" bash -euo pipefail "$tmp/step.sh" > /dev/null 2>&1 || {
    echo "the step failed for a profile with no Brewfile"
    return 1
  }
  [ ! -e "$tmp/brew.log" ] || {
    echo "brew ran for a profile with no Brewfile: $(cat "$tmp/brew.log")"
    return 1
  }
  PATH="$tmp/bin:$PATH" machine_dir="$tmp/with" bash -euo pipefail "$tmp/step.sh" > /dev/null 2>&1 || {
    echo "the step failed for a profile with a Brewfile"
    return 1
  }
  out=$(cat "$tmp/brew.log" 2> /dev/null)
  [ "$out" = "bundle install --no-upgrade --file=$tmp/with/Brewfile" ] || {
    echo "brew was called with: ${out:-nothing}"
    return 1
  }
}
check "install.sh installs the profile's Brewfile with --no-upgrade, and nothing without one" install_machine_brewfile_step
