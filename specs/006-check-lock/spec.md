# Feature Specification: One check suite at a time

**Feature Branch**: `006-check-lock`

**Created**: 2026-10-22

**Status**: Draft

**Input**: User description: "One ./check.sh suite runs at a time on this machine, across every worktree and clone. A second top-level invocation waits for the first to finish instead of competing, says so once (whose run it waits for: its pid and repository path), and then runs normally; its verdict and output are unaffected. A lock left by a process that died does not block anyone (stale detection by the holder's liveness, not by age). INT/TERM while waiting exits cleanly without taking the lock. The runner's own self-test, which runs check.sh copies nested inside a run, must not deadlock on the lock its parent holds; nested runs are part of the holder's run. CI (one run per runner) behaves as today."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Overlapping runs take turns (Priority: P1)

Several agents and the owner work in different worktrees and clones of this
repository at once, and each runs `./check.sh` — by hand, through the
pre-commit hook, or as part of a task. The second run to start does not compete
with the first: it says once that it is waiting, for which run (the holder's
process id and repository path), waits until that run has finished, and then
runs exactly as it would have alone.

**Why this priority**: observed 2026-10-22 on this laptop (an M4 Pro, 12
CPUs): several suites overlapped — three agents in different worktrees plus
another session's worktree — each fanning its sections over every CPU and some
driving container VMs. The machine ran hot for hours, and one section (the
routed end-to-end run, 96 on feature 003's branch) failed once under that
contention and passed alone. Nothing stops two suites from overlapping today.

**Independent Test**: start a run whose sections take a few seconds in one
scratch repository, start a second in another scratch repository while the
first is running, and see from the sections' own timestamps that no section of
the second started before the first run ended; the second said once whom it
was waiting for, and its output and exit status, apart from that line, equal
those of the same run made alone.

**Acceptance Scenarios**:

1. **Given** a run in progress in one repository, **When** a second run starts
   in another worktree or clone of it, **Then** the second runs none of its
   sections until the first has ended, and prints one line naming the first
   run's process id and repository path.
2. **Given** a second run that waited, **When** it then runs, **Then** its
   output, verdict and exit status are those of the same run made alone, apart
   from the one waiting line.
3. **Given** a second run started in the same repository as the first,
   **When** it starts, **Then** it waits just the same: the rule is per
   machine, not per repository.
4. **Given** no other run in progress, **When** a run starts, **Then** it
   starts at once and prints no waiting line.
5. **Given** three runs started while a fourth is in progress, **When** it
   ends, **Then** the waiting runs run one at a time, never two at once.

---

### User Story 2 - A dead run blocks nobody (Priority: P2)

A run that died without cleaning up — killed outright, its terminal closed,
the machine's power cut — leaves nothing that makes the next run wait. A run
is held up only by a run that is still alive.

**Why this priority**: a lock that outlives its holder turns a courtesy into an
outage: every commit in every worktree would hang until someone found and
removed it by hand.

**Independent Test**: start a run, kill it outright (no chance to clean up),
start another, and see it start at once without a waiting line; likewise when
a process the dead run's sections left behind is still alive.

**Acceptance Scenarios**:

1. **Given** a run killed outright while running, **When** a new run starts,
   **Then** it starts at once, without waiting.
2. **Given** a run that ended, normally or killed, but whose sections left a
   process running in the background, **When** a new run starts, **Then** it
   starts at once: what a section leaves behind is not the run.
3. **Given** whatever record an earlier run left on disk, however old, **When**
   no run is alive, **Then** a new run starts at once; age plays no part.

---

### User Story 3 - Waiting can be abandoned (Priority: P2)

The owner, or an agent's tool, stops a run that is still waiting — `^C` in a
terminal, or a TERM signal. It ends at once, having run nothing, and leaves the
turn to whoever comes next; the run it was waiting for is untouched.

**Why this priority**: a pre-commit hook waiting behind a long full run must
be cancellable, and a cancelled waiter that still took its turn would hold up
everyone after it.

**Independent Test**: while one run is in progress, start a second, send it
TERM (and `^C` through a terminal), and see it end with the status of that
signal, having run no section; the first run ends normally; a third run started
after the first ended starts at once.

**Acceptance Scenarios**:

1. **Given** a run waiting for another, **When** it receives TERM, **Then** it
   ends at once with status 143, runs no section, and the run it waited for
   carries on unaffected.
2. **Given** a run waiting for another, started from a terminal, **When** the
   owner presses `^C`, **Then** it ends at once with status 130 and runs no
   section.
3. **Given** a waiter that was stopped, **When** the run it was waiting for
   ends, **Then** the next run starts at once: the stopped waiter never held
   the turn.

---

### User Story 4 - A run inside a run is part of it (Priority: P1)

The runner's own checks (`checks/05-runner.sh`) start copies of `check.sh`
from inside a run, and so may any section. Those nested runs are part of the
run that started them: they neither wait for it nor block a run elsewhere any
longer than their parent does.

**Why this priority**: without it the suite deadlocks on itself: the parent
holds the turn and waits for a section that waits for the parent.

**Independent Test**: run the suite whose section starts a nested copy of
`check.sh`; it completes, with no waiting line from the nested copy.

**Acceptance Scenarios**:

1. **Given** a run whose section starts another `check.sh`, **When** the
   nested run starts, **Then** it runs at once, without waiting and without a
   waiting line, and the outer run completes.
2. **Given** the repository's own suite, **When** it runs in full, **Then**
   `checks/05-runner.sh` passes, as today.

---

### Edge Cases

- CI: one run per runner, so the turn is always free and a CI run behaves as
  today, without a waiting line.
- A usage error (an unknown flag) is reported at once, without waiting for
  another run.
- The place where the turn is recorded cannot be written (permissions, a full
  disk): the run says so, naming the place, and fails, as a run that cannot
  make its scratch directory does today; it does not run unguarded in silence.
- The record of the turn lives in a per-user temporary location that macOS may
  clear: a cleared record means no run is alive to hold it, so the next run
  starts at once.
- A run that waited a long time: there is no timeout; it waits as long as the
  run ahead of it takes, and the owner can abandon it (User Story 3).
- Waiting runs are not ordered: when the turn frees, any one of them may take
  it next.
- The waiting line names a run whose process id and path are those the holder
  recorded; if the holder has taken the turn but not yet recorded itself, the
  line still says the run is waiting, without the details it does not have.
- A process the owner starts by hand from inside a section's environment is
  treated as nested: what makes a run nested is being started from within a
  run.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: At most one top-level `check.sh` run per user MUST execute its
  sections at a time on this machine, whichever worktree or clone of the
  repository it was started in, and whichever mode (`--staged`, `--strict`, or
  neither).
- **FR-002**: A top-level run that finds another in progress MUST wait for it
  to end before running anything else, MUST print exactly one line saying it
  is waiting and for whom (the holder's process id and repository path), on
  standard error, and MUST then run as it would have alone.
- **FR-003**: Apart from that one line, a run that waited MUST produce the same
  output, verdict and exit status as the same run made alone.
- **FR-004**: The turn MUST be held only while the run that took it is alive:
  a run that dies by any means, including SIGKILL, frees it with no clean-up
  step and no timeout; a process a section leaves running MUST NOT keep it.
- **FR-005**: A waiting run that receives INT or TERM MUST end at once with
  status 130 or 143, MUST NOT run any section, and MUST NOT take the turn.
- **FR-006**: A `check.sh` run started from within a run MUST run at once as
  part of it, neither waiting for nor printing a waiting line.
- **FR-007**: A run that cannot record its turn for any reason other than
  another run holding it MUST say so, naming the location, and exit non-zero
  without running any section.
- **FR-008**: The argument check MUST happen before the wait, so a usage error
  never waits.
- **FR-009**: `docs/checks.md`, section "How a run executes", MUST state the
  rule: one run at a time per machine, what a second run does, what frees the
  turn, and that nested runs are part of their parent.
- **FR-010**: Every behaviour above with logic of its own MUST have a check
  that drives overlapping runs against scratch fixtures and was seen to fail
  with the behaviour broken by hand (constitution III).

### Key Entities

- **Run**: one invocation of `check.sh` and everything it starts; top-level
  when not started from within another run.
- **Turn**: the right to execute sections, held by at most one top-level run
  per user at a time, released when its holder ends.
- **Holder record**: the holder's process id and repository path, kept beside
  the turn so a waiter can say whom it waits for; informative only, never what
  decides whether the turn is held.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With two, three and four runs started within one second of each
  other in different scratch repositories, the sections' recorded start and end
  times never overlap across runs, in every repetition of the check.
- **SC-002**: A run started after another was killed outright starts within
  one second, with no waiting line, every time.
- **SC-003**: A waiting run sent TERM ends within one second with status 143,
  having run nothing.
- **SC-004**: A run with no other in progress takes no measurably longer than
  before the feature (under 0.1 s added, measured before and after on this
  machine, recorded in research.md).
- **SC-005**: The repository's full suite, run alone, passes as it does today,
  its nested runs included.

## Assumptions

- One user's runs are the contention that matters: the turn is per user. Runs
  by other macOS users of the same machine are not coordinated; this machine
  has one.
- The lock is a courtesy to the machine, not a correctness guarantee for the
  checks: sections already run in scratch directories of their own, so two
  overlapping runs were never wrong, only slow and contended.
- The pre-commit hook waiting behind a long full run in another worktree is
  accepted: waiting is what the owner chose over competing.
- CI runs one suite per runner, so the feature changes nothing there.
- Rejected, as decided with the owner on 2026-10-22 (research.md has why):
  capping the number of sections a run executes at once, running sections at
  background priority, and one lock per repository.
