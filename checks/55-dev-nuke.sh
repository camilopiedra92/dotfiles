# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── dev-nuke ─────────────────────────────────────────────────────────────────
# bin/dev-nuke.sh quits apps, signals processes, deletes a socket, flushes DNS
# and purges memory, as root. Its check runs it under a hermetic PATH: stubs
# for everything that acts on the machine or reads who is running it, links to
# the harmless utilities it needs, and nothing else. A stub-first PATH that
# fell through to the real one would let a command the stubs miss -- today's
# or one added later -- act on the machine; here it fails as "command not
# found" instead. rm is a stub too, and removes nothing outside the scratch
# directory, so even a script that ignored DEV_NUKE_PG_SOCKET could not delete
# the real socket.
#
# Every stub that stands for an action appends "as=<user> <command> <args>"
# to $CALLS, where the user is the one the sudo stub ran it as, or root. pgrep answers from $PROCS, one
# "pid owner obeys-TERM command" line per process, and kill -TERM removes the
# processes that obey it, so which ones survive to KILL is the fixture's
# choice.
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
printf 'as=%s %s\n' "\${AS_USER:-root}" "$tool \$*" >> "\$CALLS"
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
  cat > "$bin/dscl" << 'STUB'
#!/usr/bin/env bash
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
  # -x NAME matches the command exactly; -f [-u USER] PATTERN matches the
  # processes, USER's only when given, whose command line contains PATTERN.
  cat > "$bin/pgrep" << 'STUB'
#!/usr/bin/env bash
printf 'as=%s %s\n' "${AS_USER:-root}" "pgrep $*" >> "$CALLS"
case "$1" in
  -x) awk -v n="$2" '{ c = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", c) } c == n { print $1; f = 1 } END { exit !f }' "$PROCS" ;;
  -f)
    u='' p=$2
    [ "$2" = -u ] && u=$3 p=$4
    awk -v u="$u" -v p="$p" '{ c = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", c) } (u == "" || $2 == u) && index(c, p) { print $1; f = 1 } END { exit !f }' "$PROCS"
    ;;
  *) exit 99 ;;
esac
STUB
  # TERM removes the processes that obey it; KILL removes any.
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
    "$SCRATCH"/*) /bin/rm -f -- "$path" ;;
    *) exit 96 ;;
  esac
done
STUB
  chmod +x "$bin"/*
}

dev_nuke() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap '/bin/rm -rf "$tmp"' RETURN
  dev_nuke_stubs "$tmp/bin" || {
    echo "setup: a utility the hermetic PATH links to is missing"
    return 1
  }
  mkdir -p "$tmp/home" "$tmp/sock"
  : > "$tmp/sock/.s.PGSQL.5432"
  : > "$tmp/sock/other.lock"
  cat > "$tmp/procs" << 'PROCS'
200 me 1 Docker
101 me 1 node next-server
102 me 0 webpack serve
103 other 0 nodemon app.js
PROCS
  run() {
    : > "$tmp/calls"
    CALLS="$tmp/calls" PROCS="$tmp/procs" SCRATCH="$tmp" FAKE_UID=$1 FAKE_HOME="$tmp/home" \
      SUDO_USER=me DEV_NUKE_PG_SOCKET="$tmp/sock/.s.PGSQL.5432" PATH="$tmp/bin" \
      "$tmp/bin/bash" bin/dev-nuke.sh 2>&1
  }
  called() { grep -qxF "$1" "$tmp/calls"; }

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

  # 101 obeys TERM; 102 ignores it and is the only one KILL may reach.
  local term102 kill102
  if ! called 'as=root kill -TERM 101' || ! called 'as=root kill -TERM 102'; then
    echo "orphans: did not send TERM to each of the user's matching processes"
    return 1
  fi
  if grep -q '^as=root kill -KILL.*101' "$tmp/calls"; then
    echo "orphans: sent KILL to 101, which had exited on TERM"
    return 1
  fi
  term102=$(grep -n '^as=root kill -TERM 102$' "$tmp/calls" | cut -d: -f1)
  kill102=$(grep -n '^as=root kill -KILL 102$' "$tmp/calls" | cut -d: -f1)
  [ -n "$kill102" ] && [ "$term102" -lt "$kill102" ] || {
    echo "orphans: 102 survived TERM but was not sent KILL after it"
    return 1
  }
  if grep -q '^as=root kill .*103' "$tmp/calls"; then
    echo "other users: signalled 103, which belongs to another user"
    return 1
  fi

  [ ! -e "$tmp/sock/.s.PGSQL.5432" ] || {
    echo "socket: the stale socket at DEV_NUKE_PG_SOCKET is still there"
    return 1
  }
  [ -e "$tmp/sock/other.lock" ] || {
    echo "socket: removed a file beside the socket"
    return 1
  }
  if grep '^as=[a-z]* rm ' "$tmp/calls" | grep -vqxF "as=root rm -f $tmp/sock/.s.PGSQL.5432"; then
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
  if grep -Eq '^as=root (osascript|brew|tee|mkdir)' "$tmp/calls"; then
    echo "as user: ran osascript, brew, or wrote the log, as root: $(grep -E '^as=root (osascript|brew|tee|mkdir)' "$tmp/calls")"
    return 1
  fi
  grep -q 'done' "$tmp/home/.local/state/dev-nuke.log" 2> /dev/null || {
    echo "as user: the log did not reach the invoking user's home"
    return 1
  }
}
check "dev-nuke refuses without root, and signals, quits and deletes only what it should, as whom it should" dev_nuke
