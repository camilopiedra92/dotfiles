---

description: "Task list for bounded checks"
---

# Tasks: Bounded checks

**Input**: `specs/007-bounded-checks/` (plan.md, spec.md, research.md, contracts/check-budget.md, quickstart.md)

**Tests**: requested — every story has logic of its own (constitution III, the
owner's rules). Test tasks come first in each story and run once before the
code exists; each must fail for the reason its case predicts (a missing name
proves only collection: stub it, rerun). A case that passes before its code
exists guards existing behaviour and is kept only once a hand-break turns it
red.

**The policy this feature writes is the policy it follows**: while building,
iterate with `./check.sh checks/NN-name.sh` (once US4 exists; before it, stage
the section and run `./check.sh --staged`) or `--staged`; run the whole suite
once per story close and once at the end, never to prove stability. The one
exception, and the only repetition in the feature, is T040 (SC-002), after 003
merges. Every commit keeps `./check.sh --strict` green at its story's close.

**Fixtures**: all cases drive byte-identical scratch copies of `check.sh`
(`sections_repo`, `checks/lib/runner.sh`) with `CHECK_SH_RUN` removed and the
stub `getconf` of `06-lock` where a lock is involved, so they never touch the
real lock nor wait on the run executing them. Fixture sections use small
declared budgets (1-3 s); the default is tested through a `sed`-ed copy (R7).
Each case that starts processes kills what it started on RETURN, by a marker
unique to the case in the command line (as `05-runner` does with `sleep 31.7`).

**Order**: US4 (section paths) first — small, and it is what lets every later
task iterate on one section without a scratch runner — then US1, US2, US3.

## Phase 1: Setup

- [ ] T001 Record the SC-004 "before" in specs/007-bounded-checks/research.md "Measurements": wall time of `./check.sh` in a scratch repository with one trivial section and in one with 30 trivial sections, ten runs each (`/usr/bin/time -p`), on this branch before any `check.sh` change. Scratch repositories only; not the suite.

## Phase 2: User Story 4 - Run named sections (FR-014, P2)

**Goal**: `./check.sh checks/NN-x.sh ...` runs only those, through the one runner, lock and report.

**Independent Test**: a scratch repository of three fake sections; naming two runs those two in file order; naming a non-section exits 2 before any wait.

### Tests for User Story 4

- [ ] T002 [US4] Create checks/11-named-sections.sh (header of the other sections, `# covers: check.sh githooks/pre-commit`, a `Named sections` heading, fixtures from checks/lib/runner.sh) with cases: naming `checks/30-c.sh checks/10-a.sh` runs a then c in file order, once each when repeated, `./`-prefixed accepted (contract "Invocation"); no "Staged changes select" line; `--strict` before or after the path accepted
- [ ] T003 [US4] Add cases: `checks/lib/helpers.sh`, a missing `checks/99-x.sh`, `checks` (a directory) and `10-a.sh` each exit 2 with `check.sh: not a section: <arg>` on stderr and nothing run; `--staged checks/10-a.sh` exits 2 with the usage line; with a lock holder running (stub getconf, as 06-lock) both exit 2 within 1 s, i.e. before the wait; a named section waits behind the holder like any run
- [ ] T004 [US4] Run `./check.sh --staged` with the new section staged (or its body through a scratch runner once) before any code; record that each case fails for its predicted reason: sections not selected by argument (every section ran or exit 2 for the usage line), no "not a section" line, no usage change. Update the expectation in checks/05-runner.sh `runner_usage_and_cleanup` (line 504) to the new usage line `usage: ./check.sh [--strict] [--staged | <section>...]` in this task and see it red

### Implementation for User Story 4

- [ ] T005 [US4] In check.sh: move `SECTIONS=(checks/*.sh)` above the argument loop; in the loop accept a non-flag argument equal to a `SECTIONS` entry (after dropping a leading `./`) into `NAMED`, else `check.sh: not a section: <arg>` and exit 2; after the loop `--staged` with `NAMED` is the usage error; in Selection, `NAMED` fills `PICKED` and prints no "Staged changes" line; usage line as the contract. Comment beside it: why repository-relative only (R10)
- [ ] T006 [US4] Run `./check.sh checks/11-named-sections.sh checks/05-runner.sh` (US4 using itself): green
- [ ] T007 [US4] Hand-breaks, each seen red then restored, named in the commit message: accept any existing file (lib path case red); parse names after the lock (wait case red); allow `--staged` with names (usage case red); run in argument order (order case red)
- [ ] T008 [US4] Story close: update docs/checks.md "Tiers" one line (the command for one section) in the same commit; ONE full `./check.sh --strict`, green; commit with the red runs named

## Phase 3: User Story 1 - A section that runs too long is stopped (P1) MVP

**Goal**: a section over its budget is stopped with everything it started and fails the run; the lock is released.

**Independent Test**: a scratch suite with a hanging section (`# budget: 2`) that starts a child and a reparented grandchild ends within budget + grace + 2 s, names the section, leaves no process, the other sections whole.

### Tests for User Story 1

- [ ] T009 [US1] Create checks/08-budget.sh (header, `# covers: check.sh`, a `Budgets` heading, a case-local process marker). Case "a section over its declared budget is stopped with everything it started": `# budget: 2`, sections starting a child, a grandchild whose parent exits (`(sleep M &)`) and a TERM-ignoring process; exit 1, the line `FAIL <name> over its budget of 2 s: stopped after <t>` with t between 2.0 and 2.0 + 1 + GRACE s, output before the stop kept and before the line, `Some checks failed`, nothing carrying the marker alive afterwards, total within budget + GRACE + 2 s (US1 AS1, AS2, SC-001, FR-004, FR-005)
- [ ] T010 [US1] Case "a section runs in a group of its own and the runner keeps its own": the section prints `ps -o pgid= -p $$`; it differs from the runner's and equals the section subshell's pid (R1, guards the launch)
- [ ] T011 [US1] Case "a section without a declaration gets the default": a `sed`-ed copy with `DEFAULT_BUDGET=2` (assert the line changed); stopped and reported as in T009 (AS3, R7)
- [ ] T012 [US1] Case "a section within its budget is as before": passes in less than its budget, output and status equal the same run with the declaration removed, modulo time lines (AS4)
- [ ] T013 [US1] Case "the other sections are untouched and the failure holds in every mode": one hanging, two passing around it; their output whole and in file order; exit 1 and `Some checks failed` under plain, `--strict`, `--staged` (staged fixture) and `CI=1` (AS5, FR-005, FR-006, FR-013)
- [ ] T014 [US1] Case "a run waiting behind a hung section gets its turn": two scratch runs side by side with the stub getconf (as 06-lock); A's section hangs past `# budget: 2`, B waits; B starts and ends after A has been stopped (log order), both statuses as expected (AS6)
- [ ] T015 [US1] Case "an invalid or repeated declaration fails naming the section, without running it": `# budget: abc`, `0`, `007`, `-3`, `2.5`, empty, and two `# budget:` lines; each prints `FAIL <name> invalid budget declaration (...)`, the section's body never ran (it would create a file), the other sections ran, exit 1; the same section not selected under `--staged` is not read for it (AS7, FR-003)
- [ ] T016 [US1] Case "a section that finished its last line at the budget counts as finished": a section whose last line is written and whose subshell then hangs on an `EXIT` trap past the budget; it is not reported over budget, and its status is the one it recorded (a failing variant: exit 1, no over-budget line) (Edge Cases, R8)
- [ ] T017 [US1] Case "a stop leaves nothing on stderr": stderr of a stopped run is empty (no `Terminated` job notice) (R3, FR-009)
- [ ] T018 [US1] Case "a section that reads stdin does not stop": a section running `read x` finishes with `/dev/null` as stdin, from a pty too (`script -q /dev/null`), as 05-runner's case but with job control on at the fork (R2, R3)
- [ ] T019 [US1] Case "INT/TERM to the runner stops sections and what they started, reparented ones included": extends 05-runner's two signal cases to a grandchild whose parent exited; no budget line printed; exits 143 (TERM) and 130 (^C through a pty, 05-runner's launcher) (Edge Cases, FR-004)
- [ ] T020 [US1] Case "stopping a section stops the runs it started": the section runs a nested scratch `check.sh` (CHECK_SH_RUN inherited) whose own section ignores TERM and hangs; the outer budget is 2 s; afterwards nothing alive, and the nested run's own budget applies when it is the smaller (nested edge case, R5)
- [ ] T021 [US1] Run checks/08-budget.sh before any code (`./check.sh --staged` with it staged, or `./check.sh checks/08-budget.sh` once US4 is in) and record that T009, T011, T013-T017, T019, T020 fail for their predicted reason (the hang is waited out by the watchdog of the case, no over-budget line), T010 fails (same pgid), T012, T018 pass (guards, kept after T024's hand-breaks)

### Implementation for User Story 1

- [ ] T022 [US1] In check.sh add the constants `DEFAULT_BUDGET` (provisional 240, marked so, R7), `GRACE=5`, `SIGNAL_GRACE=2` with their why and the date beside them (R5); parse `# budget:` for each selected section next to `COVERS` (valid: exactly one, `[1-9][0-9]{0,5}`), an invalid section gets `.out`/`.rc`/`.over`-less failure written in its place without being forked
- [ ] T023 [US1] In check.sh `run_section`/the launcher: `set -m; run_section "$i" < /dev/null & PIDS[i]=$!; START_S[i]=$SECONDS; set +m`; the copied section's tail writes `N.failed` then `N.done`; rewrite the comment above `kill_tree` (the `set -m` history, the window, the dates, R1-R3). In the loop: for every started section without `.rc`, `SECONDS - START_S[i] -gt budget` calls `stop_group`
- [ ] T024 [US1] `stop_group <i>`: `kill -TERM -- -pid`, `{ wait pid; } 2> /dev/null`, poll `kill -0 -- -pid` every 50 ms up to `GRACE`, then `kill -KILL -- -pid`; then if `N.done` exists write `.rc` from `N.failed`, else write `N.over`, `N.end`, `.rc` 124. Replace `kill_tree`/`stop_sections` by the same group stop with `SIGNAL_GRACE` over every running section; the printing loop prints the over-budget line and not the "stopped before its last line" one for `.over`, and sets FAILED
- [ ] T025 [US1] Run checks/08-budget.sh and checks/05-runner.sh checks/06-lock.sh through `./check.sh <paths>`: green; confirm the pty ^C and signal cases of 05/06 pass unchanged
- [ ] T026 [US1] Hand-breaks, each seen red then restored, named in the commit message: no `set -m` window (T010, T009 grandchild red); `-ge` for `-gt`, or `SECONDS` read at the wrong place (T012 flaky-red or T009 time bound red); skip the `KILL` stage (T009 TERM-ignorer red); skip `.done` re-check (T016 red); drop `</dev/null` (T018 red under the pty); `SIGNAL_GRACE` above `GRACE` (T020 red); drop the `wait ... 2> /dev/null` (T017 red); count the over-budget section as a skip under non-strict (T013 plain mode red)
- [ ] T027 [US1] Docs in the same commit: docs/checks.md "How a run executes": the budget rule (declaration, default and its provisional status, grace, that it fails in every mode, what a stop reaches and does not), replacing "INT or TERM ... stops the running sections and what they started" with the group wording
- [ ] T028 [US1] Story close: ONE full `./check.sh --strict`, green; commit

## Phase 4: User Story 2 - Every run shows what each section cost (P2)

**Goal**: time beside each section's output, the three slowest before the verdict, order untouched.

**Independent Test**: fixture sections sleeping 1, 2 and 3 s report within 0.5 s of those and are listed 3, 2, 1.

### Tests for User Story 2

- [ ] T029 [US2] Add helper `strip_report` to checks/lib/runner.sh (removes `  <name> took <t>` lines and the `Slowest sections` block) and create checks/09-durations.sh (header, `# covers: check.sh checks/lib/runner.sh`, a `Durations` heading); case "a section's time is reported in its place": sleeps 1, 2, 3 s; each `took` line is within 0.5 s of its sleep and follows its own section's output (AS1, SC-003, FR-007)
- [ ] T030 [US2] Case "the three slowest, slowest first": four sections (1, 2, 3, 0 s) list 3, 2, 1; fewer than three ran lists fewer; none ran (staged, nothing selected) lists none (AS2, FR-008)
- [ ] T031 [US2] Case "file order whatever finishes first": section 10 slow, 20 fast, 30 medium; the sections' output in file order, only the time values differ between two runs (AS3, FR-009)
- [ ] T032 [US2] Case "time for sections that fail, stop early or are stopped": a failing section, one with an `exit`, and one over budget each show a `took` line; an invalid-budget section shows none (AS1)
- [ ] T033 [US2] Case "not selected, not reported": a `--staged` run lists no time for unselected sections and none among the slowest (AS4)
- [ ] T034 [US2] Case "apart from the report a run's output is as before": `strip_report` of the run equals the output of the same fixture run with the report lines removed by hand-written expectation (verdict line, exit status), including for a run that waited (FR-009)
- [ ] T035 [US2] Update the exact-output comparisons in checks/06-lock.sh (`lock_waited_output_is_unchanged`, the nested case at lines ~236 and ~475) and any in checks/05-runner.sh to compare through `strip_report`; see them red for the predicted reason (the times differ) once US2's code exists in T037, not before
- [ ] T036 [US2] Run checks/09-durations.sh before any code and record that T029-T034 fail for their predicted reason (no time lines, no slowest block); T031 passes (guard)

### Implementation for User Story 2

- [ ] T037 [US2] In check.sh: `run_section` stamps `N.start` before and `N.end` after the section with `perl -MTime::HiRes=time` (R6), the stopped path stamps its own `.end`; the printer prints `  <name> took <t>` after each ran section's output (millisecond difference, one truncated decimal), collects `<ms> <name>`, prints the `Slowest sections` block before the verdict via `sort -rn | head -3`; keep `strip_report` and T035 green
- [ ] T038 [US2] Hand-breaks named in the commit: print times in finish order (T031 red); `sort` without `-r` (T030 red); take the start after the section (T029 red); list unselected sections (T033 red); stamp in the runner's loop instead of the subshell is not a break but is measured in T044
- [ ] T039 [US2] Docs in the same commit: docs/checks.md "How a run executes": the durations report and the slowest list. Story close: ONE full `./check.sh --strict` green, commit

## Phase 5: User Story 3 - Everyone verifies the same way (P2)

**Goal**: the policy written once in full, once briefly, consistent.

**Tests**: none of code: the texts have no logic of their own; SC-005 is a reviewer check, done in T047. (A check that greps two documents for phrases would assert wording, not behaviour.)

- [ ] T039a [US3] Write the "How much to run when" subsection in docs/checks.md "Tiers" (R11): the three rules, the 2026-10-22 evidence, repetition inside the check that needs it, with its own bound; and the line in the project CLAUDE.md "Commands" (R11) pointing to it; the `./check.sh checks/NN-x.sh` form in both. Commit as docs only

## Phase 6: Measurements that need other branches

- [ ] T040 Measure the default budget (SC-002, FR-002), after 003 merges into main and this branch is rebased: FIVE consecutive `./check.sh --strict` runs on this machine, the one place repetition is the point; record each section's duration per run, the maximum per section, and the arithmetic of R7 in research.md "Measurements"; replace the provisional `DEFAULT_BUDGET` and its comment, update docs/checks.md "How a run executes" with the value and where it was measured; confirm no budget tripped in the five. If 003 is not merged when this feature is ready, the PR says the default is provisional, and this task is its own follow-up commit
- [ ] T041 Read the CI runner's section durations from the CI log of this feature's pull request (the durations report) and record them in research.md; the default must keep the headroom of R7 over them, else raise it in a reviewed commit (FR-013)
- [ ] T042 Confirm `GRACE`/`SIGNAL_GRACE` against the worst clean-up seen: the time from `TERM` to an empty group in T009/T020's runs, recorded in research.md; revise R5 if within 10x of the constant
- [ ] T043 Check 96 (branch 003) and any section that legitimately exceeds the default after T040 declare their own `# budget:` in their own reviewed commit on that branch, if T040 shows any

## Phase 7: Polish and closing

- [ ] T044 SC-004 "after": the T001 scratch runs repeated on the finished check.sh; no more than 1 s above the before, recorded in research.md; if over, move the clock from the subshell to a cheaper form (R6 alternatives) and measure again
- [ ] T045 Correct project CLAUDE.md "Commands" and every comment this feature made false (the `kill_tree` block, the `docs/checks.md` signal sentence); no READMEs; no `docs/decisions` entry: nothing here binds a later feature beyond `check.sh` itself, and the reasons live in research.md R1-R5 and the comments (decision recorded here, to be reopened if a later feature stops sections with another mechanism)
- [ ] T046 Open the pull request as a draft (CI runs on pull requests only); do not mark it ready before T047
- [ ] T047 Closing pass, ONE, in a fresh context (not the implementer's): `/speckit-converge` and a review together, over spec.md, plan.md, tasks.md, research.md, the diff and the documents: every FR traced to a case and a hand-break, the red runs present in the commit messages, SC-005's two texts compared, constitution III and VI. Findings above LOW become tasks here and are closed; then the PR is marked ready
- [ ] T048 `gh pr merge --auto --squash` only on green CI for the commit that was green

## Dependencies

T001 first. US4 (T002-T008) before the rest. US1 before US2 (T037 builds on the `N.end` of the stop). US3 any time after US4 (the command it names). T040/T041 need 003 merged and US1-US2 done. T047 last but T048.
