# Implementation Plan: One check suite at a time

**Branch**: `006-check-lock` | **Date**: 2026-10-22 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/006-check-lock/spec.md`

## Summary

`check.sh` takes a per-user, machine-wide lock before it does anything else
but parse its arguments, so one top-level suite runs at a time across every
worktree and clone (research R1). The lock is `flock(2)` through the
`/usr/bin/lockf` that macOS ships, held on a descriptor only the runner's own
shell keeps open, in `getconf DARWIN_USER_TEMP_DIR` (R2, R6): the kernel
releases it when the runner dies by any means, so a dead run blocks nobody
and nothing a section leaves behind holds it (R5). A second run says once
whom it waits for, from a record the holder writes into the lock file (R4),
waits interruptibly (R3), then runs as it would have alone. Runs started from
inside a run see `CHECK_SH_RUN` and skip the lock (R5). A new section,
`checks/06-lock.sh`, drives overlapping scratch runs (R8);
`docs/checks.md` "How a run executes" gets the rule.

## Technical Context

**Language/Version**: bash 3.2.57, the macOS `/bin/bash` (`bash --version`,
2026-10-22): no `{var}>` descriptor allocation, so a fixed descriptor number;
no `wait -n`

**Primary Dependencies**: `/usr/bin/lockf` and `getconf`, both in macOS's
base system (`ls /usr/bin/lockf`, `getconf DARWIN_USER_TEMP_DIR`, 2026-10-22);
no new tool, nothing added to a manifest

**Storage**: one lock file per user, `dotfiles-check.lock` in the per-user
temporary directory, holding one informative line `<pid> <repository path>`

**Testing**: the repository's own `check.sh`; the new section
`checks/06-lock.sh` runs scratch copies of `check.sh` side by side in scratch
repositories, against a stub `getconf` naming a scratch lock directory;
`checks/05-runner.sh` passing unchanged under the lock proves nested runs

**Target Platform**: macOS (Apple Silicon), as the rest of the repository;
the CI runner is macOS too

**Project Type**: shell tooling

**Performance Goals**: a run with no other in progress adds under 0.1 s
(spec SC-004); a run after a dead holder starts within one second (SC-002)

**Constraints**: output, verdict and exit status of a run that waited equal a
run made alone, apart from one stderr line (FR-003); no timeout; INT/TERM
while waiting end the run 130/143 without the turn (FR-005)

**Scale/Scope**: one script (`check.sh`), one new section, one helper moved
to `checks/lib/`, one documentation section

## Constitution Check

*GATE: before Phase 0, re-checked after Phase 1.*

- **I. Declared, never hand-installed**: nothing installed; `lockf` and
  `getconf` are part of macOS. Pass.
- **II. One owner per layer**: no runtime, no Python, nothing versioned that
  identifies anyone; the lock lives in the per-user temporary directory, which
  is runtime state, not configuration. Pass.
- **III. One gate, seen red**: the hook, CI and a person still run the same
  `check.sh`; the lock changes when sections run, never which or with what
  verdict. Taking the lock, waiting, abandoning the wait, the record, nested
  runs and the closed descriptor are logic of their own: each gets a case in
  `checks/06-lock.sh` seen red with that behaviour broken by hand, the red runs
  named in the commit message (tasks). Pass.
- **IV. Apply and report are twins**: not applicable; `check.sh` reports.
- **V. Upstream's files stay upstream's**: not applicable.
- **VI. The why beside the subject**: the lock's block in `check.sh` carries
  why `lockf` on a descriptor, why the sections close it, why `getconf` and
  not `TMPDIR`, and why the wait is a background job, with the dates they were
  observed; `docs/checks.md` states the rule. Pass.

Post-design re-check: unchanged. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/006-check-lock/
├── spec.md
├── plan.md
├── research.md
├── quickstart.md
├── contracts/check-lock.md
├── checklists/requirements.md
└── tasks.md
```

No `data-model.md`: the run, the turn and the holder record are defined in
the spec's Key Entities and the contract.

### Source Code (repository root)

```text
check.sh                 # + the lock: take, wait, record, CHECK_SH_RUN; sections close the descriptor
checks/lib/runner.sh     # new: sections_repo, moved from 05-runner (now used by two sections)
checks/05-runner.sh      # sections_repo removed (uses the shared one)
checks/06-lock.sh        # new: overlapping runs, dead holder, abandoned wait, nested run
docs/checks.md           # "How a run executes": one run at a time
```

## Complexity Tracking

None.
