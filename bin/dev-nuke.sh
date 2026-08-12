#!/usr/bin/env bash
# Frees a development machine left in a bad state: apps that stopped responding,
# dev servers that outlived their parent and still hold a port, a Postgres
# socket nobody cleaned up, a stale DNS cache, and memory macOS has not
# reclaimed.
#
# Usage:  sudo dev-nuke
#
# Root is needed by two things only: `purge` and signalling mDNSResponder.
# Everything else runs back as the invoking user, which is why `as_user` exists
# rather than a bare command: Homebrew run as root leaves a prefix owned by root
# and the next `brew install` fails for reasons nobody connects to this script.
set -euo pipefail

# Asked to quit, not killed: AppleScript lets them save first.
APPS=("Docker" "Postman")
SERVICES=("postgresql@17")
# Long-running dev servers that survive their parent and keep holding a port.
ORPHAN_PATTERNS=("next-server" "webpack" "ts-node" "nodemon")
# Seconds to wait for a TERM before escalating to KILL.
GRACE=3

if [ "$(id -u)" -ne 0 ]; then
  echo "dev-nuke must run as root: sudo dev-nuke" >&2
  exit 1
fi

# sudo exports the invoking user. The console owner is the fallback for a root
# shell that was not opened through sudo, where SUDO_USER does not exist.
USER_NAME="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
LOG_FILE="$USER_HOME/.local/state/dev-nuke.log"

as_user() { sudo -u "$USER_NAME" "$@"; }

# Created as the user, so the log does not end up owned by root and unwritable
# the next time anything else wants to append to it.
as_user mkdir -p "$(dirname "$LOG_FILE")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | as_user tee -a "$LOG_FILE"; }

log "starting"

# --- 1. Applications ---
for app in "${APPS[@]}"; do
  if pgrep -x "$app" > /dev/null 2>&1; then
    log "quitting $app"
    as_user osascript -e "quit app \"$app\"" 2> /dev/null || true
  fi
done

# --- 2. Orphaned dev servers ---
# Scoped to the invoking user, and matched with pgrep rather than `ps | grep`.
# A grep over `ps aux` also matches processes whose *environment* happens to
# mention the pattern, so searching for one tool kills unrelated ones. pgrep -f
# matches the command line only.
for pattern in "${ORPHAN_PATTERNS[@]}"; do
  pids=$(pgrep -f -u "$USER_NAME" "$pattern" || true)
  [ -z "$pids" ] && continue

  log "terminating orphans matching '$pattern': $(echo "$pids" | tr '\n' ' ')"
  # TERM first: a dev server that handles it flushes and closes its port
  # cleanly. KILL leaves the port in TIME_WAIT, which is the very problem this
  # script is usually run to fix.
  echo "$pids" | xargs kill -TERM 2> /dev/null || true
  sleep "$GRACE"

  survivors=$(pgrep -f -u "$USER_NAME" "$pattern" || true)
  if [ -n "$survivors" ]; then
    log "escalating to KILL: $(echo "$survivors" | tr '\n' ' ')"
    echo "$survivors" | xargs kill -KILL 2> /dev/null || true
  fi
done

# --- 3. Homebrew services ---
for service in "${SERVICES[@]}"; do
  log "stopping service $service"
  as_user brew services stop "$service" > /dev/null 2>&1 || true
done

# --- 4. Postgres socket ---
# Only this socket, by exact path. The previous version deleted every *.lock
# under /tmp, which is shared: it also removed lock files belonging to programs
# that had nothing to do with development and were running fine.
PG_SOCKET="/tmp/.s.PGSQL.5432"
if [ -e "$PG_SOCKET" ]; then
  log "removing stale socket $PG_SOCKET"
  rm -f "$PG_SOCKET"
fi

# --- 5. DNS cache ---
# Both halves are needed: dscacheutil empties the cache, mDNSResponder has to be
# signalled or it keeps serving what it already resolved.
log "flushing DNS cache"
dscacheutil -flushcache
killall -HUP mDNSResponder 2> /dev/null || true

# --- 6. Memory ---
# Forces macOS to release inactive and wired pages it is holding on to.
log "purging inactive memory"
purge

log "done"
as_user osascript -e 'display notification "Development environment reset." with title "dev-nuke"' 2> /dev/null || true
