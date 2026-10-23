# Research: Bounded checks

Probes ran 2026-10-22 on macOS 27.0.1, `/bin/bash` 3.2.57, in a scratch
directory with fake sections; none ran this repository's suite. "pty" means
python's `pty.fork` giving the script a terminal, optionally under an
interactive `bash -i` that started it, with `\x03` written to the master.

## R1 — The stop mechanism: a process group per section

**Decision**: each section is a background job that bash places in a group of
its own by switching job control on only around the fork:
`set -m; run_section "$i" < /dev/null & PIDS[i]=$!; set +m`. The job's pid is
its group id. Stopping is `kill -TERM -- -$pid`, a grace, `kill -KILL -- -$pid`.

**Evidence**:
- The job's group was its own pid while the runner kept its group (runner
  pgid 82391, job 82402). A section that started `(sleep 300 &)` left that
  `sleep` with ppid 1 and the job's pgid; 004's walk (`pgrep -P` from the job)
  listed only the section's subshell and never the orphan, the group TERM
  reached it. This is the case 004 cannot reach and FR-004 requires.
- Spawning cost, 30 sections of a trivial function: `set -m` window 26 ms,
  plain background 23 ms.
- It works with no terminal (the tool's shell) and with one (R2).

**Alternatives**:
- 004's parent-pid walk (`kill_tree`). Lost: misses a reparented process
  (above).
- `set -m` for the whole run, as 004 tried. Lost for the reasons 004 recorded
  (`checks/05-runner.sh`: a section reading the terminal stopped on SIGTTIN, and
  the runner's own foreground children took ^C). The window keeps job control
  off for every foreground command of the runner and puts only the section
  jobs in their groups (R2, R3).
- An exec wrapper (`perl -e 'setpgrp(0,0); exec @ARGV'`). Lost: 30 forks cost
  111 ms against 26; and `exec` replaces the section's subshell, which is a fork
  of the runner and so holds `check`, `skip`, the colours, `STRICT`,
  `THIS_INDEX` and `checks/lib/*`; a wrapper has to rebuild all of that in a new
  bash (`export -f` plus re-sourcing the libraries), a second place for the
  section's environment to drift. `POSIX::setsid` would also drop the controlling
  terminal, changing what a section sees.
- Another process calling `setpgid` on the forked subshell. Lost: only the
  process itself or its parent may, and bash's builtins offer neither; job
  control is the parent doing it.
- Tagging every section's environment and sweeping `ps eww` for the tag. Lost:
  a child started with `env -i` or `env -u` (the checks do both) leaves no
  tag; groups are kept by the kernel. Not probed beyond that reasoning.
- A `timeout` binary: macOS ships none; a Homebrew one would be a dependency
  the manifests declare for one use and would still need a group to reach a
  reparented child. Not probed.

**Known limits**: a process that makes its own session or group leaves the
section's group: `pty.fork` (used by cases in `05-runner` and `06-lock`),
`setsid`, a `set -m` in a section. Work handed to a daemon outside the tree is
outside any mechanism (spec Edge Cases). Neither is solvable by the runner;
the cases that use `pty.fork` already `pkill` what they started.

## R2 — ^C still reaches the runner, with the window

**Decision**: keep the window as narrow as the fork.

**Evidence** (pty, a mini runner with the window, a `sleep 0.02` poll loop,
two sections each with an orphaned `sleep`, INT/TERM traps signalling each
group): from `pty.fork` directly, and again from an interactive `bash -i` that
ran it, `\x03` fired the runner's INT trap (`TRAP INT: groups signalled`, exit
130, runner pgid = terminal's foreground pgid), no `sleep` survived, and the
interactive shell returned to its prompt. Started with `&` from an interactive
shell the runner was in state `S` (not stopped by SIGTTIN) and a `kill %1`
ran its TERM trap.

**Alternatives**: none beyond R1's `set -m` throughout.

## R3 — Stdin, job-status noise, status

**Decision**: the job's stdin is redirected from `/dev/null` explicitly: with
job control on at the fork bash does not do it for an asynchronous command as
it does without. The group is then never in a position to read the terminal (004's
SIGTTIN). A killed job makes bash print `<script>: line N: <pid> Terminated`
on stderr when it reaps it (probed); the runner reaps with `{ wait "$pid"; }
2> /dev/null` straight after signalling, so nothing reaches the run's
stderr (FR-009). The status the runner writes for a section stopped for its
budget is 124, the `timeout(1)` convention; the verdict uses only `.over`.

## R4 — 006's descriptor 9

**Decision**: unchanged. `run_section` still begins with `exec 9>&-`, before
anything else, so the section's group never holds the run lock.

**Evidence**: a mini runner holding `lockf` on descriptor 9 forked a section
through the window (which closed 9 first), then `kill -9`'d itself; the
section's group kept running (`sleep 200`, `sleep 201` alive) and
`lockf -s -t 0 <file> true` succeeded at once. The window adds no wrapper
process, so there is no holder besides the ones 006's contract already names
(the runner's short commands).

006's waiting traps (`kill "$lock_waiter"`) are unchanged: while a run waits,
no section exists, so there is no group to signal; the sections' traps come
later, as they did.

## R5 — The graces, and nested runs

**Decision**: `GRACE=5` s between `TERM` and `KILL` for a budget stop,
`SIGNAL_GRACE=2` s for INT/TERM to the runner; `SIGNAL_GRACE < GRACE` by
construction.

**Rationale**: what a section's clean-up does is `rm -rf` of scratch and
`pkill` of what it started (the `trap ... RETURN` lines of 05/06): `rm -rf` of
30 scratch repositories took 12 ms (probed). 5 s is hundreds of times that and
costs a hung run 5 s only when its section ignores `TERM`; the group is
polled every 50 ms and the grace ends as soon as it is empty, so a section
that does stop costs nothing. The signal path is shorter because of nesting:
`05-runner` runs ~30 copies of `check.sh` inside a section, and a nested
runner's sections are in groups of the nested runner, not of the outer
section. Probe, nested mini runners: `KILL` to the outer section's group left
the inner section alive (it ignored TERM; pgid different from the outer's);
`TERM` to the outer group made the inner runner's trap signal its own groups,
wait 1 s, `KILL` them and exit, and nothing survived. So the outer `TERM`
has to be allowed to finish the inner stop before the outer `KILL`, hence the
inner stop's grace is shorter than the outer's. Fixed by the plan, same for
every section (FR-004); to be confirmed at the story's close by the nested
case in `08-budget`.

**Alternatives**: one constant (race at the boundary); making nested runs skip
groups (then their budgets could not reach a reparented process, against the
spec's edge case); recursing over `ps` to find nested groups (a nested group
whose runner is already dead has no ancestor to find it by).

## R6 — The clock

**Decision**: milliseconds from `perl -MTime::HiRes=time -e 'printf "%d", time*1000'`,
taken by the section's own background subshell before and after the section,
so the forks run in parallel with the other sections, not in the runner's loop;
a stopped section's end is stamped by the runner. Durations are shown with
one decimal, truncated.

**Rationale**: SC-003 asks for 0.5 s; bash 3.2's `$SECONDS` is whole seconds
and can be nearly 1 s off. `perl` ships in `/usr/bin` (probed), 6.4 ms a call.

**Alternatives**: `date +%s%N` (2.2 ms; works on this macOS 27 but the CI
image's `date` is not known from here, and older BSD dates print a literal
`N`); `python3 -I` (precedent in 05/06, but it is the Command Line Tools shim
when they are absent and slower to start); the runner stamping each event
itself (forks in the serial loop: ~60 per nested copy of the runner inside
`05-runner`, the suite's floor); a bash 5 `EPOCHREALTIME` (not on 3.2).

## R7 — The default budget

**Decision**: the rule is `DEFAULT_BUDGET` = three times the largest duration
any default-budget section shows in five consecutive full runs, rounded up to
a multiple of 30 s. The value is **not yet measured**: it needs this feature's
durations report (US2) and check 96, which exists only on branch
`003-sdd-model-routing`; 96 alone takes ~70 s (spec US2, observed 2026-10-22),
so the default must clear it: 3 x 77 s rounds to 240 s, used as a scratch
placeholder while the sections are built. Task T040 measures it on a throwaway
merge of 003's branch (check 96 only has to be present, not merged) and
replaces it before the PR opens; no provisional value ships.

**Known numbers** (not this feature's): `specs/004-fast-checks/research.md`,
sections alone: `05-runner` 11.0 s, `10-lint` 4.7 s, `80-git-guard` 3.0 s,
`50-install` 2.9 s, the rest at most 2.5 s; full run 11.6-12.0 s then, ~105 s
with 96 now (spec). The CI runner's durations come from one CI log of this
feature's pull request (its durations report), not from repetition.

**Why not tighter, with 96 declaring its own**: the owner's direction is that
the default covers 96; a section needing more declares more in a reviewed
commit (spec Assumptions). The cost is that a hang in an ordinary section holds
006's lock up to the default; still bounded, where it was unbounded.

**Rejected with the owner** (spec): moving 96 out of the hook to CI only
(004 selects it only when what it drives changes, and then it is the check that
must run before that commit); fixed global timeouts without per-section
declaration (one legitimate slow section loosens the bound for all).

**Testing the default without an override** (the spec allows none): the case
copies `check.sh` to a scratch repository and `sed`s the `DEFAULT_BUDGET=` line
to 2, asserting the line was there to change.

## R8 — The budget clock and the polling

**Decision**: the runner's existing 20 ms loop, for every started section with
no `.rc`, compares `SECONDS - START_S[i] -gt budget`. `SECONDS` is whole
seconds, and a start taken at x.99 makes a difference of `budget` possibly
only `budget - 1` s real; `-gt` makes the stop never early and at most one
second plus a poll late, inside SC-001's budget + grace + 2 s. The clock
starts at the fork, after 006's lock wait and after the section had a CPU
slot, as the spec's edge case asks. A section finished at the instant of the
stop: `N.done` is checked after the group is gone; if present the section
counts as finished with `N.failed` (the tail the runner appends to the copy now
writes it before `.done`), never also over budget.

**Alternatives**: a sidecar `sleep $budget; kill` per section (a process and a
race to cancel per section, and the same single-threaded decision about
`.done` afterwards); `perl` in the loop (a fork per 20 ms).

## R9 — The report

**Decision**: as the contract: the time line follows each section's output in
file order, so 004's ordering is untouched (the values are the only nondeterminism);
the slowest three come from `sort -rn` over `<ms> <name>` lines of the
sections that ran, before the verdict. `strip_report` (checks/lib/runner.sh)
removes both from a captured run, for the existing cases that compare whole
outputs (`05-runner` usage case, `06-lock` waited-equals-alone, nested).

**Alternatives**: one summary table at the end only (rejected: FR-007 puts the
time with the output); coloured ok/FAIL on the time line (a time line is not a
verdict).

## R10 — Section paths

**Decision**: parsed in the argument loop beside `--strict`/`--staged`, which
already runs before the lock; `SECTIONS=(checks/*.sh)` moves above it. Each
argument must equal a `SECTIONS` entry (after dropping `./`); selection then
fills `PICKED` as `--staged` does, `ALL` stays empty. Run order is file order.

**Alternatives**: accepting any existing file (a path under `checks/lib/` would
source helpers as a section); resolving absolute paths and paths relative to
the caller's directory (the runner `cd`s to its own directory first; one rule,
repository-relative, is what the usage error can say); a separate
`run-section.sh` (the scratch runners agents wrote were this, each a drifting copy).

## R11 — The policy text

For `CLAUDE.md` "Commands" (added after the existing two bullets):

> - Verify in tiers (`docs/checks.md`, "Tiers"): iterate with
>   `./check.sh --staged` or one section (`./check.sh checks/NN-name.sh`); one
>   full `./check.sh` when a story or a commit closes; never repeat full
>   suites to prove stability, repetition belongs inside the check that needs it.

For `docs/checks.md` "Tiers", after the table: the three rules in full, why
(2026-10-22: agents repeated full suites, one task list asked for five in a row,
four suites overlapped and the laptop ran hot for hours; 006 queues them and
cools the machine but each repetition now costs every other worktree its wait),
and that a check needing repetition to show stability (a race, a flake)
repeats inside itself, with its own bound. `strip`-free: the two texts say the
same three things; SC-005 is a reviewer check.

## R12 — Rejected: a warning by hand

(Spec Assumptions.) The section has to be stopped for the run to end and
release 006's lock, and a stopped section has not finished its checks.

## Measurements

- **SC-004 before** (T001, pending): wall time of `./check.sh` in a scratch
  repository with one trivial section, ten runs, on this branch before any
  `check.sh` change.
- **SC-004 after** (T0xx, pending), **SC-002 five runs** (T040, pending after
  003 merges), **CI durations** (T041, pending).
- Probe table above (R1-R5): 26/111/23 ms spawn cost, 12 ms cleanup, 6.4 ms perl.
