---

description: "Task list for fast tiered checks"
---

# Tasks: Fast tiered checks

**Input**: Design documents from `specs/004-fast-checks/`

**Prerequisites**: plan.md, spec.md, research.md, contracts/check-cli.md, quickstart.md

**Tests**: requested — every story has logic of its own (constitution III, the
owner's rules). Test tasks come first in each story, run once before the code
exists, and each must fail for the reason its case predicts.

**Organization**: by user story. Every commit keeps `./check.sh --strict` green.

## Format: `[ID] [P?] [Story] Description`

## Phase 1: Setup

- [x] T001 Record the before measurements (full run, hook on a docs-only change, hook on one covered file, each section alone) in specs/004-fast-checks/research.md

## Phase 2: Foundational (blocking: sections must stand alone before either story runs them apart)

- [x] T002 Move `one_step_only` (checks/50-install.sh) and `machine_fixture` (checks/60-machine-profile.sh) into checks/lib/fixtures.sh, source checks/lib/*.sh from check.sh before the sections, and add ./checks/lib/*.sh to the shellcheck, shfmt and bash-syntax globs in checks/10-lint.sh
- [x] T003 Move the "exec_bits reads the commit's index" case from `hook_git_env_dropped` in checks/80-git-guard.sh to its own check beside `exec_bits` in checks/10-lint.sh
- [x] T004 Prove every section passes run alone with only the runner's helpers and checks/lib/ (each section in its own `bash -c`), and the full run stays green

## Phase 3: User Story 1 - A commit is checked by what it touches (P1) MVP

**Goal**: `./check.sh --staged` runs only the sections the staged paths select; the hook uses it.

**Independent Test**: stage a file one section covers and run the hook; stage `check.sh` and see every section run.

### Tests for User Story 1

- [ ] T005 [US1] Write checks/05-runner.sh: a scratch repository holding a copy of check.sh, fake sections A (`# covers: a/*`), B (`# covers: b.txt`), C (no declaration) and checks/lib/; cases: a staged path selects its section plus C and names B as not selected (US1 AS1, FR-003); check.sh, githooks/, checks/lib/ and an undeclared checks/ path select all (AS2, AS7); a section edit leaving `# covers:` alone selects that section, one changing it, adding or deleting a section selects all (AS3, AS4); a selected failing section exits 1 (AS5); a rename selects both sides (AS6); nothing staged runs only C and passes under --strict (edge); an unreadable index selects all (edge); a pattern is not glob-expanded against the tree (edge); `*` crosses `/`; the index read is THIS_INDEX's
- [ ] T006 [US1] Change the expectation in `pre_commit_gate` (checks/15-githooks.sh) to `check.sh --strict --staged` (FR-004)
- [ ] T007 [US1] Run the suite and record that each new case fails for its predicted reason (an unknown `--staged` is a usage error)

### Implementation for User Story 1

- [ ] T008 [US1] Implement `--staged` in check.sh: argument parsing in any order, the staged list through `this_repo_git diff --cached --name-status --no-renames -z`, the selection rule of research R4, globbing off while reading patterns, the selection line of contracts/check-cli.md
- [ ] T009 [US1] Run `"$repo/check.sh" --strict --staged` from githooks/pre-commit, comment updated
- [ ] T010 [P] [US1] Add the `# covers:` lines of research R7 to each section in checks/*.sh, and a comment on each section without one saying why
- [ ] T011 [US1] Break each selection rule by hand once and see its case go red; restore; full suite green; fresh review of the story

## Phase 4: User Story 2 - The full run takes about the time of its slowest section (P2)

**Goal**: every run executes sections concurrently, prints each whole in file order, one verdict.

**Independent Test**: the full run's output and verdict equal a sequential run's, wall time below the sum.

### Tests for User Story 2

- [ ] T012 [US2] Add to checks/05-runner.sh: sections finishing in reverse order print in file order, whole, ending "All checks passed" exit 0 (AS1); one failing section exits 1 with its output in place (AS2); a section calling a function only an earlier section defines fails (AS3); a section that exits early or hits an unset variable counts as failed with the "stopped before its last line" line (AS4, FR-008); a skip fails under --strict and not without (AS5); with `sysctl` stubbed to answer 2, never more than 2 sections run at once, and 2 do (FR-006)
- [ ] T013 [US2] Run the suite and record that each new case fails for its predicted reason

### Implementation for User Story 2

- [ ] T014 [US2] Implement the parallel runner in check.sh (research R5): each section in its own subshell with a done-marker, output and status in one `mktemp -d`, at most `sysctl -n hw.ncpu` at once, polling, in-order printing, removed on exit
- [ ] T015 [US2] Break the ordering, the verdict, the done-marker and the cap by hand once each and see their cases go red; restore; full suite green; fresh review of the story

## Phase 5: User Story 3 - Coverage declarations stay honest (P3)

**Goal**: a pattern matching no tracked file fails the suite.

### Tests for User Story 3

- [ ] T016 [US3] Add to checks/05-runner.sh a case running the declaration check over a scratch repository whose section declares a pattern matching no tracked file, expecting a failure naming the section and the pattern (US3 AS1), and run it red

### Implementation for User Story 3

- [ ] T017 [US3] Implement the declaration check in checks/05-runner.sh over this repository's sections, through the runner's own pattern reader and `this_repo_git ls-files`
- [ ] T018 [US3] Break it by hand (a typo in one real `# covers:` pattern) and see it go red; restore; full suite green; fresh review of the story

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T019 [P] Update docs/checks.md (the tiers, the declaration, the selection rule, the parallel run, no pre-push tier), README.md and CLAUDE.md where they say the hook runs every check or the sections are sourced into one shell
- [ ] T020 Measure after: the hook on a docs-only change, on one covered file, the full run; run the full suite five times and compare verdicts and `git status --porcelain`; record in specs/004-fast-checks/research.md
- [ ] T021 Run speckit-converge until a pass finds nothing above LOW, implementing its tasks

## Dependencies & Execution Order

- Phase 2 blocks every story: a section run apart from the others must not lean on them.
- US1 (Phase 3) before US2 (Phase 4): both change check.sh's section loop; US1 keeps the loop sequential, US2 makes it parallel.
- US3 needs US1's pattern reader.
- T010 touches only the section files and can go beside T008–T009.

## Implementation Strategy

MVP is US1: the hook alone is what every commit waits on. US2 then cuts the
full run, US3 guards US1's input. Each story ends with the whole suite, the
hand-breaks, a commit, and a review by a fresh context.
