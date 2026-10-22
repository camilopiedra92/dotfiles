---

description: "Task list for one check suite at a time"
---

# Tasks: One check suite at a time

**Input**: Design documents from `specs/006-check-lock/`

**Prerequisites**: plan.md, spec.md, research.md, contracts/check-lock.md, quickstart.md

**Tests**: requested — every story has logic of its own (constitution III, the
owner's rules). Test tasks come first in each story, run once before the code
exists, and each must fail for the reason its case predicts; a case that
passes before its code exists guards existing behaviour and is kept only once
a hand-break turns it red.

**Organization**: by user story. Every commit keeps `./check.sh --strict` green.
All lock cases live in `checks/06-lock.sh` and drive scratch copies of
`check.sh` with `CHECK_SH_RUN` removed from their environment and a stub
`getconf` first on `PATH` printing a scratch directory (research R6, R8), so
they never touch the real lock nor wait on the run executing them.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4, spec.md)

## Phase 1: Setup

- [X] T001 Record the before measurement for spec SC-004 in specs/006-check-lock/research.md "Measurements": wall time of `./check.sh` in a scratch repository with one trivial section (ten runs, `/usr/bin/time -p`), on `main` at c3819e5

## Phase 2: Foundational (blocking: every story's cases need the fixtures)

- [X] T002 Move `sections_repo` from checks/05-runner.sh into a new checks/lib/runner.sh (header comment: shared by 05-runner and 06-lock), delete it from checks/05-runner.sh, and confirm `bash -n` and shellcheck on both files (the lint globs in checks/10-lint.sh already include checks/lib/*.sh)
- [X] T003 Create checks/06-lock.sh: the header of the other sections (shellcheck directives, "Sourced by check.sh" comment), `# covers: check.sh`, a `printf '\n%sRun lock%s\n'` heading, and its fixtures: `lock_env <tmp>` (writes a stub `getconf` into `<tmp>/bin` that prints `<tmp>/lockdir/` for `DARWIN_USER_TEMP_DIR`, makes the directory), `lock_repo <dir> <name> <seconds> [<extra section body>]` (sections_repo whose section `10-a` appends `<name> start` to `$tmp/log`, sleeps, appends `<name> end`), `lock_start <dir> <out-prefix>` (runs `cd <dir> && exec env -u CHECK_SH_RUN PATH=<tmp>/bin:$PATH ./check.sh` in the background with stdout and stderr to separate files, sets `LOCK_PID`), and `within <seconds> <pid>` (waits for a pid, killing it and returning 1 past the bound — bash 3.2 has no `timeout`); cleanup on RETURN kills what a case started

## Phase 3: User Story 1 - Overlapping runs take turns (P1) MVP

**Goal**: a second top-level run waits for the first, says once for whom, then runs as it would alone.

**Independent Test**: two scratch runs started a fraction of a second apart log `A start, A end, B start, B end`, never interleaved; B's stderr is one waiting line naming A's pid and repository.

### Tests for User Story 1

- [X] T004 [US1] Add to checks/06-lock.sh the case "a second run waits for the first, across repositories, and says so once": runs A (2 s) and B in two scratch repositories, B started 0.5 s after A; expect the log `A start|A end|B start|B end|`, B's stderr exactly `check.sh: waiting for the run of pid <A's pid> in <A's repository> to finish` (one line), both exit 0 (spec US1 AS1, FR-001, FR-002)
- [X] T005 [US1] Add the case "a run that waited prints what it prints alone": B's stdout and exit status after waiting equal B's stdout and status run alone, once with a passing and once with a failing fake section (US1 AS2, FR-003)
- [X] T006 [US1] Add the case "the lock is the machine's, not the repository's": A and B in the same scratch repository, same expectation as T004 (US1 AS3)
- [X] T007 [US1] Add the case "a run with nobody ahead neither waits nor says so": one run, empty stderr, exit 0, within 2 s (US1 AS4)
- [X] T008 [US1] Add the case "waiting runs go one at a time": a holder of 1.5 s and three runs started while it holds, each section 0.5 s; the log has every `start` immediately followed by its own `end`, four runs, all exit 0 (US1 AS5, SC-001)
- [X] T009 [US1] Add the case "a usage error does not wait": with a holder running, `./check.sh --bogus` exits 2 within 1 s (FR-008)
- [X] T010 [US1] Add the case "a holder that has not recorded itself": hold the scratch lock with `lockf -k <file> sleep 2` (file left empty) and start a run; its stderr is `check.sh: waiting for another run to finish`, and it runs after the sleep ends (contracts/check-lock.md, spec Edge Cases)
- [X] T011 [US1] Add the case "a lock that cannot be taken says where": the stub `getconf` prints a path under a file (not a directory); the run exits 1, its stderr is `check.sh: cannot take the run lock <path>`, and no section ran (FR-007)
- [X] T012 [US1] Run checks/06-lock.sh (`./check.sh --strict --staged` with it staged, or the section through the runner) before any code, and record that T004–T011 fail for their predicted reason: interleaved logs and no waiting line (T004, T006, T008), T005 and T007 and T009 passing (guards: kept only after T015's hand-breaks), T010 no line, T011 exit 0

### Implementation for User Story 1

- [X] T013 [US1] In check.sh, after `drop_hook_git_env` and the argument loop and before Selection, add the lock block (research R2–R7, contracts/check-lock.md): skip it entirely when `CHECK_SH_RUN` is set; `lock=$(getconf DARWIN_USER_TEMP_DIR)dotfiles-check.lock`; `exec 9>>"$lock"` or fail with the FR-007 line; `lockf -s -t 0 9`: 0 takes the turn, 75 reads `<pid> <path>` from the file with `read -r`, prints the one waiting line on stderr and waits with a foreground `lockf -s 9` (US3 makes it interruptible), any other status fails with the FR-007 line; once held, `printf '%s %s\n' "$$" "$PWD" > "$lock"` and `export CHECK_SH_RUN=$$` — the export is what keeps checks/05-runner.sh's nested copies from waiting on their parent, so it lands in this task, not US4's. Each decision carries its why and date beside it (constitution VI)
- [X] T014 [US1] Run checks/06-lock.sh: T004–T011 green; run the full suite `./check.sh --strict` alone and see it green, 05-runner included
- [X] T015 [US1] Hand-breaks, each seen red then restored, named in the commit message: drop the `lockf -t 0`/wait (T004, T006, T008 red); print the waiting line twice or on stdout (T004, T005 red); take the lock before the argument loop (T009 red); write no record (T004 red on the line); treat any `lockf` failure as "held" (T011 red)
- [X] T016 [US1] Commit the story; a fresh-context review of the diff against spec US1 and constitution III before the next story

## Phase 4: User Story 4 - A run inside a run is part of it (P1)

**Goal**: a `check.sh` started from within a run runs at once, without waiting or a line.

**Independent Test**: a scratch run whose section starts another scratch `check.sh` completes within its bound, the nested run printing no waiting line.

### Tests for User Story 4

- [X] T017 [US4] Add to checks/06-lock.sh the case "a run started inside a run does not wait for it": a scratch repository whose section runs `./check.sh` in a second scratch repository (inheriting the outer copy's environment) and checks its stderr is empty; the outer run exits 0 within 10 s under `within` (US4 AS1, FR-006)
- [X] T018 [US4] Run it: it passes, since T013 already exports `CHECK_SH_RUN`; break by hand (remove the export, then separately the skip) and see it go red by the watchdog each time, which is what keeps it (T013's note); restore

### Implementation for User Story 4

- [X] T019 [US4] Run the full suite `./check.sh --strict` and see checks/05-runner.sh pass with its ~30 nested copies (US4 AS2, SC-005); commit with T018's red runs named

## Phase 5: User Story 2 - A dead run blocks nobody (P2)

**Goal**: only a live runner holds the turn; nothing a section leaves running holds it.

**Independent Test**: kill a run with SIGKILL, or let a section leave a `sleep` behind; the next run starts at once with no waiting line.

### Tests for User Story 2

- [X] T020 [US2] Add to checks/06-lock.sh the case "a run killed outright frees the turn": start A (section sleeping 5 s), `kill -9` its runner after 0.5 s, start B; B has empty stderr and ends within 2 s (US2 AS1, SC-002); then kill what A's section left
- [X] T021 [US2] Add the case "what a section leaves running is not the run": A's section starts `sleep 5 &` and ends; after A exits, B has empty stderr and ends within 2 s (US2 AS2, FR-004); kill the sleep
- [X] T022 [US2] Add the case "an old record is not a lock": the scratch lock file holds `99999 /nowhere` and nobody holds it; a run starts at once with empty stderr (US2 AS3)
- [X] T023 [US2] Run them before the code: T021 fails (the section's child inherited descriptor 9, so B waits — the R2 probe's prediction); T020 and T022 pass (the kernel lock already frees on death: guards, kept only after T025)

### Implementation for User Story 2

- [X] T024 [US2] In check.sh's `run_section`, close descriptor 9 first thing in the section's subshell (`exec 9>&-`), with the R2 probe beside it as its why; T020–T022 green
- [X] T025 [US2] Hand-breaks, seen red and restored, named in the commit message: remove the `exec 9>&-` (T021 red); replace the kernel lock with an existence test of the lock file (T020, T022 red); commit; fresh-context review of the story

## Phase 6: User Story 3 - Waiting can be abandoned (P2)

**Goal**: INT or TERM while waiting end the run at once, 130 or 143, without the turn.

**Independent Test**: TERM to a waiting run ends it within a second with 143 and none of its sections in the log; the holder finishes; a third run then starts at once.

### Tests for User Story 3

- [X] T026 [US3] Add to checks/06-lock.sh the case "TERM while waiting ends the run without its turn": holder A (3 s), waiter B; TERM to B's runner after 0.5 s; B exits 143 within 1 s (SC-003), no `B start` in the log, A exits 0 with its log whole, then C starts with empty stderr, and no `lockf` process B started remains (`pgrep -P` before the TERM names it) (US3 AS1, AS3, FR-005)
- [X] T027 [US3] Add the case "^C while waiting ends the run with 130": the pty pattern of `ctrl_c_stops_sections` in checks/05-runner.sh (python3 `pty.fork`, `\x03` written to the pty) with the scratch lock held by `lockf -k <file> sleep 5`; the run exits 130 and runs no section (US3 AS2)
- [X] T028 [US3] Run them before the code: T026 fails for not exiting within 1 s (bash defers the TERM trap behind the foreground `lockf`); T027's predicted result recorded as observed, kept only if a hand-break turns it red

### Implementation for User Story 3

- [X] T029 [US3] In check.sh's lock block, wait with `lockf -s 9 &` and `wait $!` under INT and TERM traps that kill that `lockf` and exit 130 and 143, then clear those traps before the runner sets its section traps (research R3); T026–T027 green
- [X] T030 [US3] Hand-breaks, seen red and restored, named in the commit message: wait in the foreground again (T026 red); let the trap exit without killing the background `lockf` (T026 red on the leftover process or C waiting); exit 0 from the trap (T026, T027 red); commit; fresh-context review of the story

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T031 [P] Update docs/checks.md "How a run executes": one run at a time per user on the machine across worktrees and clones; a second run waits and says for whom on stderr; the kernel frees the turn when the runner dies, and nothing a section leaves running holds it; INT/TERM while waiting; nested runs through `CHECK_SH_RUN` (and that exporting it by hand bypasses the lock); where the lock file lives; CI unaffected (FR-009)
- [X] T032 [P] Check README.md and CLAUDE.md for text the lock makes false (a claim that runs are independent of each other, or about running several suites at once) and correct it in the same commit
- [X] T033 Measure after for SC-004 as T001 did and record both in specs/006-check-lock/research.md "Measurements"; run the full suite once alone, compare its verdict and `git status --porcelain` (amended 2026-10-22 by the owner, from five runs to one: machine load, and the repetition lives in checks/06-lock.sh's own overlap cases; five had already run when the amendment arrived). quickstart.md steps 2–4 by hand are not run: each is one or more full suites, and checks/06-lock.sh drives the same behaviour on scratch copies
- [ ] T034 Run speckit-converge until a pass finds nothing above LOW, implementing its tasks last

## Dependencies & Execution Order

- Phase 2 blocks every story: the cases need `sections_repo` shared and 06-lock's fixtures.
- US1 (Phase 3) before every other story: they all extend its lock block. US1's implementation already exports `CHECK_SH_RUN`, because without it 05-runner's nested copies wait forever on their parent and the suite cannot stay green; US4 (Phase 4) adds the case that proves it and its red run.
- US2 and US3 both change check.sh in different places (`run_section`, the lock block) and add cases to the same file; done one after the other.
- T031 and T032 touch only documentation and can go beside T033.

## Parallel Opportunities

- Within a story, the test tasks write to the same file (checks/06-lock.sh) and are sequential.
- T031 [P] and T032 [P] in Phase 7.

## Implementation Strategy

MVP is US1 with US4's mechanism: one run at a time, and the suite still green
because nested runs pass through. US4 then proves the nesting, US2 makes a
dead or leaky run harmless, US3 makes the wait cancellable. Each story ends
with its cases green, its hand-breaks seen red, the whole suite green, a
commit naming the red runs, and a review by a fresh context.
