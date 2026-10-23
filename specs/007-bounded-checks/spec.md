# Feature Specification: Bounded checks

**Feature Branch**: `007-bounded-checks`

**Created**: 2026-10-22

**Status**: Draft

**Input**: User description: "Bounded checks: a per-section time budget, per-section durations, and a written verification policy (feature 007, directory specs/007-bounded-checks, built on 006's run lock)." As decided with the owner on 2026-10-22: each section may declare its own time budget in a header line shaped like `# covers:`, else a default derived from measured durations; a section over its budget is stopped with everything it started and fails the run, naming the section and the time; every run reports each section's wall time and the slowest at the end; the verification policy — iterate on `--staged` or one section, one full run when a story or commit closes, never repeated full suites to prove stability — is written in the project CLAUDE.md "Commands" and `docs/checks.md` "Tiers".

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A section that runs too long is stopped and fails the run (Priority: P1)

A section hangs or slows far past what it normally takes. Instead of the run
waiting on it without end — and, since feature 006, every run queued behind it
in other worktrees waiting too — the section is stopped when it exceeds its
time budget, together with every process it started, and the run fails with a
line naming the section, its budget and the time it ran. The other sections'
results are unaffected and the run ends with its verdict.

**Why this priority**: observed 2026-10-22: runs hung for minutes at about 1%
CPU — a lock test waiting on a lock it should never have reached — and nothing
bounded them. With 006's one-run-at-a-time lock, which waits with no timeout,
a hung section in one worktree holds up every run in every other worktree
until someone notices. A bound on each section is what makes the lock's
unbounded wait safe.

**Independent Test**: in a scratch repository, a section that sleeps past a
small declared budget and starts a background child; run the suite and see it
end shortly after the budget, the section reported as over budget with its
budget and elapsed time, no process the section started still alive, and the
other sections' output and verdicts as without it.

**Acceptance Scenarios**:

1. **Given** a section that declares a budget and runs past it, **When** the
   suite runs, **Then** the section is stopped no later than its budget plus
   the grace period (FR-004), the run fails, and the section's place in the
   output holds what it printed before it was stopped followed by one line
   naming the section, its budget and its elapsed time.
2. **Given** a section over its budget that started child processes, including
   one whose own parent has already exited, **When** it is stopped, **Then**
   none of the processes it started is still running once the run has ended.
3. **Given** a section that declares no budget, **When** it runs past the
   default budget, **Then** it is stopped and reported the same way.
4. **Given** a section that finishes within its budget, **When** the suite
   runs, **Then** its result is exactly what it was before this feature.
5. **Given** one section over its budget and the others passing, **When** the
   run ends, **Then** every other section's output is shown whole and in file
   order, the verdict is "Some checks failed" and the exit status is 1 — by
   hand, under `--strict`, under `--staged` and in CI alike.
6. **Given** a run waiting for the run lock (006) behind a run whose section
   hangs, **When** that section exceeds its budget, **Then** the holder's run
   ends and the waiting run gets its turn: no hang in one run holds another
   indefinitely.
7. **Given** a section whose declared budget is not a valid budget (not a
   positive whole number of seconds, or declared twice), **When** that section
   is selected, **Then** the run fails naming the section and the declaration,
   without running it.

---

### User Story 2 - Every run shows what each section cost (Priority: P2)

Every run — by hand, in the hook, in CI — reports each section's wall time
beside its output, and at the end names the slowest sections with their
times, so a section getting slower is seen in the run where it happens rather
than discovered hours later as a hot laptop.

**Why this priority**: on 2026-10-22 nobody could see what each section cost;
the full run's ~105 s floor (set by the routed end-to-end section, about 70 s
alone; a hook run selecting it took 77 s, a docs-only one 4.9 s) was found by
timing sections by hand. Durations are also the measurements the default
budget is derived from and re-checked against.

**Independent Test**: run a scratch suite of sections with known sleeps; each
section's reported time is within a small tolerance of its sleep, the end of
the run names the slowest in descending order, and the output is otherwise in
file order as before.

**Acceptance Scenarios**:

1. **Given** any run, **When** a section finishes, passing, failing or
   stopped, **Then** its wall time appears with its output, in its place in
   file order.
2. **Given** any run, **When** it ends, **Then** before the verdict it lists
   the three slowest sections that ran (fewer when fewer ran), slowest first,
   with their times.
3. **Given** sections finishing in a different order than file order, **When**
   the run prints, **Then** the output is still in file order, as 004
   guarantees; only the time values differ from run to run.
4. **Given** a `--staged` run, **When** sections are not selected, **Then** no
   time is reported for them and they do not appear among the slowest.

---

### User Story 3 - Everyone verifies the same way, and the machine stays cool (Priority: P2)

An agent or the owner working on a change iterates with `./check.sh --staged`
or the sections it names (`./check.sh checks/91-sdd-routing.sh`, FR-014), runs
the full suite once when a story or a commit closes, and
never repeats full suites to prove that something is stable; a check that
needs repetition to prove stability repeats inside itself. The rule is written
where every agent and person reads it: the project CLAUDE.md "Commands" and
`docs/checks.md` "Tiers", which stays the one place that says how much runs
when.

**Why this priority**: on 2026-10-22 agents repeated full suites — one task
list asked for five in a row — and the laptop ran hot for hours. 006 makes
those runs queue instead of overlap, which cools the machine but makes each
repetition cost every other worktree its wait.

**Independent Test**: read the project CLAUDE.md "Commands" and
`docs/checks.md` "Tiers": both state the three rules, they do not contradict,
and the CLAUDE.md lines point to "Tiers" for the full statement.

**Acceptance Scenarios**:

1. **Given** the project CLAUDE.md, **When** an agent loads it, **Then**
   "Commands" says: iterate with `--staged` or one section; one full run when
   a story or commit closes; never repeat full suites to prove stability; and
   points to `docs/checks.md` "Tiers".
2. **Given** `docs/checks.md` "Tiers", **When** read, **Then** it states the
   same policy in full, beside the table of what runs when, with why: the
   evidence of 2026-10-22, and that repetition belongs inside the check that
   needs it.

---

### Edge Cases

- A section that finishes at the moment its budget expires: if it wrote its
  last line before it was stopped it counts as finished; otherwise it counts
  as over budget. It is never both.
- The budget clock starts when the section starts, not when the run starts:
  time spent waiting for 006's lock or for a free CPU slot does not count.
- A section that ignores the polite stop (traps or ignores TERM): after the
  grace period it is stopped forcibly; the run still ends.
- A section that hands work to a long-lived service outside its process tree
  (a container runtime's daemon, launchd): that work is outside what stopping
  the section can reach; the grace period exists so the section's own
  clean-up can release it.
- A section that runs nested copies of `check.sh` (`checks/05-runner.sh`): the
  nested runs and their sections are processes the section started, stopped
  with it; the nested runs apply budgets of their own to their own sections.
- The machine is busy with work other than checks (006 rules out other
  suites): budgets carry enough headroom over measured durations that a
  healthy section does not trip them on this machine or on the CI runner.
- INT or TERM to the runner while a section is running: stops every section
  as 004 does; no budget line is printed for a section stopped that way.
- A section that prints nothing and passes: its place shows only its time.
- A section over budget in a run where every other section passed: the run
  still fails; a budget is not a skip and does not depend on `--strict`.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A section MAY declare its time budget in a line of its own in
  the section file, `# budget: <seconds>`, a positive whole number of seconds,
  in the shape of its `# covers:` lines; at most one such line per section.
- **FR-002**: A section without a budget declaration MUST get a default
  budget, one value for all such sections, derived in the plan from measured
  section durations on this machine and on the CI runner, with the
  measurements and the headroom recorded in research.md.
- **FR-003**: A budget declaration that is not a positive whole number of
  seconds, or a second one in the same section, MUST fail the run when that
  section is selected, naming the section and the declaration, without running
  that section.
- **FR-004**: A section still running when its budget has elapsed, counted from
  the moment the section starts, MUST be stopped: first given a short grace
  period, the same for every section and fixed by the plan, to run its own
  clean-up, then forcibly. Stopping MUST reach every process the section
  started that stays in the section's process group, including processes whose
  parent has exited, so none of those outlives the run. A process that makes
  its own session or group (`setsid`, a pty child, `set -m` inside a section)
  is outside any group signal; the sections that start such processes
  (`05-runner`, `06-lock`) stop their own children, and the contract names the
  limit (settled with the owner, 2026-10-22: the limit is POSIX's, not a gap
  to engineer around). Settled with the owner (2026-10-22): this stays a requirement, not a
  goal. 004's parent-pid walk cannot reach a reparented process, and 004
  rejected `set -m` because a section in its own group lost ^C and stopped on
  reading stdin (SIGTTIN). The plan researches a process group per section
  without job control, with the section's stdin from /dev/null and the
  runner's INT/TERM traps signalling each group, and records the evidence.
- **FR-005**: A section stopped for its budget MUST count as failed in every
  mode — by hand, `--strict`, `--staged`, CI — and its place in the output MUST
  show what it printed before it was stopped followed by one line naming the
  section, its budget and its elapsed time.
- **FR-006**: A section stopped for its budget MUST NOT change any other
  section's execution, output or result, nor the order in which output is
  printed; the run MUST then end with its verdict as usual, releasing 006's
  run lock as any ending run does.
- **FR-007**: Every run MUST report the wall time of each section it ran, with
  that section's output and in its place, for sections that pass, fail, stop
  early or are stopped for their budget.
- **FR-008**: Every run MUST list, before its verdict, the three slowest
  sections it ran (fewer if fewer ran), slowest first, with their times.
- **FR-009**: Apart from the reported times and the lines FR-005 and FR-008
  add, a run's output, verdict and exit status MUST be those of the same run
  before this feature (004's ordering and verdict guarantees, 006's waiting
  line).
- **FR-010**: The project CLAUDE.md "Commands" and `docs/checks.md` "Tiers"
  MUST state the verification policy: iterate with `./check.sh --staged` or one
  section; one full run when a story or a commit closes; never repeat full
  suites to prove stability — repetition belongs inside the check that needs
  it. "Tiers" holds the full statement with its reasons; "Commands" states it
  briefly and points there; they MUST NOT contradict each other.
- **FR-011**: `docs/checks.md` "How a run executes" MUST state the budget rule
  (declaration, default, what happens past it, that it fails in every mode),
  the durations report, and the default's value with where it was measured.
- **FR-012**: Every behaviour above with logic of its own — reading a budget,
  the default, stopping a section and what it started, the over-budget line
  and verdict, the durations and the slowest list — MUST have a check that
  drives it against scratch fixtures and was seen to fail with that behaviour
  broken by hand (constitution III), the red runs named in the commit message.
- **FR-013**: The suite MUST behave the same in CI as on this machine: the same
  budgets, the same stop, the same failure, the same report.
- **FR-014**: `check.sh` MUST accept section paths as arguments
  (`./check.sh [--strict] checks/91-sdd-routing.sh ...`) and run only those,
  with the same runner, helpers, budgets, lock (006) and report as any run; a
  path that is not a section is a usage error, reported before any wait.
  `--staged` and named sections together are a usage error. Observed
  2026-10-22: every agent that iterated on a section wrote its own scratch
  runner to source one section (run-section.sh, drive.sh, run1.sh), each a
  copy of the runner's setup that could drift from it, and one ran outside the
  lock.

### Key Entities

- **Section**: as in 004 — a file directly in `checks/` ending in `.sh`, run by
  `check.sh` in a shell of its own.
- **Budget**: the longest a section may run, in whole seconds; declared in the
  section file or, absent, the default.
- **Default budget**: the single budget of every section that declares none;
  derived from measured durations, recorded with its measurements.
- **Duration**: a section's wall time in one run, from its start to its end or
  to its stop.
- **Verification policy**: how much of the suite to run when, for agents and
  people alike; stated in "Tiers" and summarised in the project CLAUDE.md.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A section that never ends, with a 2 s budget, makes the run end
  within its budget plus the grace period plus 2 s, every time the check
  drives it; nothing it started is running afterwards.
- **SC-002**: On this machine and in CI, five consecutive full runs of the
  unchanged suite trip no budget (measured once when the defaults are set and
  recorded in research.md; this is the one place repetition is the point).
- **SC-003**: For fixture sections of known length (sleeps of 1, 2 and 3 s),
  the reported times are within 0.5 s of those lengths and the slowest list
  names them 3, 2, 1.
- **SC-004**: The run's total wall time, with no section over budget, is no
  more than 1 s above the same run before this feature, measured before and
  after on this machine and recorded in research.md.
- **SC-005**: Both documents state the three rules of the verification policy
  and a reader finds no contradiction between them (reviewer check).

## Assumptions

- Exceeding a budget is a failure everywhere, as the owner directed (a budget
  as in a CI performance budget). A warning by hand was considered and
  rejected: the section has to be stopped either way for the run to end and
  release 006's lock, a stopped section has not finished its checks, and a run
  whose checks did not finish must not read as passed — the same reasoning as
  strict mode for a skip, without the exemption, since there is no tool to
  install that would make the run complete.
- No override of a budget from the command line or the environment: a section
  that needs more time gets a larger declared budget in a reviewed commit.
- Durations are reported on every run; no separate flag.
- "The three slowest" is a fixed number chosen here (not given by the owner);
  it is enough to see the floor and what is next to it.
- The default budget and every declared budget are seconds of wall time, not
  CPU time: the hangs observed were idle waits at about 1% CPU.
- 006's lock is in place underneath: a run's sections do not compete with
  another suite's, so durations measure the section, not contention between
  suites.
- Out of scope: a budget for the whole run (the per-section budgets bound it),
  budgets for single checks inside a section, and the global
  `claude/CLAUDE.md` (the policy is this repository's; whether to generalise
  it is the owner's call).
- Rejected, as decided with the owner on 2026-10-22 (research.md will carry
  them): moving check 96 out of the hook to CI only — 004's selection already
  runs it only when what it drives changes, and then it is the check that must
  run before that commit; fixed global timeouts without a per-section
  declaration — one slow, legitimate section would force a loose bound on all.
- Constraints: macOS, bash 3.2, no new dependency unless the platform lacks
  the primitive (macOS ships no `timeout`; the plan chooses how to bound a
  section).
