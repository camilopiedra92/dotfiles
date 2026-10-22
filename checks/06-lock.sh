# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: check.sh

# ── Run lock ─────────────────────────────────────────────────────────────────
# One top-level check.sh at a time per user on this machine (specs/006).
# Driven against byte-identical copies of this check.sh in scratch
# repositories, run side by side: each copy starts with CHECK_SH_RUN removed,
# so it is a top-level run and not part of the run executing this section, and
# with a stub `getconf` first on PATH that names a scratch lock directory, so
# it never touches nor waits on the real lock this run holds. The fake
# sections log `<run> start` and `<run> end` to one file shared by the runs;
# an overlap shows as interleaved lines, so no clock is read.
printf '\n%sRun lock%s\n' "$DIM" "$OFF"

# lock_env <tmp>: the stub getconf in <tmp>/bin, answering <tmp>/lockdir/ for
# the per-user temporary directory and passing anything else to the real one.
# Sets LOCK_TMP, read by the helpers below.
lock_env() {
  LOCK_TMP=$1
  LOCK_FILE=$LOCK_TMP/lockdir/dotfiles-check.lock
  mkdir -p "$LOCK_TMP/bin" "$LOCK_TMP/lockdir"
  : > "$LOCK_TMP/log"
  : > "$LOCK_TMP/pids"
  # shellcheck disable=SC2016  # expanded by the stub, not here
  printf '#!/bin/sh\nif [ "$1" = DARWIN_USER_TEMP_DIR ]; then echo "%s/lockdir/"; else exec /usr/bin/getconf "$@"; fi\n' \
    "$LOCK_TMP" > "$LOCK_TMP/bin/getconf"
  chmod +x "$LOCK_TMP/bin/getconf"
}

# lock_repo <dir> <name> <seconds> [<extra section body>]: a scratch repository
# whose one section logs `<name> start`, sleeps, and logs `<name> end`. The
# sleep records its own pid (sh's $$, kept by exec), so lock_cleanup can end
# it even when the run that started it was killed and it lost its parent.
lock_repo() {
  local dir=$1 name=$2 seconds=$3 extra=${4:-}
  sections_repo "$dir" "10-a:echo '$name start' >> '$LOCK_TMP/log'
sh -c 'echo \$\$ >> \"$LOCK_TMP/pids\"; exec sleep $seconds'
echo '$name end' >> '$LOCK_TMP/log'
check '$name ran' true
$extra"
}

# lock_start <dir> <out-prefix> [<flags>...]: starts the copy in <dir> in the
# background, stdout to <out-prefix>.out and stderr to <out-prefix>.err, and
# sets LOCK_PID to the runner's pid (the subshell execs env, which execs it).
lock_start() {
  local dir=$1 prefix=$2
  shift 2
  (cd "$dir" && exec env -u CHECK_SH_RUN PATH="$LOCK_TMP/bin:$PATH" ./check.sh "$@") > "$prefix.out" 2> "$prefix.err" &
  LOCK_PID=$!
  echo "$LOCK_PID" >> "$LOCK_TMP/pids"
}

# within <seconds> <pid>: waits for a child up to the bound and sets RC to its
# exit status; past the bound it kills the child and what it started and
# returns 1. bash 3.2 has no `timeout`, and a case that hangs must fail, not
# hang the suite.
within() {
  local pid=$2 ticks=0 limit
  # 20 ticks of 0.05 s per second; bash has no fractions.
  limit=$(awk -v s="$1" 'BEGIN { print int(s * 20) }')
  while kill -0 "$pid" 2> /dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      echo "pid $pid still running after $1 s; killed"
      kill_tree "$pid"
      wait "$pid" 2> /dev/null
      RC=
      return 1
    fi
    sleep 0.05
    ticks=$((ticks + 1))
  done
  RC=0
  wait "$pid" || RC=$?
}

# lock_await <text>: waits, up to 5 s, for a line of the shared log. A run
# logs its start only once it holds the lock and has recorded itself, so the
# next run is started knowing whom it will find.
lock_await() {
  local tries=0
  until grep -qx "$1" "$LOCK_TMP/log"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.05
  done
}

# The log as one line, `|` after each entry.
lock_log() {
  tr '\n' '|' < "$LOCK_TMP/log"
}

# Ends whatever a case started that is still alive: the runners, and the
# sleeps of their sections, which a killed runner leaves without a parent.
lock_cleanup() {
  local pid
  while read -r pid; do
    [ -n "$pid" ] || continue
    kill_tree "$pid" 2> /dev/null
  done < "$LOCK_TMP/pids"
  rm -rf "$LOCK_TMP"
}

# lock_expect <case> <what> <expected> <got>
lock_expect() {
  [ "$3" = "$4" ] || {
    printf '%s: expected %s\n  [%s]\ngot\n  [%s]\n' "$1" "$2" "$3" "$4"
    return 1
  }
}

# US1 AS1, FR-001, FR-002. B starts once A has logged its start, which A does
# only holding the lock and recorded: B then knows whom it waits for.
lock_waits_across_repositories() {
  local tmp a b
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" A 1
  lock_repo "$tmp/b" B 0.1
  lock_start "$tmp/a" "$tmp/A"
  a=$LOCK_PID
  lock_await "A start" || {
    echo "A never logged its start"
    return 1
  }
  lock_start "$tmp/b" "$tmp/B"
  b=$LOCK_PID
  within 10 "$a" && lock_expect A "exit" 0 "$RC" || return 1
  within 10 "$b" && lock_expect B "exit" 0 "$RC" || return 1
  lock_expect log "no overlap" "A start|A end|B start|B end|" "$(lock_log)" || return 1
  lock_expect "B's stderr" "one waiting line" \
    "check.sh: waiting for the run of pid $a in $tmp/a to finish" "$(cat "$tmp/B.err")"
}
check "a second run waits for the first, across repositories, and says so once" lock_waits_across_repositories

# US1 AS2, FR-003: what B prints after waiting is what it prints alone, for a
# passing and for a failing section.
lock_waited_output_is_unchanged() {
  local tmp verdict waited_rc
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" A 1
  for verdict in true false; do
    rm -rf "$tmp/b"
    lock_repo "$tmp/b" B 0.1 "check 'B verdict' $verdict"
    : > "$tmp/log"
    lock_start "$tmp/a" "$tmp/A"
    lock_await "A start" || return 1
    lock_start "$tmp/b" "$tmp/B-waited"
    within 10 "$LOCK_PID" || return 1
    waited_rc=$RC
    [ -s "$tmp/B-waited.err" ] || {
      echo "$verdict: B did not wait, so nothing is compared"
      return 1
    }
    lock_start "$tmp/b" "$tmp/B-alone"
    within 10 "$LOCK_PID" || return 1
    lock_expect "$verdict" "the exit status alone" "$RC" "$waited_rc" || return 1
    lock_expect "$verdict" "the output alone" "$(cat "$tmp/B-alone.out")" "$(cat "$tmp/B-waited.out")" || return 1
  done
}
check "a run that waited prints what it prints alone" lock_waited_output_is_unchanged

# US1 AS3: two runs of one repository take turns just the same.
lock_is_the_machines() {
  local tmp a b
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" R 1
  lock_start "$tmp/a" "$tmp/first"
  a=$LOCK_PID
  lock_await "R start" || return 1
  lock_start "$tmp/a" "$tmp/second"
  b=$LOCK_PID
  within 10 "$a" && lock_expect first "exit" 0 "$RC" || return 1
  within 10 "$b" && lock_expect second "exit" 0 "$RC" || return 1
  lock_expect log "no overlap" "R start|R end|R start|R end|" "$(lock_log)" || return 1
  lock_expect "second's stderr" "one waiting line" \
    "check.sh: waiting for the run of pid $a in $tmp/a to finish" "$(cat "$tmp/second.err")"
}
check "the lock is the machine's, not the repository's" lock_is_the_machines

# US1 AS4.
lock_free_turn_is_silent() {
  local tmp
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" A 0.1
  lock_start "$tmp/a" "$tmp/A"
  within 2 "$LOCK_PID" || {
    echo "a run with nobody ahead took over 2 s"
    return 1
  }
  lock_expect A "exit" 0 "$RC" || return 1
  lock_expect A "an empty stderr" "" "$(cat "$tmp/A.err")"
}
check "a run with nobody ahead neither waits nor says so" lock_free_turn_is_silent

# US1 AS5, SC-001: three runs waiting behind a fourth run one at a time, in
# whatever order they take the turn.
lock_waiters_go_one_at_a_time() {
  local tmp n pids=() pid log
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/h" H 1
  for n in 1 2 3; do lock_repo "$tmp/w$n" "W$n" 0.3; done
  lock_start "$tmp/h" "$tmp/H"
  pids+=("$LOCK_PID")
  lock_await "H start" || return 1
  for n in 1 2 3; do
    lock_start "$tmp/w$n" "$tmp/W$n"
    pids+=("$LOCK_PID")
  done
  for pid in "${pids[@]}"; do
    within 15 "$pid" && lock_expect "$pid" "exit" 0 "$RC" || return 1
  done
  log=$(lock_log)
  # Four runs, each start followed at once by its own end.
  printf '%s\n' "$log" | tr '|' '\n' | awk '
    NF { n++; if (n % 2) { name = $1; if ($2 != "start") bad = 1 } else if ($1 != name || $2 != "end") bad = 1 }
    END { exit (bad || n != 8) }' || {
    echo "expected four runs, each whole before the next; got: $log"
    return 1
  }
}
check "waiting runs go one at a time" lock_waiters_go_one_at_a_time

# FR-008.
lock_usage_error_does_not_wait() {
  local tmp
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" A 3
  lock_start "$tmp/a" "$tmp/A"
  lock_await "A start" || return 1
  lock_start "$tmp/a" "$tmp/bogus" --bogus
  within 1 "$LOCK_PID" || {
    echo "a usage error waited for the run ahead"
    return 1
  }
  lock_expect "--bogus" "exit" 2 "$RC"
}
check "a usage error does not wait" lock_usage_error_does_not_wait

# The holder has the turn but has written no record: here a bare lockf, which
# leaves the file empty, holds it.
lock_unrecorded_holder() {
  local tmp tries=0 rc
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" R 0.1
  lockf -k "$LOCK_FILE" sh -c "sleep 1; echo 'H end' >> '$tmp/log'" &
  echo "$!" >> "$tmp/pids"
  while :; do
    rc=0
    lockf -k -s -t 0 "$LOCK_FILE" true || rc=$?
    [ "$rc" -eq 75 ] && break
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || {
      echo "the stand-in holder never took the lock"
      return 1
    }
    sleep 0.05
  done
  lock_start "$tmp/a" "$tmp/R"
  within 10 "$LOCK_PID" && lock_expect R "exit" 0 "$RC" || return 1
  lock_expect "R's stderr" "the line without details" \
    "check.sh: waiting for another run to finish" "$(cat "$tmp/R.err")" || return 1
  lock_expect log "R after the holder" "H end|R start|R end|" "$(lock_log)"
}
check "a holder that has not recorded itself still makes a run wait, said without details" lock_unrecorded_holder

# FR-007: the lock cannot be opened (its directory is a file), or it opens and
# lockf fails for a reason other than a holder (a stub answering 71,
# EX_OSERR): neither is a turn held by someone, and neither runs unguarded.
lock_cannot_be_taken() {
  local tmp
  tmp=$(mktemp -d) || return 1
  lock_env "$tmp"
  trap 'lock_cleanup' RETURN
  lock_repo "$tmp/a" A 0.1
  printf '#!/bin/sh\nexit 71\n' > "$tmp/lockf"
  chmod +x "$tmp/lockf"
  cp "$tmp/bin/getconf" "$tmp/getconf"
  : > "$tmp/notadir"
  printf '#!/bin/sh\necho "%s/notadir/"\n' "$tmp" > "$tmp/bin/getconf"
  lock_start "$tmp/a" "$tmp/open"
  within 5 "$LOCK_PID" || return 1
  lock_expect open "exit" 1 "$RC" || return 1
  lock_expect "open's stderr" "the line naming the lock" \
    "check.sh: cannot take the run lock $tmp/notadir/dotfiles-check.lock" "$(cat "$tmp/open.err")" || return 1
  cp "$tmp/getconf" "$tmp/bin/getconf"
  cp "$tmp/lockf" "$tmp/bin/lockf"
  lock_start "$tmp/a" "$tmp/lockf"
  within 5 "$LOCK_PID" || return 1
  lock_expect lockf "exit" 1 "$RC" || return 1
  lock_expect "lockf's stderr" "the line naming the lock" \
    "check.sh: cannot take the run lock $LOCK_FILE" "$(cat "$tmp/lockf.err")" || return 1
  lock_expect log "no section run" "" "$(lock_log)"
}
check "a lock that cannot be taken says where, and runs nothing" lock_cannot_be_taken
