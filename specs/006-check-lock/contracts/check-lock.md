# Contract: the run lock in `check.sh`

Extends `specs/004-fast-checks/contracts/check-cli.md`; invocation, flags,
selection and output there are unchanged.

## Order of a run

1. Arguments parsed; a usage error exits 2 at once, without the lock.
2. If `CHECK_SH_RUN` is set, the run is nested: steps 3–5 are skipped.
3. The lock is taken (below), waiting if another run holds it.
4. The holder writes `<pid> <repository path>` into the lock file and
   exports `CHECK_SH_RUN=<pid>`.
5. Selection, sections and verdict, as in 004. Every section's subshell
   closes the lock descriptor before running the section.
6. The runner empties the lock file as it exits through its EXIT trap,
   still holding the lock; the lock is released when the runner process
   ends, by any means.

## The lock

- File: `$(getconf DARWIN_USER_TEMP_DIR)dotfiles-check.lock`, per user.
  Its existence means nothing; only a live `flock(2)` on it does.
- Held by: the runner's own shell, on descriptor 9; no other process holds
  it. Each section's subshell closes it before the section runs, and every
  external command the runner starts after taking the turn (its 20 ms
  poll's `sleep`, `find`, `wc`, `cat`, `mktemp`, `sysctl`, `pgrep`, and
  under `--staged` `git`, `sed`, `rm`) is started with `9>&-`. So the lock
  is free the instant the runner ends, by any means (R2, R8), and git's
  fsmonitor daemon, which a run's git may start, does not keep it (probed
  2026-10-22: a shell holding the lock ran `git status` with
  `core.fsmonitor` on, the daemon started, and the lock was free once the
  shell exited). The one exception in time is the instant between a
  background section's fork and its first instruction, `exec 9>&-`, a
  fork of the runner's own shell and not a command it starts.
- Scope: every `check.sh` of this repository run by the user — any worktree,
  any clone, any flags.

## Standard error lines

- Waiting, once per run, before anything else is printed:
  - `check.sh: waiting for the run of pid <pid> in <path> to finish`, or
  - `check.sh: waiting for another run to finish` when the file holds no
    record, or one whose pid is no longer alive (a run killed outright).
- The lock cannot be opened or taken for a reason other than a holder:
  `check.sh: cannot take the run lock <file>`, exit 1, no section run.

Standard output is unchanged: a run that waited prints, on standard output,
exactly what the same run made alone prints.

## Exit statuses added

| situation | status |
|---|---|
| INT while waiting | 130, no section run, lock not taken |
| TERM while waiting | 143, no section run, lock not taken |
| lock cannot be opened or taken | 1 |

All others are 004's.

INT reaches a waiting run as a terminal's ^C, or as `kill -INT` to a run
an interactive shell started. A run started with `&` by a non-interactive
shell (a script, an agent's tool) ignores INT from its first instruction,
and bash cannot trap a signal ignored on entry: INT does nothing to it, and
TERM is what ends it (observed 2026-10-22, 06-lock's INT case without its
python launcher).

## Environment

- `CHECK_SH_RUN`: set by a holder for everything it starts. A run that starts
  with it set is part of that run and takes no lock. Exporting it by hand
  bypasses the lock.
