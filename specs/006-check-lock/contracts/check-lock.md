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
6. The lock is released when the runner process ends, by any means.

## The lock

- File: `$(getconf DARWIN_USER_TEMP_DIR)dotfiles-check.lock`, per user.
  Its existence means nothing; only a live `flock(2)` on it does.
- Held by: the runner's own shell, on descriptor 9, and no other process
  once the sections start.
- Scope: every `check.sh` of this repository run by the user — any worktree,
  any clone, any flags.

## Standard error lines

- Waiting, once per run, before anything else is printed:
  - `check.sh: waiting for the run of pid <pid> in <path> to finish`, or
  - `check.sh: waiting for another run to finish` when the holder has not
    recorded itself yet.
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

## Environment

- `CHECK_SH_RUN`: set by a holder for everything it starts. A run that starts
  with it set is part of that run and takes no lock. Exporting it by hand
  bypasses the lock.
