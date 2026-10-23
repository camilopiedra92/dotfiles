# Feature Specification: Extract the SDD routing harness into its own repository

**Feature Branch**: `008-extract-sdd-routing`
**Created**: 2026-10-23
**Status**: Draft
**Input**: Move the routed Spec Kit harness (`sdd-run`, `sdd-step`, `sdd-pass`,
the egress proxy, the routing table and schemas, the worker image recipe, their
checks and their 003 spec) out of dotfiles into the public repository
`camilopiedra92/sdd-routing`, keeping its history, before branch
`003-sdd-model-routing` merges. dotfiles keeps the wiring that puts the
harness on this machine.

## Why now (measured 2026-10-22/23)

The harness has outgrown the repository it was born in. Numbers, from branch
`003-sdd-model-routing` at `42f05e1` against `main` at `4f3bb6d`:

| | harness | everything else in dotfiles |
|---|---|---|
| scripts and code | 6,633 lines (`bin/sdd-*`, `containers/worker/`, `claude/speckit/`) | about 4,000 lines |
| checks | 5,640 lines (sections 91-96, `checks/sdd/`) | 6,127 lines |
| local suite (`./check.sh`) | 105-201 s with it | 12-17 s without it |
| CI | 355-567 s per push on the 003 branch | 36-51 s on `main` |
| spec | 3,000 lines of its own (`specs/003-sdd-model-routing/`) | 004, 006: a few hundred each |

dotfiles' constitution scopes the repository to "this machine's development
environment, declared as code". The harness is a product: a CLI, a workflow,
a container image recipe, ten JSON schemas, an egress proxy and a threat
model. It would make every later dotfiles change (007 and 009 among them) pay
a 10x suite and a 10x CI to prove nothing about the machine.

The new repository is public so its CI costs nothing (the owner does not pay
for GitHub Actions; a private repository's CI is already dead for that reason
in `ha-config`).

## User Scenarios & Testing

### User Story 1 - The harness lives and is checked on its own (Priority: P1)

`camilopiedra92/sdd-routing` holds every file the harness is made of, with the
history of those files, and its own `./check.sh` and CI run its sections green
without dotfiles being present.

**Why this priority**: nothing else can move until the new repository is
green by itself; it is the first of the two pull requests.

**Independent Test**: clone the new repository on a machine (or a CI runner)
that has no dotfiles checkout, run `./check.sh --strict`: every section runs
and passes, none skips.

**Acceptance Scenarios**:

1. **Given** the 003 branch's final tip, **When** the extraction runs, **Then**
   the new repository's history contains every commit that touched a moved
   path (renames included, `git log --follow claude/speckit/brief.md` shows
   the same commits as the source) and no commit that touched none.
2. **Given** a fresh clone with no `~/dotfiles`, **When** `./check.sh --strict`
   runs, **Then** it ends green and no section reads a path outside the
   clone.
3. **Given** the vendored runner or the vendored `config-guard.sh` is edited
   by hand, **When** the suite runs, **Then** it fails naming the file and the
   upstream commit it should equal.
4. **Given** the CI workflow on a pull request, **When** it runs, **Then** it
   runs the same `./check.sh` on a macOS runner and is a required check of the
   default branch.

---

### User Story 2 - dotfiles installs the harness at a pin (Priority: P2)

`./install.sh` on a machine puts `sdd-run` and `sdd-step` on `PATH` from a
tagged release of `sdd-routing`, declared in `uv-tools.txt`; `./drift.sh`
reports a missing, stale or unanswering install.

**Why this priority**: it is the second pull request and the only thing the
owner needs from dotfiles; it depends on a tag existing.

**Independent Test**: on a scratch `HOME`, `install.sh` links the commands and
`sdd-run` prints its usage; with the pin edited to a tag that does not exist,
`install.sh` fails naming it; `drift.sh` reports the install when the tool is
absent.

**Acceptance Scenarios**:

1. **Given** `uv-tools.txt` pins `sdd-routing` to a release tag, **When**
   `install.sh` runs twice, **Then** the second run changes nothing
   (constitution IV).
2. **Given** the installed `sdd-run`, **When** it starts a run, **Then** it
   finds its schemas, routing table, worker recipe and judge from its own
   location with no `~/dotfiles` on the machine (R28's frozen bundle is
   unchanged in layout).
3. **Given** upstream has released a newer tag, **When** `drift.sh` runs,
   **Then** it reports the pin as behind, as it does for `specify-cli`.
4. **Given** the installed command does not answer, **When** `drift.sh` runs,
   **Then** it reports it.

---

### User Story 3 - The old home is closed and its work follows (Priority: P3)

PR #155 and branch `003-sdd-model-routing` are closed with a pointer, dotfiles'
docs point at the new repository, and the open 003 tasks (US3, T049-T055)
continue there.

**Independent Test**: the PR is closed, its last comment links the new repo and
the tag; `README.md` links the new repository's README; no file in dotfiles
still names a path that moved.

**Acceptance Scenarios**:

1. **Given** the new repository is green and dotfiles' wiring PR is merged,
   **When** the old PR is closed, **Then** the branch is kept (not deleted)
   until the first routed run from the installed command has succeeded.
2. **Given** features 007 and 009, **When** they are specified, **Then** they
   concern dotfiles' runner and are untouched by this move.

### Edge Cases

- The 003 agent commits to the branch after the extraction ran: the extraction
  is repeatable from the final tip; a catch-up imports only the commits after
  the last imported one (plan, "Cut-over").
- A routed run is in progress while the installed harness is upgraded: its
  bundle holds a frozen copy of its code (R28), so the upgrade changes nothing
  in it.
- `uv tool` rebuilds its virtualenv on an interpreter change: the installed
  files move with it; the frozen bundle of a live run does not.
- The tag moves (force-pushed): the install changes without the pin changing.
  Mitigated by a tag-protection rule on the new repository and detected by
  `drift.sh` comparing the installed commit to the tag (R9).
- dotfiles' runner changes upstream: the new repository's vendored copy is
  behind until its owner runs the sync; the suite does not fail on that (only
  on hand edits), `./drift.sh` of the new repository reports it.

## Requirements

### Functional Requirements

- **FR-001**: Every path in `inventory.md` "Moves" MUST exist in the new
  repository at the same relative path (layout preserved, R4), and none MUST
  remain in dotfiles.
- **FR-002**: The new repository's history MUST be the source branch's history
  restricted to the moved paths, authors and dates intact, renames followed
  (R2). The extraction command and its dry-run counts are recorded in
  `research.md` R2.
- **FR-003**: The harness MUST be installable with one pinned line in
  dotfiles' `uv-tools.txt` and MUST resolve every file it reads from the
  location of its own files, never from `~/dotfiles` (R3).
- **FR-004**: The harness MUST get its write-judging logic from its own vendored
  copy of `claude/config-guard.sh`, byte-for-byte as dotfiles' at a recorded
  commit, with a check that fails on a hand edit and a report of the copy being
  behind (R5).
- **FR-005**: The new repository MUST run its sections with dotfiles' runner
  (`check.sh`, `checks/lib/`, `githooks/pre-commit`) vendored byte-for-byte at a
  recorded commit, with the same check and report (R6).
- **FR-006**: The new repository's CI MUST run `./check.sh` on a macOS runner,
  as a required check of its default branch (R7), without secrets.
- **FR-007**: dotfiles MUST keep, and only keep: the `uv-tools.txt` pin, the
  Brewfile entry for `container`, install.sh's container-kernel step, drift.sh's
  reports for them and for the installed command, docs pointing at the new
  repository (R8).
- **FR-008**: Nothing MUST be removed from or added to dotfiles' `main` until
  the new repository's tagged release has a green suite and the wiring has been
  proved on a scratch `HOME` (plan, "Cut-over"). Because the harness never
  reached `main`, "removal" is the closing of branch 003, and the rollback of
  the wiring PR is a revert (R10).
- **FR-009**: The new repository MUST have its own constitution, written with
  `/speckit-constitution` at implementation time from principles that a check
  or a named reviewer step can verify (plan, "Constitution of the new
  repository" lists the candidates).
- **FR-010**: `specs/003-sdd-model-routing/` MUST move with the harness,
  keeping its number, and the open tasks T049-T055 MUST continue there; T052
  and T053 (the SC-001/SC-002 measurement) run against the new repository's
  tagged release (R11).

### Key Entities

- **Moved path**: a tracked file that only the harness reads, writes or checks
  (`inventory.md`).
- **Vendored file**: a file of dotfiles' copied byte-for-byte into the new
  repository with a recorded source commit and sha256 (`vendor/SOURCES`).
- **Pin**: the line in `uv-tools.txt` naming the release tag the machine
  installs.
- **Release**: a git tag on `sdd-routing` with a GitHub Release (required by
  `drift.sh`'s stale-pin report) and a passing suite.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `./check.sh` in dotfiles drops back to the 12-17 s class and its
  CI to the 36-51 s class once branch 003 is closed (measured on the wiring
  PR, three runs each, recorded in `research.md` "Measurements"). Pending.
- **SC-002**: The new repository's `./check.sh --strict` passes from a clean
  clone with no dotfiles checkout, on this machine and in its CI. Pending.
- **SC-003**: Breaking each guard by hand turns it red: a byte changed in the
  vendored runner; the same in `config-guard.sh`; a file missing from the built
  wheel; a launcher pointing at a wrong root. Pending.
- **SC-004**: A run started by the installed `sdd-run` freezes a bundle whose
  `code/` tree equals the repository's tagged `bin/`, `claude/speckit/schemas/`,
  `claude/config-guard.sh` and `containers/worker/` (the existing 96 end-to-end
  case, run against the installed tree). Pending.
- **SC-005**: `git log --follow` over each moved file in the new repository
  lists the same number of commits as in the source branch. Dry run on
  2026-10-23: `claude/speckit/brief.md` 4 of 4 (`research.md` R2).

## Assumptions

- The 003 branch is not merged and not changed after the extraction starts
  except through the catch-up described in the plan; its agent is told to stop
  before T-extract runs.
- GitHub Actions on a public repository is free, including macOS runners
  (stated by the owner; to be confirmed on the first run, T-ci).
- The owner creates the GitHub repository and tags; this feature's tasks
  prepare everything up to those two actions and say when each is needed.
- Out of scope: any change to the harness's behaviour beyond the minimal
  edits `inventory.md` lists under "Edited on the way"; the 003 US3 tasks; a
  Linux runner; publishing the harness to PyPI.
