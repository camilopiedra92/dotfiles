# Feature Specification: Checks for the scripts with logic and no check

**Feature Branch**: `001-script-checks`

**Created**: 2026-10-12

**Status**: Draft

**Input**: User description: "Checks in checks/ for the scripts that have
logic of their own and none yet (constitution principle III): githooks/pre-push,
bump-tools.sh and bin/dev-nuke.sh." Widened to githooks/pre-commit by the
review of constitution 2.0.0 (#143), which classes it as logic of its own. Each check drives the script against scratch
fixtures, never against the real machine, the network or the real remote, and
each is seen red with the behaviour broken by hand."

## User Scenarios & Testing *(mandatory)*

The user is the maintainer of this repository, changing one of these four
scripts. Today a change that breaks any of them passes the gate every commit
runs, and is found only when the script is next needed — after a bad push has
reached the remote, a pin has been moved without its checksum, or a reset has
killed the wrong process.

### User Story 1 - A broken push guard fails the gate (Priority: P1)

The maintainer changes the push guard. If the change stops it refusing a
deletion or a rewrite of the protected branch, or starts refusing ordinary
pushes, the gate fails and names which case broke.

**Why this priority**: the push guard protects the branch every other change
lands on; it is the one script whose failure is silent until the damage is on
the remote.

**Independent Test**: run the gate with only this story's check in place, once
against the guard as it is (passes) and once against a guard edited to allow a
deletion (fails naming the deletion case).

**Acceptance Scenarios**:

1. **Given** a push that deletes the protected branch, **When** the guard runs,
   **Then** it refuses and says the branch would be deleted.
2. **Given** a push to the protected branch whose remote tip is not an ancestor
   of what is sent, **When** the guard runs, **Then** it refuses and names both
   commits.
3. **Given** a fast-forward push to the protected branch, **When** the guard
   runs, **Then** it allows it.
4. **Given** the protected branch does not yet exist on the remote, **When** it
   is pushed, **Then** the guard allows it.
5. **Given** a rewrite or deletion of a branch other than the protected one,
   **When** the guard runs, **Then** it allows it.
6. **Given** the remote's default branch is not `main`, **When** that branch is
   rewritten, **Then** the guard refuses; **Given** the remote's default branch
   is unknown, **Then** `main` is protected.
7. **Given** any refusal, **Then** the guard prints how to push deliberately
   past it; **Given** an allowed push, **Then** it prints nothing.
8. **Given** a push of several refs at once where only one is refused, **Then**
   the whole push is refused.

---

### User Story 2 - A broken commit gate fails the gate (Priority: P2)

The maintainer changes the pre-commit hook. If the change lets a commit
through when the checks fail, or runs the checks in their lenient mode, where
a missing tool is skipped rather than failed, the gate fails and names the
case.

**Why this priority**: the hook is what stops a failing change before it is
committed; a hook that passes everything looks the same as one that works.

**Independent Test**: run this story's check against the hook as it is
(passes) and against a hook edited to drop the strict option (fails naming
it).

**Acceptance Scenarios**:

1. **Given** the checks fail, **When** a commit is attempted, **Then** the
   hook refuses it and says how to bypass deliberately.
2. **Given** the checks pass, **When** a commit is attempted, **Then** it
   lands.
3. **Given** any commit, **Then** the hook runs the checks of the repository
   being committed to, in strict mode.

---

### User Story 3 - A broken pin updater fails the gate (Priority: P3)

The maintainer changes the tool that moves the CI tool pins. If the change lets
a pin move without its checksum, move backwards, or move to a version whose
artifact cannot be downloaded, the gate fails and names the case.

**Why this priority**: a pin and checksum that disagree fail CI for every pull
request until fixed by hand; a pin moved backwards silently drops fixes.

**Independent Test**: run this story's check against the updater as it is
(passes) and against an updater edited to skip the checksum rewrite (fails).

**Acceptance Scenarios**:

1. **Given** a tool with a newer upstream release whose artifact downloads,
   **When** the updater runs, **Then** the pin and that tool's checksum line
   both change, to the new version and the downloaded artifact's hash, and
   nothing else in either file changes.
2. **Given** every tool already at its latest release, **When** the updater
   runs, **Then** both files are byte-for-byte unchanged and it says so.
3. **Given** upstream reports a version older than the pin, **Then** the
   updater refuses and leaves both files unchanged.
4. **Given** a newer version whose artifact cannot be downloaded, **Then** the
   updater refuses and leaves both files unchanged.
5. **Given** the checksum file has no line for the currently pinned artifact,
   **Then** the updater refuses and leaves both files unchanged.
6. **Given** a run that moves one tool and then fails on a later one, **Then**
   every tool it did move has its pin and checksum in agreement, and the tool
   it failed on is untouched.
7. **Given** the tool whose pin is spelled with a leading `v` and one spelled
   without, **When** each moves, **Then** each keeps its own spelling.

---

### User Story 4 - A broken machine reset fails the gate (Priority: P4)

The maintainer changes the reset script. If the change lets it run without
root, act on another user's processes, kill a process it only had to ask to
stop, or delete files other than the stale database socket, the gate fails.

**Why this priority**: the reset is run rarely and by hand, so a regression
costs less often — but when it does, it kills or deletes the wrong thing.

**Independent Test**: run this story's check against the reset as it is
(passes) and against a reset edited to send KILL first (fails naming the
escalation case).

**Acceptance Scenarios**:

1. **Given** the reset is run without root, **Then** it refuses before acting
   on anything.
2. **Given** some of the listed apps are running, **Then** only those are asked
   to quit, as the invoking user.
3. **Given** matching dev-server processes of the invoking user, **Then** they
   are sent TERM first, and KILL goes only to those still running after the
   grace period.
4. **Given** matching processes that belong to another user, **Then** they are
   not signalled.
5. **Given** a stale database socket at its exact path, **Then** it is removed,
   and nothing else in that directory is.
6. **Given** any command the reset runs on the user's behalf (quitting apps,
   stopping services, writing its log, the final notification), **Then** it
   runs as the invoking user, not as root.

---

### Edge Cases

- A check must never act on the real machine, the network or the real remote:
  a check that would reach one of them when the script under test is broken
  is itself a defect.
- The gate runs on a laptop and on a CI runner; each check means the same on
  both, and does not depend on what is installed or running on either.
- A check that cannot set up its fixtures fails; it never reads as a pass.
- The updater's grace delay and the reset's grace period must not make the
  gate measurably slower (see SC-003).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The gate MUST include one check per script — the push guard, the
  commit gate, the pin updater and the machine reset — each covering every
  acceptance scenario of its story.
- **FR-002**: Each check MUST drive the real script, unmodified, against
  scratch fixtures; it MUST NOT reach the real remote, the network, real
  processes, real sockets, the DNS cache, memory, or files outside its scratch
  directory.
- **FR-003**: Each check MUST, on failure, name the scenario that failed.
- **FR-004**: Each check MUST have been seen to fail with the behaviour it
  guards broken by hand, once per acceptance scenario, before it is trusted;
  the pull request records those runs.
- **FR-005**: A script MAY gain a way to point it at fixtures (for example, a
  path it acts on) only where the check cannot otherwise avoid the real
  machine; such a change MUST leave the script's behaviour for its normal
  invocation unchanged, and is the only change to the scripts.
- **FR-006**: The checks MUST run under the same shell, lint and format rules
  as the rest of the gate, and add no dependency.

### Key Entities

- **Push guard**: refuses deleting or rewriting the protected branch; reads the
  pushed refs, decides per ref, refuses the push if any ref is refused.
- **Commit gate**: runs the repository's checks in strict mode before each
  commit and refuses the commit when they fail.
- **Pin updater**: for each CI tool, compares the pinned version with
  upstream's latest and moves the pin and its checksum line together.
- **Machine reset**: run as root on the user's behalf; quits apps, stops
  orphaned dev servers, stops services, removes a stale socket, flushes DNS,
  purges memory.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every acceptance scenario above (8 + 3 + 7 + 6) is covered by a
  check, and for each one a hand-broken script made the gate fail naming it.
- **SC-002**: The gate passes on a laptop and on CI with no network access
  needed by these checks and nothing on the machine changed by them (no
  process signalled, no file written outside a scratch directory).
- **SC-003**: The four checks together add under 10 seconds to a full gate
  run.
- **SC-004**: All four scripts are named by a check, so principle III holds
  for every script with logic of its own.

## Assumptions

- Principle III as amended in constitution 2.0.0 (#143): `bin/aware.sh` is a
  wrapper and needs no check; these four are the only scripts with logic and
  none.
- The reset's DNS flush and memory purge have no logic of their own (they run
  unconditionally); the check confirms they are invoked, not what they do.
- The pin updater's per-tool tables (URLs, artifact names, env var names) are
  data mirrored from CI; checking them against CI is out of scope, since CI's
  own verification already refuses an artifact with no checksum line.
- Making the pre-commit hook judge the commit rather than the working tree is
  a separate feature.
