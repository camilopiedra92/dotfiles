# Implementation Plan: Bounded checks

**Branch**: `007-bounded-checks` | **Date**: 2026-10-22 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/007-bounded-checks/spec.md`

## Summary

Each section of `check.sh` runs as a background job in a process group of its
own, made by switching job control on only around the fork (`set -m; ...
& ...; set +m`), with stdin from `/dev/null` (research R1, R2). The runner's
existing 20 ms poll loop watches the sections still running: one past its
budget gets `TERM` to its whole group, a grace period, then `KILL`, which
reaches processes whose parent has exited (R1). The budget is the section's
`# budget: <seconds>` line or one default (R7). The same group stop replaces
004's parent-pid walk for INT and TERM (R3, R5). Every section's wall time is
measured in its own background subshell, in milliseconds, with the `perl`
macOS ships (R6), printed beside its output, and the three slowest are listed
before the verdict (R9). `check.sh` also takes section paths as arguments (R10).
The verification policy is written in the project CLAUDE.md "Commands" and
`docs/checks.md` "Tiers" (R11).

## Technical Context

**Language/Version**: bash 3.2.57 (the macOS `/bin/bash`, probed 2026-10-22,
macOS 27.0.1): no `wait -n`, no `EPOCHREALTIME`, no `coproc`

**Primary Dependencies**: `/usr/bin/perl` with `Time::HiRes` for the clock
(probed present 2026-10-22); `kill`, `ps`, `sleep`. Nothing added to a
manifest, no new tool (R6)

**Storage**: files in the run's scratch directory (`$RUN`): `N.start`, `N.end`
(epoch milliseconds), `N.failed`, `N.over`, beside 004's `N.out`, `N.rc`,
`N.done`

**Testing**: three new sections driving byte-identical scratch copies of
`check.sh` (`sections_repo` from `checks/lib/runner.sh`): `08-budget.sh`,
`09-durations.sh`, `11-named-sections.sh`; the adapted exact-output cases of
`05-runner.sh` and `06-lock.sh`

**Target Platform**: macOS (Apple Silicon); the CI runner is macOS too

**Project Type**: shell tooling

**Performance Goals**: no more than 1 s added to a run with no section over
budget (SC-004); a section that never ends stops within budget + grace + 2 s
(SC-001)

**Constraints**: output order, verdict and exit status as 004/006 apart from
the report lines (FR-009); INT/TERM still stop the run and everything it
started; ^C from a terminal still reaches the runner (R2)

**Scale/Scope**: `check.sh` (arguments, selection, one function pair, the poll
loop), three new sections, `checks/lib/runner.sh` (one helper), two edited
sections, `docs/checks.md`, the project `CLAUDE.md`

## Constitution Check

*GATE: before Phase 0, re-checked after Phase 1.*

- **I. Declared, never hand-installed**: perl is part of macOS, as `lockf` was
  for 006; nothing is installed. Pass.
- **II. One owner per layer**: no runtime, no Python package, no identity
  versioned. Pass.
- **III. One gate, seen red**: reading a budget, the default, the stop and what
  it reaches, the over-budget line and verdict, the durations, the slowest list
  and the named sections are logic of their own; each gets a case in
  `checks/08-budget.sh`, `09-durations.sh` or `11-named-sections.sh`, seen red
  with the behaviour broken by hand, the red runs named in the commit messages
  (tasks). Pass.
- **IV. Apply and report are twins**: not applicable; `check.sh` reports.
- **V. Upstream's files stay upstream's**: no vendored file is touched. Pass.
- **VI. The why beside the subject**: the launch window, the two graces, the
  integer-seconds comparison and the clock each carry their observation and
  date beside them in `check.sh`; `docs/checks.md` states the rules. The block
  comment at `kill_tree` ("not a process group: `set -m` gave each section its
  own group...") is rewritten, since this feature makes it false. Pass.

Post-design re-check: unchanged. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/007-bounded-checks/
├── spec.md
├── plan.md
├── research.md
├── quickstart.md
├── contracts/check-budget.md
├── checklists/requirements.md
└── tasks.md
```

No `data-model.md`: the section, budget, default budget and duration are the
spec's Key Entities; the files in `$RUN` are in the contract.

### Source Code (repository root)

```text
check.sh                    # + arguments (section paths), budget parsing, group launch and stop, timing, report
checks/lib/runner.sh        # + strip_report: removes the time lines and the slowest block from a captured run
checks/08-budget.sh         # new: declarations, default, the stop and what it reaches, verdict, lock, nested
checks/09-durations.sh      # new: reported times, slowest list, file order kept
checks/11-named-sections.sh # new: section paths as arguments
checks/05-runner.sh         # usage line; exact-output cases use strip_report
checks/06-lock.sh           # exact-output cases use strip_report
docs/checks.md              # "How a run executes": budget, durations; "Tiers": the policy
CLAUDE.md                   # "Commands": the policy, briefly
```

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| two grace constants (`GRACE` 5 s for a budget stop, `SIGNAL_GRACE` 2 s for INT/TERM) | a nested run stopped with its section must finish its own stop inside the outer grace, or its sections' groups survive the outer `KILL` (R5, probed) | one constant: the nested stop and the outer `KILL` would race at the boundary |
