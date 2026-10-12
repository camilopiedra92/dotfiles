# Feature Specification: The commit gate judges the commit

**Feature Branch**: `002-gate-judges-commit`

**Created**: 2026-10-12

**Status**: Draft

**Input**: User description: the pre-commit hook runs `./check.sh` against the
working tree, so its verdict is about files that may differ from what is being
committed: an unstaged edit can refuse a good commit, and a bad staged change
can pass behind a clean working copy. Make the gate judge exactly the commit,
without touching the working tree.

## User Scenarios & Testing *(mandatory)*

The user is the maintainer committing to this repository with work in
progress around the commit: unstaged edits, untracked files, partial staging.

### User Story 1 - The verdict is about the commit (Priority: P1)

**Why this priority**: a gate that judges something other than the commit
both blocks good commits and lets bad ones land, which is the one thing it
exists to prevent; CI catches the second only after the commit exists.

**Independent Test**: in a scratch clone, stage a change the checks reject and
leave the working copy clean on top: the commit is refused. Then stage a good
change with a rejected edit left unstaged: the commit lands. Observed on
2026-10-12 with today's hook: the first lands and the second is refused.

**Acceptance Scenarios**:

1. **Given** a staged change the checks reject and an unstaged edit that
   undoes it, **When** committing, **Then** the commit is refused.
2. **Given** a staged change the checks accept and an unstaged edit they
   reject, **When** committing, **Then** the commit lands.
3. **Given** an untracked file the checks would reject, **When** committing
   anything else, **Then** the file does not affect the verdict.
4. **Given** `git commit -a` or `git commit <paths>`, which hand the hook an
   index of their own, **When** committing, **Then** the verdict is about that
   index's content.
5. **Given** a commit from a linked worktree, **When** committing, **Then** the
   verdict is about that worktree's commit.

---

### User Story 2 - The working tree is left exactly as it was (Priority: P1)

**Why this priority**: a gate that rewrites the working tree to judge the
commit (stash, checkout, restore) can lose work when it is interrupted or a
restore conflicts, and makes editors reload files.

**Independent Test**: record the working tree's files, their modification
times, untracked files and the stash list; commit; compare.

**Acceptance Scenarios**:

1. **Given** unstaged edits and untracked files, **When** the gate runs,
   whether it passes or refuses, **Then** every file's content and
   modification time, the untracked files and the stash list are unchanged.
2. **Given** a gate run that passes, refuses, or is interrupted, **When** it
   ends, **Then** nothing it created is left behind: no extra worktree
   registered with git, no directory in the temp folder.

---

### Edge Cases

- The gate's own output still shows what failed, and the bypass is still
  `git commit --no-verify`.
- Strict mode is unchanged: a missing tool fails the gate.
- A run takes about as long as today's (the spike measured 31-35 s for both).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pre-commit gate MUST run the checks against a tree holding
  exactly the content of the index git hands the hook, and nothing else.
- **FR-002**: The gate MUST NOT write to the user's working tree, index, stash
  or refs.
- **FR-003**: The gate MUST remove whatever it creates on every exit path,
  including interruption.
- **FR-004**: Machinery that existed only so the checks could read the
  commit's index from the working tree MUST be removed once nothing needs it.
- **FR-005**: Each behaviour above MUST have a check in `checks/` seen red
  with the behaviour broken by hand (constitution III).

### Key Entities

- **Commit index**: the index git hands the hook (`GIT_INDEX_FILE`); the
  content being committed.
- **Judging tree**: a temporary checkout of the commit index, where the
  checks run.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All seven acceptance scenarios hold, each guarded by a check
  seen red.
- **SC-002**: After any gate run, `git worktree list`, `git stash list`, the
  working tree and the temp folder are as before.
- **SC-003**: A commit through the gate takes no more than 5 s longer than
  today's.

## Assumptions

- `git worktree` (available since git 2.5) is the mechanism; the spike
  observed it judging the commit in both directions on git 2.56.
- Checks that read machine state outside the repository (installed tool
  versions, `~/.claude` wiring) keep reading the machine; only the
  repository's content comes from the commit.
- Running `./check.sh` by hand keeps judging the working tree, which is what
  a person running it by hand is looking at.
