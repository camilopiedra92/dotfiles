# Research: One check suite at a time

## R1 — Why a lock, and not the other answers to a hot machine

**Decision**: one top-level `check.sh` run per user at a time on the machine;
a second run waits for the first instead of competing (spec FR-001).

**Rationale**: what was observed on 2026-10-22 was runs piling up — three
agents in different worktrees plus another session's worktree, each fanning
its sections over every CPU (`JOBS` = `hw.ncpu` = 12) and some driving
container VMs (feature 003's sections 92–96) — not one run being too wide. A
single run on an idle machine using the whole machine is what feature 004
built (004 research R5) and what the owner wants kept.

**Alternatives** (rejected with the owner, 2026-10-22):
- Capping `JOBS` per run. Lost: it does not stop runs from piling up — four
  capped runs still run at once — and a single run on an idle machine would
  stop using the machine.
- Running sections at background QoS (`taskpolicy -b`). Lost: it slows the
  pre-commit hook, whose whole point is latency (004), and still lets runs
  pile up, only more slowly.
- One lock per repository. Lost: the contention is the machine's. The
  overlapping runs were in different worktrees and clones, which a
  per-repository lock lets through.
- A shared jobserver: a machine-wide token pool, as GNU make's, Ninja's or
  Cargo's, here a FIFO handing one token per section across all runs. Lost:
  with no parent process owning every client (make's model), a run killed
  with SIGKILL leaks its tokens until the pool drains and every run
  deadlocks; recovering them needs a daemon tracking holders, far more
  machinery than one user's machine needs. And what it buys is throughput
  when two suites coincide, not the goal, which is not overloading the
  machine.
- Caching section verdicts by their inputs, as Bazel, Turborepo or Nx do.
  Lost: it requires hermetic sections, and these read machine state —
  installed tool versions, the container runtime, Keychain stand-ins — so a
  stale verdict could pass green.

**Prior art** the chosen design follows (cited by the owner, 2026-10-22; the
wording was not re-checked against those tools here): Bazel's client prints
"Another command (pid=…) is running. Waiting for it to complete" and waits
for the server's lock; Cargo prints "Blocking waiting for file lock" and
waits on an advisory `flock` of its build directory. Both wait rather than
compete, and say once for whom.

## R2 — The locking primitive

**Decision**: `flock(2)` through `/usr/bin/lockf` in its file-descriptor form:
the runner opens the lock file on a descriptor of its own (`exec 9>>file`) and
`lockf -s -t 0 9` takes an exclusive lock on that open file. The lock belongs
to the open file description the runner holds, so it lasts exactly as long as
some process holds that descriptor open, and the kernel releases it when the
last one closes it — on exit, normal or SIGKILL. Stale detection is the
holder's liveness by construction, with no age, no pid check and no clean-up
step (spec FR-004).

**Evidence** (this Mac, macOS 27.0.1, bash 3.2.57, 2026-10-22, a probe script
in a scratch directory):
- `ls /usr/bin/lockf /usr/bin/shlock` — both ship with macOS; `flock(1)` is
  not installed (`which flock`: not found), neither from the system nor from
  Homebrew here.
- `man lockf`: "BSD-style locking is used, as described in flock(2); the mere
  existence of the file is not considered to constitute a lock"; `-t 0` fails
  at once with `EX_TEMPFAIL` (75) when held; the fd form is documented "to
  lock inside a shell script".
- Probe: a holder ran `exec 9>>l.lock; lockf -s -t 0 9`; a second process's
  `lockf -s -t 0 9` on its own open of the file returned 75. After `kill -9`
  of the holder, the second still got 75 **while a child the holder had
  started with fd 9 inherited was alive**, and 0 once that child was gone; a
  child started with `exec 9>&-` did not hold it. Hence R5.
- Probe: a waiter ran `lockf -s 9 &` and `wait $!` under a TERM trap that
  kills the background `lockf`; TERM ended it at once with 143 and no `lockf`
  process was left. A waiter whose background `lockf` acquired the lock and
  exited kept holding it: a third process got 75. Hence R3.

**Alternatives**:
- `mkdir` as the atomic test-and-set, with the holder's pid inside. Lost: the
  directory outlives a killed holder, so staleness must be decided by hand —
  `kill -0` on the recorded pid, then a removal that two waiters can race
  (both see the holder dead, one removes the other's fresh lock) — and a
  recycled pid makes a dead holder look alive.
- `shlock(1)`. Lost: its own man page says "deprecated, and lockf(1) should be
  used instead", and lists under BUGS that a recycled pid makes a stale lock
  look valid.
- `set -o noclobber` and `>` as the test-and-set. Lost: the same staleness
  problems as `mkdir`.
- `flock(1)` from Homebrew (util-linux or the `flock` formula). Lost: a new
  dependency for a primitive the platform already ships.
- `perl -e 'flock …'` or Python's `fcntl`. Lost: an interpreter started on
  every run for what `lockf` does; the system Python is never touched
  (constitution II) and perl's future on macOS is announced as uncertain.

## R3 — Waiting, and abandoning the wait

**Decision**: first `lockf -s -t 0 9`. On 0 the turn is taken. On 75 the run
prints its one waiting line (R4), then starts `lockf -s 9` in the background
and `wait`s for it, with INT and TERM trapped to kill that `lockf` and exit
130 or 143 without running anything (spec FR-005). Any other status, or an
`exec 9>>file` that fails, is FR-007: `check.sh: cannot take the run lock
<path>` on stderr, exit 1. The waiting traps are replaced by the runner's
section traps once the turn is taken.

**Rationale**: a foreground `lockf -s 9` would wait in the kernel, and bash
defers a trapped signal until its foreground child returns — a TERM sent to
the runner alone (an agent's tool stopping it) would never be handled while it
waited. `wait` on a background job returns as soon as a trapped signal
arrives (probe in R2). The background `lockf` locks the open file description
it shares with the runner, so the runner holds the lock after `lockf` exits.

**Alternatives**:
- Polling `lockf -t 0` with a `sleep` between tries. Lost: latency up to the
  interval after the holder ends, and a wake-up every interval on a machine
  this feature exists to quieten; `wait` on a blocked `lockf` costs nothing.
- `lockf -t <seconds>` as a timeout. Lost: the spec has no timeout (Edge
  Cases); a run waits as long as the run ahead of it takes.

## R4 — Saying whom it waits for

**Decision**: once the turn is taken, the holder writes `<pid> <repository
path>` into the lock file itself (`printf … > file`, which truncates the same
inode and leaves the lock on the open description untouched). A run that finds
the turn held reads that line and prints, once, on stderr:
`check.sh: waiting for the run of pid <pid> in <path> to finish`. If the line
is empty — the holder has the turn but has not written yet — it prints
`check.sh: waiting for another run to finish`. The repository path is the
directory `check.sh` changed into (`$PWD` after its `cd`). The holder
empties the record in its EXIT trap, while the turn is still its own, and a
waiter that reads a pid no longer alive (`kill -0` fails) prints the line
without details too.

**Rationale**: the record is informative only: the kernel lock decides who
holds the turn (spec Key Entities), so no record, stale or empty, blocks
anyone. But a stale one does not merely make the line vaguer: until
2026-10-22 the record was never emptied, so a waiter that read it between
the next holder taking the turn and writing its own, or while something that
is not a run held the turn, named a run that had finished (06-lock, "a run
that has ended is not named", red that way before the fix). Emptying it on
exit covers every run that ends through its EXIT trap; the liveness test
covers the rest, a run killed outright (06-lock, "a run killed outright is
not named", red without it). What remains: a record left by a run killed
outright whose pid is still taken -- by the dead run until its parent reaps
it, or by a process the system has given it since -- read in that instant or
behind such a holder names that pid. Standard error keeps standard output
identical to a run made alone (FR-003).

**Alternatives**:
- A separate record file beside the lock. Lost: a second file to create and
  keep consistent for no gain.
- Retrying the read until the line appears. Lost: the window is the holder's
  next statement; a less precise message is acceptable there.
- Truncating the record as the turn is taken, before writing it. Lost: the
  write that follows truncates already, in the next statement; the gap
  between taking the turn and that statement is the same either way.

## R5 — What holds the turn, and nested runs

**Decision**: only the runner's own shell holds the lock descriptor. Each
section's subshell closes it first (`exec 9>&-`), so nothing a section starts —
a check, a scratch copy of `check.sh`, a daemon or VM left behind — keeps the
turn after the runner ends (probe in R2, spec US2 AS2). Having taken the turn,
the runner exports `CHECK_SH_RUN=<its pid>`; a run that starts with it set is
nested and skips the lock entirely: no wait, no line, no record (FR-006). It
is not a `GIT_` variable, so `drop_hook_git_env` leaves it alone.

**Rationale**: the runner's self-test (`checks/05-runner.sh`) starts about 30
copies of `check.sh` inside a run (`checks/15-githooks.sh` uses a stub
`check.sh`, so only 05-runner does, `grep -n check.sh checks/*.sh`,
2026-10-22), and they would otherwise wait forever for their own parent. Being started from within a run
is what makes a run nested (spec Edge Cases), and an inherited environment
variable is exactly that relation.

**Alternatives**:
- Letting nested runs inherit the locked descriptor and re-lock it. Lost: a
  nested run opens the lock file afresh, a new open file description that
  waits on its parent's lock; telling an inherited descriptor from its own
  would need fd introspection bash 3.2 lacks, and keeping the descriptor open
  in sections is what lets a leftover child hold the turn.
- Walking the process ancestry for a `check.sh`. Lost: `ps` parsing on every
  run for what one variable says.
- Validating the variable's pid (alive, and the lock's recorded holder).
  Lost: it guards only against someone exporting it by hand, who means to
  bypass the lock anyway.

**Consequence**: exporting `CHECK_SH_RUN` by hand bypasses the lock. It is
named in `docs/checks.md` for what it is.

## R6 — Where the lock lives

**Decision**: `$(getconf DARWIN_USER_TEMP_DIR)dotfiles-check.lock`, the
per-user temporary directory (`/var/folders/…/T/`, mode 700, owned by the
user), read from the system rather than from `TMPDIR`.

**Evidence**: `getconf DARWIN_USER_TEMP_DIR` and `$TMPDIR` printed the same
directory in this session (2026-10-22), and a file could be created there.

**Rationale**: per-user (spec Assumptions), the platform's place for a user's
transient files, and macOS may clear it, which the kernel lock makes harmless:
a missing file means no live holder. `TMPDIR` is an environment variable any
tool or sandbox may point elsewhere, and two runs that read different
`TMPDIR`s would take two different locks and overlap in silence; `getconf`
asks the system. The name says whose lock it is, so other tools' files there
cannot collide.

**Alternatives**:
- `$TMPDIR`. Lost: see above.
- `/tmp`. Lost: shared by every user, and world-writable.
- An XDG state path under `~/.local/state`. Lost: it persists across
  reboots for a lock that means nothing after one, and gives nothing the
  kernel lock does not.
- A path inside the repository (`.git/`). Lost: per repository (R1).

**Test seam**: `checks/` drives the runner against a stub `getconf` earlier on
`PATH` that prints a scratch directory, the way 05-runner already stubs
`mktemp`; no variable in `check.sh` exists only for tests.

**Known limit**: macOS's cleaner removes files in that directory left
untouched for days. A run lasting that long whose lock file was removed would
let a second run take a new file; runs take minutes, so it is not handled.

## R7 — Where in the run the lock is taken

**Decision**: right after the arguments are parsed and the git environment is
dropped, before the selection and any output, so a usage error never waits
(FR-008) and a waiting run has printed nothing but its waiting line. The lock
is the first thing a run does once it knows it will run.

**Alternatives**:
- Just before the sections, after the selection. Lost: the selection line
  would print before the wait, and the selection's git calls would run
  against an index that may change while it waits (a `commit -a` index is
  fixed, but a hand run's is not).

## R8 — The check

**Decision**: a new section, `checks/06-lock.sh`, declaring `# covers:
check.sh`, drives scratch copies of `check.sh` in scratch repositories whose
fake sections log `<run> start` and `<run> end` lines, a pause between, to a
log shared across the runs; overlap shows as interleaved lines, so no clock
is read. Each copy runs with `CHECK_SH_RUN` removed from its environment and a
stub `getconf` on `PATH` naming a scratch directory, so the cases neither see
the outer run as their parent nor wait on its real lock. Cases that could hang
run under a watchdog that kills them after a bound and fails the case. The
helper that builds a fake-section repository, `sections_repo`, moves from
`checks/05-runner.sh` to `checks/lib/runner.sh`, since two sections now use it
(004 research R6).

**Rationale**: a section of its own runs beside 05-runner instead of after its
cases: 05-runner is already the slowest section and so the full run's floor
(11.0 s alone, 004 Measurements); the lock cases wait on purpose, and inside
05-runner they would add to that floor.

**Alternatives**:
- Extending `checks/05-runner.sh`. Lost: see above.
- Copying `sections_repo` into the new section. Lost: two copies drift.

## R9 — CI

**Decision**: no special case. A CI runner executes one run, finds the turn
free, takes it at once and prints nothing extra; `getconf
DARWIN_USER_TEMP_DIR` exists on the macOS runner as on any macOS.

**Alternatives**:
- Skipping the lock when `CI` is set. Lost: a second code path the gate would
  never exercise, for a lock that already costs nothing there.

## Measurements

The added time of a run with no other in progress (spec SC-004): wall time
of `./check.sh` in a scratch repository (`git init`, `check.sh` copied, one
section `check "a ran" true`, `checks/lib/` with one helper), one warm-up run
not counted, then ten runs, each `/usr/bin/time -p env -u CHECK_SH_RUN
./check.sh`, the `real` line kept; this M4 Pro, idle, 2026-10-22.
`time -p` reports hundredths, so 0.01 s is its resolution.

- Before, `check.sh` from c3819e5 (`main`): 0.05 0.04 0.05 0.05 0.05 0.05
  0.05 0.05 0.05 0.05 s — median 0.05, mean 0.049.
- After, this feature's `check.sh` (8cd7ec2's lock, run as a top-level run
  on the real lock, nobody else holding it): 0.05 s each of the ten — median
  0.05, mean 0.05. Indistinguishable at this resolution, so also:
- Twenty back-to-back runs timed as one (`/usr/bin/time -p` around the loop,
  same scratch repository), alternating, three rounds: before 1.02, 1.03,
  1.02 s; after 1.10, 1.10, 1.11 s. About 0.004 s added per run, under
  SC-004's 0.1 s.

The full suite, `./check.sh --strict` alone (T014, T019, T033): 12.9 s and
12.8 s once 06-lock had its US1 and US4 cases; 16–17 s in each of five runs
once the US3 cases joined, all "All checks passed", exit 0, `git status
--porcelain` unchanged. 06-lock had then outgrown 05-runner and become the
run's floor, against R8's premise. Its holders slept a fixed time; they now
hold until the case has seen their waiters waiting, which is also
deterministic under load: the section alone went from about 17.5 s to 9.8 s
(two runs, 9.76 and 9.85 s, in a scratch runner holding only it). The full
suite was not rerun after that change (the owner's limit on full runs).
