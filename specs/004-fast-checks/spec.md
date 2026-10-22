# Feature Specification: Fast tiered checks

**Feature Branch**: `004-fast-checks`

**Created**: 2026-10-21

**Status**: Draft

**Input**: User description: "Every commit waits minutes because the pre-commit hook runs the whole of check.sh. Standard tiering: the pre-commit hook runs only the sections the staged files affect, each section declaring the paths it covers and anything doubtful running everything; the full suite stays the merge gate in CI; the full run executes independent sections in parallel with one verdict, one summary, the same strictness and each section's output whole and in file order; one check.sh with a selection mode, no second runner; a pre-push tier only if it earns its place."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A commit is checked by what it touches (Priority: P1)

The owner commits a change. The pre-commit hook runs only the check sections
whose declared coverage matches a staged path, plus every section that
declares no coverage, and finishes in seconds when the change touches little.
A change to the checks' own machinery, or to what a section declares, runs
everything.

**Why this priority**: every commit pays the hook's cost. Measured on
2026-10-21: the whole suite takes about 22 s on `main` and about five minutes
on the branch carrying feature 003's integration sections, 87% of it in four
sections a documentation edit cannot affect.

**Independent Test**: stage a file only one section covers, run the hook, and
see that section and the undeclared ones run and every other section named as
not selected; stage `check.sh` and see every section run.

**Acceptance Scenarios**:

1. **Given** a staged path one section's coverage matches, **When** the hook
   runs, **Then** that section runs, every section with no coverage declaration
   runs, and every other section is named as not selected.
2. **Given** a staged change to `check.sh`, to anything under `githooks/`, or to
   the helpers every section is given (under `checks/` but not a section),
   **When** the hook runs, **Then** every section runs.
3. **Given** a staged change to one section file that leaves its coverage
   declaration alone, **When** the hook runs, **Then** that section runs.
4. **Given** a staged change that adds, removes or edits a coverage
   declaration line, or adds or deletes a section, **When** the hook runs,
   **Then** every section runs.
5. **Given** a selected section that fails, **When** the hook runs, **Then**
   the commit is refused, as today.
6. **Given** a deleted or renamed staged path, **When** the hook runs, **Then**
   the sections covering its old path and its new path both run.
7. **Given** a staged path under `checks/` that is neither a section nor
   matched by any section's declaration, **When** the hook runs, **Then** every
   section runs.

---

### User Story 2 - The full run takes about the time of its slowest section (Priority: P2)

`./check.sh` with no selection — by hand and in CI — runs every section, many
at once, and reports exactly as a sequential run would: each section's output
whole and in file order, one verdict, the same strictness, the same exit
status. The selected run of User Story 1 uses the same machinery.

**Why this priority**: the full suite is the merge gate; its wall time is paid
on every pull request and on every deliberate full run.

**Independent Test**: run the full suite; its output, verdict and exit status
match a sequential run of the same sections, and its wall time is below the
sum of the sections' times.

**Acceptance Scenarios**:

1. **Given** every section passing, **When** the full run executes, **Then** it
   ends "All checks passed", exit 0, each section's output whole, in file order,
   whatever order the sections finished in.
2. **Given** one section failing, **When** the full run executes, **Then** it
   ends "Some checks failed", exit 1, and the failing section's output shows
   whole in its place.
3. **Given** a section that uses a function or variable only another section
   defines, **When** that section runs, **Then** it fails, so no hidden
   dependency between sections survives.
4. **Given** a section that stops before its last line (an `exit`, an unset
   variable), **When** the run executes, **Then** that section counts as
   failed and the run says so, rather than the run dying or passing.
5. **Given** strict mode and a section that skips a check, **When** the run
   executes, **Then** the skip fails the run, as today.

---

### User Story 3 - Coverage declarations stay honest (Priority: P3)

A coverage pattern that names nothing in the repository — a typo, a moved
file — is caught by the suite, so a section cannot silently stop being
selected.

**Why this priority**: a stale declaration turns the fast tier into a hole;
the full tier in CI still catches what it misses, but later.

**Independent Test**: declare a pattern that matches no tracked file in a
section, run the suite, see it fail naming the section and the pattern.

**Acceptance Scenarios**:

1. **Given** a coverage pattern matching no tracked file, **When** the suite
   runs, by hand, in CI or in the hook, **Then** it fails naming the section
   and the pattern.

---

### Edge Cases

- Nothing staged (an `--allow-empty` commit): only the sections without a
  declaration run; the others are named as not selected and the run passes.
- The staged list cannot be read: every section runs (fail safe).
- A section prints nothing and passes: its place in the output stays empty, as
  in a sequential run.
- More sections than CPUs: no more run at once than the machine has CPUs.
- Scratch files: nothing two sections write is shared, so running them at the
  same time cannot make one see the other's files.
- A section whose result depends on the machine rather than on files (the
  installed tools' versions): it declares no coverage, so it runs on every
  commit.
- A coverage pattern written with a glob character must not be expanded
  against the working tree while it is read.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `check.sh` MUST accept a selection mode that takes the staged
  paths — added, changed, deleted, and both sides of a rename — and runs only
  the sections whose coverage declaration matches one of them, plus every
  section without a declaration.
- **FR-002**: The selection MUST fail safe: a staged change to `check.sh`, to
  `githooks/`, to the helpers under `checks/` every section is given, to any
  section's coverage declaration (adding or deleting a section included), or to
  a path under `checks/` that no declaration matches runs every section; a
  staged section file otherwise runs that section; a staged list that cannot be
  read runs every section.
- **FR-003**: A run in selection mode MUST name the sections it did not run,
  and MUST NOT count them as failures or as skips, in strict mode too: not
  running a check the change cannot affect is deliberate, unlike a missing
  tool.
- **FR-004**: The pre-commit hook MUST run `check.sh` in strict and selection
  mode, and MUST refuse the commit when it fails, as today.
- **FR-005**: A run without the selection mode — by hand and in CI — MUST run
  every section, so the merge gate stays the whole suite.
- **FR-006**: Every run MUST execute its sections concurrently, at most as
  many at once as the machine has CPUs, and MUST print each section's output
  whole, in file order, followed by one verdict; its exit status and strictness
  MUST be those of a sequential run.
- **FR-007**: Each section MUST run correctly on its own: no section may rely
  on a function, variable or file another section defines.
- **FR-008**: A section that ends before its last line MUST count as failed,
  with a line saying so in its place.
- **FR-009**: The suite MUST fail on a coverage pattern matching no tracked
  file, naming the section and the pattern.
- **FR-010**: Every behaviour above with logic of its own MUST have a check
  that was seen to fail on that behaviour broken by hand (constitution III).

### Key Entities

- **Section**: a file directly in `checks/` ending in `.sh`; a group of named
  checks, run by `check.sh` in its own shell.
- **Coverage declaration**: the path patterns a section's checks exercise,
  declared in the section file itself; absent, the section runs on every
  change.
- **Shared helpers**: functions more than one section needs, kept under
  `checks/` outside the sections and given to every section.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The pre-commit hook on a documentation-only commit takes at most
  a quarter of the full run on `main`, and runs none of the sections that
  cover only scripts; measured before and after, recorded in research.md.
- **SC-002**: The hook on a change to one file a single section covers runs
  the sections whose declarations match it and the undeclared ones only
  (`macos/touchid.sh` is also matched by `50-install`'s `macos/*`; measured
  2026-10-22: 5 of 18 sections), measured before and after.
- **SC-003**: The full run's wall time is below the sum of its sections'
  times on a machine with more than one CPU: measured before and after.
- **SC-004**: The full run's verdict and exit status equal a sequential run's
  for a passing tree and for a tree with one failing section, and repeated
  full runs on an unchanged tree give the same verdict and leave the working
  tree unchanged.

## Assumptions

- The merge gate is CI running the full suite: the repository's ruleset
  requires CI green to merge (`github/repos.json`), so a check the hook did not
  select still runs before anything reaches `main`.
- Sections are the unit of selection; selecting individual checks inside a
  section is out of scope.
- No pre-push tier (research R2).
- A coverage declaration can be wrong in the other direction — a section that
  exercises a file it does not declare. The suite cannot detect that in
  general; CI's full run catches the failure it would have missed, later.
