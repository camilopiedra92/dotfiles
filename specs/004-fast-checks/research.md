# Research: Fast tiered checks

## R1 — The tiers, and where the gate is

**Decision**: two tiers of one script. The pre-commit hook runs `./check.sh
--strict --staged`: the sections the staged paths can affect. A run with no
selection — CI, and the owner by hand — runs every section. CI is the merge
gate: the ruleset `github/repos.json` declares for this repository requires
its `check` job green to merge, so a check the hook did not select still runs
before anything reaches `main`.

**Rationale**: the presubmit/postsubmit split large repositories use (Bazel
and Nx "affected" targets, the `pre-commit` framework running each hook only
on the changed files that match its `files:` pattern): the fast tier catches
most mistakes where they are cheapest, the full tier is the guarantee.

**Alternatives**:
- The whole suite on every commit (today). Lost: every commit pays for checks
  it cannot affect — 24.7 s for a one-line docs change on `main` (measured
  below), about five minutes on feature 003's branch.
- A second, fast runner script for the hook. Lost: checks written twice
  drift, the reason `docs/checks.md` gives for one script.
- `--no-verify` as a habit. Lost: the hook stops being a gate at all.

## R2 — No pre-push tier

**Decision**: none; `githooks/pre-push` stays the default-branch guard it is.

**Rationale**: every change reaches `main` through a pull request whose CI run
is the full suite, so a full run before each push repeats, minutes earlier and
on this machine's time, what CI runs anyway — and on feature 003's branch that
is the slowest section's wall time on every push, including pushes made only
to get CI going. The one thing a pre-push tier adds is a red caught before the
round trip to CI; for this repository that round trip costs nothing but
waiting, since a draft pull request merges only on green (`gh pr merge
--auto`). `./check.sh` by hand remains the full local run whenever the owner
wants the answer first.

**Alternatives**:
- Pre-push running the full suite. Lost: duplicates CI on every push.
- Pre-push running the sections the pushed commits touched (the union of
  their paths). Lost: the commits were already checked one by one by the
  pre-commit hook against the same rule, so it would re-run what already
  passed.

## R3 — How a section declares what it covers

**Decision**: lines in the section file itself, `# covers: <pattern>
[<pattern>…]`, any number of them. A pattern is a bash pattern matched against
a repository-relative path with `[[ $path == $pattern ]]`, so `*` also crosses
`/`: `macos/*` covers the whole tree under it. Patterns are split with
globbing off, so a pattern is never expanded against the working tree. A
section with no `# covers:` line is selected for every change, and says why
in a comment: either its checks read every tracked file (lint, the English
check, the declarations' own check) or they depend on the machine rather than
on files (the installed tools' versions).

**Rationale**: the declaration sits beside the checks it describes, so a
reviewer of a new check sees the coverage it needs (constitution VI); it is a
comment, so running the section is unaffected; bash patterns need no new tool.
Absence meaning "always" makes forgetting a declaration slow rather than
unsafe.

**Alternatives**:
- One central map file. Lost: a second place that drifts from the sections.
- Inferring coverage from the paths a section mentions. Lost: sections
  mention paths they only build in fixtures (`bin/env`, `bin/sudo` in a stub
  directory) and omit paths reached indirectly (`macos/machine.sh` through
  `macos/dock.sh`).
- git pathspecs (`:(glob)`). Lost: `**` semantics that differ from bash, and
  one git call per pattern.
- A build graph (Bazel, Nx). Lost: a new toolchain for a shell repository.
- An explicit `# covers: *` for the always-run sections. Lost: two spellings
  for one meaning; a comment saying why serves the reader as well.

## R4 — The selection rule

**Decision**: the staged paths come from `git diff --cached --name-status
--no-renames -z` through `this_repo_git`, which reads the index being
committed (`check.sh` keeps it as `THIS_INDEX`; `git commit -a` and `git
commit <path>` hand the hook a temporary one). `--no-renames` lists a rename
as a deletion of its old path and an addition of its new one, so both sides
select. Then, for each staged path:

- `check.sh`, anything under `githooks/` or `checks/lib/` → every section;
- a section file (`checks/<name>.sh`) added or deleted, or modified with a
  `# covers:` line among its changed lines → every section;
- a section file modified otherwise → that section;
- a path some section's pattern matches → those sections;
- any other path under `checks/` → every section;
- every section with no declaration → selected regardless.

A staged list that cannot be read (git fails) → every section, with a line
saying so. The run prints which sections it did not select, or why it
selected all of them.

**Rationale**: every way the runner, the hooks, the shared helpers or the
declarations themselves change re-runs everything, so no change to the
machinery that picks the checks is judged by the checks it picked. Section
fixtures under `checks/` (feature 003 has `checks/sdd/`) can be declared by
the sections that use them; one nobody declares falls back to everything.

**Alternatives**:
- Every staged section file runs everything. Lost: editing one slow
  integration section would pay for all of them; the declaration-line test
  catches the one change that alters selection.
- Diffing against `HEAD` instead of the index. Lost: wrong for `commit -a`,
  `commit <path>` and partial staging — the index is what is committed.

## R5 — Sections in parallel

**Decision**: every run, full or selected, executes each section in its own
subshell, `( FAILED=0; . section; : > done-marker; exit "$FAILED" )`, with
stdout and stderr in its own file inside one `mktemp -d` directory, at most
`sysctl -n hw.ncpu` at once. The parent polls every 0.1 s: it starts a
section whenever fewer than the cap are running, and prints a section's file
whole as soon as it and every section before it have finished, so the output
is exactly that of a sequential run, in file order. The verdict is the OR of
the subshells' statuses. A section with no done-marker stopped before its last
line — an `exit`, an unset variable under `set -u` — and is a failed section
with a line saying so, not a dead run. Written for bash 3.2: indexed arrays,
`wait` with no arguments only at the end, and polling instead of `wait -n`.

**Rationale**: sections become independent by construction — each subshell
gets the runner's helpers and none of another section's definitions — so a
hidden dependency fails loudly in the very run that used to hide it (spec US2
AS3). Running them one by one in this design found three (2026-10-21):
`checks/70`, `72` and `73` called `machine_fixture` from `checks/60`; `checks/60`
called `one_step_only` from `checks/50`; and `checks/80` called `exec_bits`
from `checks/10` inside an `if`, where "command not found" read as the check
passing. The first two move to shared helpers (R6); the third check moves
beside its function in `checks/10-lint.sh`.

**Collisions**: what two sections could share is (a) scratch paths, (b)
ports, (c) the working tree, (d) the user's real home. (a) every scratch path
in `checks/` comes from `mktemp` (`grep -n mktemp checks/*.sh`: every scratch
directory is a `mktemp -d`, none is a fixed name; no `/tmp/<name>` literal); (b)
no section on `main` listens on a port (`grep -nE 'listen|port|nc -|socat|
http.server' checks/*.sh`: none in code); feature 003's sections are not on
this branch and are reviewed for it when it rebases; (c) the sections that
need a repository build a scratch one or an `rsync` copy, and `install.sh`'s
step 3c, the one that writes into the real repository, is excluded from its
extraction; (d) the sections that run something writing under HOME — the
install steps, dev-nuke, the defaults script, the guards' install cases — set
HOME to a scratch directory on that call (`grep -c 'HOME=' checks/*.sh`), and
the others mention `~` or `$HOME` only in strings they compare or print. Read
from the code, then exercised: the parallel suite run repeatedly, verdicts
and `git status --porcelain` compared (Measurements).

**Alternatives**:
- GNU `parallel` or `xargs -P`. Lost: a new dependency, and the output
  ordering and the verdict still to write.
- Each section as its own executable script. Lost: each would re-source the
  helpers and re-parse the arguments — a second runner in every file.
- `wait <pid>` on the oldest section (a sliding window, no polling). Lost: a
  slow section early in file order holds its slot and every slot behind it
  idle; polling keeps every CPU busy for 0.1 s of latency.
- Parallelism inside a section. Out of scope: sections own their scratch
  layout.

## R6 — Where the shared helpers go

**Decision**: `checks/lib/fixtures.sh` holds `one_step_only` and
`machine_fixture`; `check.sh` sources `checks/lib/*.sh` once, before the
sections, so every section's subshell inherits them. A change there runs
every section (R4). `checks/lib/` is not matched by the section glob
`checks/*.sh`, so it is never run as a section, and the lint globs add it.

**Alternatives**:
- Into `check.sh` itself. Lost: the runner would carry fixtures of four
  sections; `check.sh` is arguments, strictness, the helpers every check uses,
  and the verdict.
- A copy in each section that needs one. Lost: two copies drift.
- Merging the sections that share them. Lost: `checks/60` and `checks/70–73`
  are separate areas; merging them would make selection coarser.

## R7 — The declarations

| section | covers | why |
|---|---|---|
| 05-runner | — | the declarations' check reads every tracked file |
| 10-lint | — | gitleaks reads history and the index, exec bits every tracked file |
| 15-githooks | `githooks/*` | |
| 20-tool-versions | — | compares installed tools, machine state |
| 30-config | — | the English check reads every tracked file |
| 40-statusline | `claude/*statusline*` | |
| 50-install | `install.sh` and every tree it links or reads | step 3 links into a scratch HOME from a copy of the repository |
| 55-dev-nuke | `bin/dev-nuke.sh` | |
| 60-machine-profile | `macos/machine.sh macos/machines/* install.sh Brewfile` | |
| 70–75 | each `macos/<script>` and the manifests and `macos/machine.sh` it reads | |
| 80-git-guard | `claude/git-guard.sh claude/settings.json claude/mcp.json install.sh drift.sh Brewfile uv-tools.txt macos/machines/* checks/*.sh` | its last case greps every section for calls that bypass `this_repo_git` |
| 81-config-guard | `claude/config-guard.sh claude/settings.json install.sh` | |
| 90-spec-kit | `drift.sh bin/sdd-init.sh bin/merge-on-green.sh bin/repo-rules.sh github/repos.json zsh/.zshenv` | |

Generous on purpose: an extra pattern costs a section's seconds on some
commits; a missing one is a hole until CI.

## R8 — Keeping declarations honest

**Decision**: a check in `checks/05-runner.sh` fails on any pattern that
matches no tracked file, naming the section and the pattern (FR-009). It uses
the runner's own parser, so the check and the selection cannot read a
declaration differently. It cannot catch the opposite error, a file a section
exercises but does not declare (spec Assumptions); CI's full run does, later.

## R9 — Constitution principle III's wording

Principle III says the hook, CI and a person "run the same command". They run
the same script; the hook passes `--strict --staged`, a person usually
neither. The hook already passed `--strict` before this feature, so the
principle was already read as "the same script, whose flags choose
strictness"; this feature adds a flag that chooses which of the same checks
run. No amendment is made here (amendments go in a pull request of their own);
whether the wording should say so is the owner's call.

## Measurements

Machine: this Mac, 12 CPUs, bash 3.2.57, 2026-10-21. `real` from `/usr/bin/time -p`.

Before (`main` at 889a751, in a scratch clone):

| case | wall |
|---|---|
| full run, `./check.sh --strict` | 21.8 s |
| hook, docs-only change staged (`docs/checks.md`) | 24.7 s |
| hook, one file one section covers staged (`macos/touchid.sh`) | 23.5 s |

Each section alone, sequential sum: 18.6 s; the slowest, `10-lint`, 2.7 s.

After: pending.
