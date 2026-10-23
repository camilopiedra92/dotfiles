# Contract: budgets, report and section arguments in `check.sh`

Extends `specs/004-fast-checks/contracts/check-cli.md` and
`specs/006-check-lock/contracts/check-lock.md`; whatever is not said here is
unchanged.

## Invocation

`./check.sh [--strict] [--staged | <section>...]`

- `<section>`: a path relative to the repository root exactly as a section is
  listed (`checks/91-sdd-routing.sh`; a leading `./` is ignored). Only those
  run, in file order whatever the argument order, each once.
- A path that is not a section (`checks/lib/x.sh`, a missing file, a
  directory), or `--staged` together with a section: stderr
  `check.sh: not a section: <arg>` or
  `usage: ./check.sh [--strict] [--staged | <section>...]`, exit 2, before the
  run lock is taken (the order of 006's contract is kept: arguments first).
- Named sections run under the same runner, helpers, budgets, lock and report
  as any run. No "Staged changes select" line is printed.

## Budget declaration

- A line starting at column 1: `# budget: <seconds>`, `<seconds>` matching
  `[1-9][0-9]{0,5}` after trimming blanks. At most one per section.
- Absent: the default, one constant in `check.sh` (`DEFAULT_BUDGET`, value and
  measurements in `research.md` R7). No flag or variable overrides either.
- Invalid or repeated, in a selected section: the section is not run; in its
  place `  FAIL <name> invalid budget declaration (<the line as written>; a
  positive whole number of seconds, once)`; the run fails; other sections run.
  Sections not selected are not read for it.

## What a run prints

Names are the file name without `checks/` and `.sh`. `<t>` is seconds with one
decimal, truncated (`2.7 s`).

1. Each section's output as before, in file order, then one dim line
   `  <name> took <t>` for every section that ran (passing, failing,
   stopped before its last line, or stopped for its budget).
2. A section stopped for its budget additionally gets, after its output and
   before its time line,
   `  FAIL <name> over its budget of <b> s: stopped after <t>`.
   The "stopped before its last line" line is not printed for it.
3. Before the verdict: a blank line, a dim `Slowest sections`, then up to
   three lines `  <name>  <t>`, slowest first, names padded to align; omitted
   when no section ran.
4. The verdict and exit status as before; any over-budget or invalid section
   makes it `Some checks failed` and exit 1, in every mode.

Standard error stays as 006 and 004 left it: no shell job-status noise
("Terminated") from a stopped section.

## Stopping

- Each section runs in its own process group (group id = the section
  subshell's pid), stdin `/dev/null`, as a background job of the runner.
- Past `budget` whole seconds counted from the fork (stopped when
  `SECONDS - start > budget`, so never early, at most one second late plus the
  20 ms poll): `TERM` to the group, up to `GRACE` seconds for the group to
  empty, then `KILL` to the group. The runner writes the section's `.over`
  marker, end stamp and `.rc` (124).
- If the section's last line had been written (`N.done`), it counts as
  finished with the status it recorded (`N.failed`), never also over budget.
- INT or TERM to the runner: `TERM` to every running section's group, up to
  `SIGNAL_GRACE` seconds, `KILL`, then exit 130 or 143 as before. No budget
  line is printed.
- Constants: `GRACE` 5, `SIGNAL_GRACE` 2 (must stay lower than `GRACE`;
  research R5), `DEFAULT_BUDGET` (research R7).
- Not reached: a process that leaves the group on its own (`setsid`,
  `pty.fork`, `set -m` in a section) and work handed to a service outside the
  tree (a container runtime's daemon).

## Files in the run's scratch directory (added)

`N.start`, `N.end`: epoch milliseconds, written by the section's background
subshell (by the runner for a stopped section's `.end`). `N.failed`: the
section's `FAILED` after its last line. `N.over`: present when stopped for its
budget.
