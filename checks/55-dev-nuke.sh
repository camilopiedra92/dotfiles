# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: bin/dev-nuke.sh

# ── dev-nuke ─────────────────────────────────────────────────────────────────
# bin/dev-nuke.sh quits apps, signals processes, deletes a socket, flushes DNS
# and purges memory, as root. Its check runs it under a hermetic PATH: stubs for
# everything that acts on the machine or reads who is running it, links to the
# harmless utilities it needs, and nothing else. A stub-first PATH that fell
# through to the real one would let a command the stubs miss -- today's or one
# added later -- act on the machine; here a command looked up on PATH fails as
# "command not found" instead. What PATH cannot close: an absolute path, a shell
# redirection, and builtins -- bash's kill, if the script stopped going through
# xargs, is the dangerous one. Against kill, the fixture's PIDs are six digits,
# above the five macOS gives out, so a real kill finds no such process (`kill -0
# 900101` answered "No such process" here, 2026-10-12). rm is a stub that
# removes nothing outside the scratch directory, so even a script that ignored
# DEV_NUKE_PG_SOCKET could not delete the real socket. HOME is a scratch
# directory too, so a log written to the wrong home stays in it.
#
# Every stub that stands for an action appends "as=<user> <command> <args>"
# to $CALLS, where the user is the one the sudo stub ran it as, or root.
# pgrep answers from $PROCS, one "pid owner obeys-TERM command" line per
# process, and kill -TERM removes the processes that obey it, so which ones
# survive to KILL is the fixture's choice.
printf '\n%sdev-nuke%s\n' "$DIM" "$OFF"

dev_nuke_stubs() {
  local bin=$1 tool real
  mkdir -p "$bin"
  for tool in awk basename bash cat date dirname tr xargs; do
    real=$(command -v "$tool") || return 1
    ln -s "$real" "$bin/$tool"
  done
  # The log and its directory must be written as the user, so tee and mkdir
  # log who ran them before doing their real work.
  for tool in tee mkdir; do
    real=$(command -v "$tool") || return 1
    cat > "$bin/$tool" << STUB
#!/usr/bin/env bash
printf 'as=%s %s\\n' "\${AS_USER:-root}" "$tool \$*" >> "\$CALLS"
exec "$real" "\$@"
STUB
  done
  for tool in osascript brew dscacheutil killall purge sleep stat; do
    cat > "$bin/$tool" << 'STUB'
#!/usr/bin/env bash
printf 'as=%s %s\n' "${AS_USER:-root}" "$(basename "$0")${*:+ $*}" >> "$CALLS"
STUB
  done
  cat > "$bin/id" << 'STUB'
#!/usr/bin/env bash
echo "$FAKE_UID"
STUB
  # Only the invoking user's record exists, so asking for anyone else's home
  # fails the way dscl does for an unknown user.
  cat > "$bin/dscl" << 'STUB'
#!/usr/bin/env bash
[ "$1 $2 $3 $4" = ". -read /Users/$SUDO_USER NFSHomeDirectory" ] || exit 56
echo "NFSHomeDirectory: $FAKE_HOME"
STUB
  # sudo -u USER cmd...: records the user for the stubs below it, runs cmd.
  cat > "$bin/sudo" << 'STUB'
#!/usr/bin/env bash
[ "$1" = -u ] || exit 97
AS_USER=$2
export AS_USER
shift 2
exec "$@"
STUB
  # pgrep [-x] [-f] [-u USER] PATTERN, in any order: -x matches the whole
  # command, otherwise any part of the command line; -u limits it to USER.
  cat > "$bin/pgrep" << 'STUB'
#!/usr/bin/env bash
printf 'as=%s %s\n' "${AS_USER:-root}" "pgrep $*" >> "$CALLS"
exact=0 user=''
while [ $# -gt 1 ]; do
  case "$1" in
    -x) exact=1 ;;
    -f) ;;
    -u) user=$2; shift ;;
    *) exit 99 ;;
  esac
  shift
done
awk -v x="$exact" -v u="$user" -v p="$1" '
  { c = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", c) }
  (u == "" || $2 == u) && (x ? c == p : index(c, p)) { print $1; f = 1 }
  END { exit !f }' "$PROCS"
STUB
  # One line per call, "kill -SIG pid...", as xargs batches them. TERM
  # removes the processes that obey it; KILL removes any.
  cat > "$bin/kill" << 'STUB'
#!/usr/bin/env bash
printf 'as=%s %s\n' "${AS_USER:-root}" "kill $*" >> "$CALLS"
sig=$1
shift
for pid in "$@"; do
  awk -v p="$pid" -v s="$sig" '!($1 == p && (s == "-KILL" || $3 == 1))' "$PROCS" > "$PROCS.new"
  cat "$PROCS.new" > "$PROCS"
done
STUB
  cat > "$bin/rm" << 'STUB'
#!/usr/bin/env bash
printf 'as=%s %s\n' "${AS_USER:-root}" "rm $*" >> "$CALLS"
for path in "$@"; do
  case "$path" in
    -*) ;;
    *..*) exit 95 ;;
    "$SCRATCH"/*) /bin/rm -f -- "$path" ;;
    *) exit 96 ;;
  esac
done
STUB
  chmod +x "$bin"/*
}

dev_nuke() {
  local tmp out pid line term kill rms
  tmp=$(mktemp -d) || return 1
  trap '/bin/rm -rf "$tmp"' RETURN
  dev_nuke_stubs "$tmp/bin" || {
    echo "setup: a utility the hermetic PATH links to is missing"
    return 1
  }
  mkdir -p "$tmp/home" "$tmp/roothome" "$tmp/sock"
  : > "$tmp/sock/.s.PGSQL.5432"
  : > "$tmp/sock/other.lock"
  # Docker runs, Postman does not (a document viewer only mentions it). Each
  # orphan pattern has one of the user's processes that obeys TERM, one that
  # does not, and another user's process that matches it too.
  cat > "$tmp/procs" << 'PROCS'
900200 me 1 Docker
900300 me 1 Preview Postman-guide.pdf
900101 me 1 node next-server
900102 me 0 node next-server --turbo
900111 other 0 node next-server
900201 me 1 webpack serve
900202 me 0 webpack --watch
900211 other 0 webpack serve
PROCS
  run() {
    : > "$tmp/calls"
    CALLS="$tmp/calls" PROCS="$tmp/procs" SCRATCH="$tmp" FAKE_UID=$1 FAKE_HOME="$tmp/home" \
      HOME="$tmp/roothome" SUDO_USER=me DEV_NUKE_PG_SOCKET="$tmp/sock/.s.PGSQL.5432" \
      PATH="$tmp/bin" "$tmp/bin/bash" bin/dev-nuke.sh 2>&1
  }
  called() { grep -qxF "$1" "$tmp/calls"; }
  # The line number of the kill call that sent SIG to PID, batched or not.
  signalled() { grep -n "^as=root kill -$1 " "$tmp/calls" | grep -E " $2( |\$)" | cut -d: -f1; }

  if out=$(run 501); then
    echo "root: ran without root"
    return 1
  fi
  [ ! -s "$tmp/calls" ] || {
    echo "root: acted before refusing to run without root: $(cat "$tmp/calls")"
    return 1
  }

  out=$(run 0) || {
    echo "run: failed as root: $out"
    return 1
  }

  called 'as=me osascript -e quit app "Docker"' || {
    echo "apps: did not ask Docker to quit as the invoking user"
    return 1
  }
  if grep -q 'osascript.*Postman' "$tmp/calls"; then
    echo "apps: asked Postman to quit, which is not running"
    return 1
  fi

  # TERM to every one of the user's matching processes; then, after a
  # grace period, KILL to exactly the ones that ignored it.
  for pid in 900101 900102 900201 900202; do
    [ -n "$(signalled TERM "$pid")" ] || {
      echo "orphans: did not send TERM to $pid, one of the user's matching processes"
      return 1
    }
  done
  for pid in 900101 900201; do
    [ -z "$(signalled KILL "$pid")" ] || {
      echo "orphans: sent KILL to $pid, which had exited on TERM"
      return 1
    }
  done
  for pid in 900102 900202; do
    term=$(signalled TERM "$pid")
    kill=$(signalled KILL "$pid")
    if [ -z "$kill" ] || [ "$term" -gt "$kill" ]; then
      echo "orphans: $pid survived TERM but was not sent KILL after it"
      return 1
    fi
    awk -v t="$term" -v k="$kill" 'NR > t && NR < k && /^as=root sleep [1-9]/ { f = 1 } END { exit !f }' "$tmp/calls" || {
      echo "orphans: sent KILL to $pid without waiting out a grace period after TERM"
      return 1
    }
  done
  for pid in 900111 900211; do
    if line=$(grep -E "^as=[a-z]+ kill .* $pid( |\$)" "$tmp/calls"); then
      echo "other users: signalled $pid, which belongs to another user: $line"
      return 1
    fi
  done

  [ ! -e "$tmp/sock/.s.PGSQL.5432" ] || {
    echo "socket: the stale socket at DEV_NUKE_PG_SOCKET is still there"
    return 1
  }
  [ -e "$tmp/sock/other.lock" ] || {
    echo "socket: removed a file beside the socket"
    return 1
  }
  if rms=$(grep '^as=[a-z]* rm ' "$tmp/calls") && grep -vqxF "as=root rm -f $tmp/sock/.s.PGSQL.5432" <<< "$rms"; then
    echo "socket: rm was asked for something besides the socket: $(grep ' rm ' "$tmp/calls")"
    return 1
  fi

  if ! called 'as=root dscacheutil -flushcache' || ! called 'as=root killall -HUP mDNSResponder' ||
    ! called 'as=root purge'; then
    echo "dns and memory: did not flush the DNS cache and purge memory"
    return 1
  fi

  # Everything run on the user's behalf runs as the user: the services, the
  # notification, and the log, which must end up in their home, not root's.
  called 'as=me brew services stop postgresql@17' || {
    echo "as user: did not stop the service as the invoking user"
    return 1
  }
  grep -q '^as=me osascript -e display notification' "$tmp/calls" || {
    echo "as user: did not notify the invoking user"
    return 1
  }
  if grep -Eq '^as=root (osascript|brew|tee|mkdir)' "$tmp/calls"; then
    echo "as user: ran osascript, brew, or wrote the log, as root: $(grep -E '^as=root (osascript|brew|tee|mkdir)' "$tmp/calls")"
    return 1
  fi
  # Asserted as calls, not only as the file: root writing the log through a
  # shell redirection reaches the same file and no stub would see it.
  local log="$tmp/home/.local/state/dev-nuke.log"
  if ! called "as=me mkdir -p $tmp/home/.local/state" || ! called "as=me tee -a $log"; then
    echo "as user: did not create and write the log as the invoking user"
    return 1
  fi
  grep -q 'done' "$log" 2> /dev/null || {
    echo "as user: the log did not reach the invoking user's home"
    return 1
  }
}
check "dev-nuke refuses without root, and signals, quits and deletes only what it should, as whom it should" dev_nuke
