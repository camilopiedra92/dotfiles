# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Touch ID for sudo ────────────────────────────────────────────────────────
# macos/touchid.sh turns on Touch ID for sudo through /etc/pam.d/sudo_local,
# the file Apple keeps across system updates. Same contract as power.sh:
# check never reaches sudo, apply reaches it once and only for a difference.
# PAM_DIR points both at a fixture holding Apple's template, and the sudo
# stub records its arguments and then runs them, so `tee` really writes the
# fixture file.
printf '\n%sTouch ID for sudo%s\n' "$DIM" "$OFF"

touchid_stub() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/pam.d"
  cat > "$dir/bin/sudo" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WRITES"
exec "$@"
STUB
  chmod +x "$dir/bin/sudo"
  # Apple's template as macOS 27.0 ships it, read 2026-10-03.
  cat > "$dir/pam.d/sudo_local.template" << 'EOF'
# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
#auth       sufficient     pam_tid.so
EOF
  : > "$dir/writes"
}

touchid_run() {
  local tmp=$1
  shift
  WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" PAM_DIR="$tmp/pam.d" bash macos/touchid.sh "$@"
}

touchid_check_reports_and_never_sudos() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  rc=0
  out=$(touchid_run "$tmp" check) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "Touch ID for sudo is off: no pam_tid.so line in $tmp/pam.d/sudo_local" ] || {
    echo "check exited $rc with no sudo_local: $out"
    return 1
  }
  # The template's own line is commented out, which is still off.
  cp "$tmp/pam.d/sudo_local.template" "$tmp/pam.d/sudo_local"
  rc=0
  touchid_run "$tmp" check > /dev/null || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "check exited $rc with the line commented out, want 1"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check called sudo:"
    cat "$tmp/writes"
    return 1
  }
}
check "check reports Touch ID off, commented line included, and never calls sudo" touchid_check_reports_and_never_sudos

touchid_apply_writes_the_template_once() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  out=$(touchid_run "$tmp" apply) || return 1
  [ "$out" = "Touch ID for sudo -> on" ] || {
    echo "unexpected output: $out"
    return 1
  }
  diff - "$tmp/pam.d/sudo_local" << 'EOF' || return 1
# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
auth       sufficient     pam_tid.so
EOF
  [ "$(wc -l < "$tmp/writes")" -eq 1 ] || {
    echo "apply called sudo more than once:"
    cat "$tmp/writes"
    return 1
  }
  : > "$tmp/writes"
  out=$(touchid_run "$tmp" apply) || return 1
  [ -z "$out" ] && [ ! -s "$tmp/writes" ] || {
    echo "a second apply called sudo or printed: $out"
    return 1
  }
  touchid_run "$tmp" check > /dev/null || {
    echo "check did not see the line apply wrote"
    return 1
  }
}
check "apply writes Apple's template with the line uncommented, once, through sudo" touchid_apply_writes_the_template_once

# A sudo_local someone already wrote -- another PAM module, a comment -- is
# theirs: apply adds the one line and keeps the rest.
touchid_apply_keeps_an_existing_file() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  printf '# mine\nauth       optional       pam_example.so\n' > "$tmp/pam.d/sudo_local"
  touchid_run "$tmp" apply > /dev/null || return 1
  diff - "$tmp/pam.d/sudo_local" << 'EOF' || return 1
# mine
auth       optional       pam_example.so
auth       sufficient     pam_tid.so
EOF
}
check "apply adds the line to an existing sudo_local and keeps what was there" touchid_apply_keeps_an_existing_file

touchid_refuses_without_a_template() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  rm "$tmp/pam.d/sudo_local.template"
  for verb in check apply; do
    rc=0
    out=$(touchid_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or called sudo with no template and no sudo_local: $out"
      return 1
    }
  done
}
check "no template and no sudo_local is a broken checker, not a file to invent" touchid_refuses_without_a_template
