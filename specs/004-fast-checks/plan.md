# Implementation Plan: Fast tiered checks

**Branch**: `004-fast-checks` | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/004-fast-checks/spec.md`

## Summary

`check.sh` gains a selection mode, `--staged`, that runs only the sections the
staged paths can affect, chosen from `# covers:` lines in each section and a
fail-safe rule that runs everything on any doubt (research R3, R4); the
pre-commit hook uses it. Every run, selected or full, executes each section in
its own subshell, several at once, and prints each section's output whole and
in file order with one verdict (R5). The helpers more than one section needs
move to `checks/lib/`, which the runner gives every section (R6). CI keeps
running the whole suite and stays the merge gate (R1); no pre-push tier (R2).

## Technical Context

**Language/Version**: bash 3.2.57, the macOS `/bin/bash` that `/usr/bin/env
bash` resolves to here (`which bash` → `/bin/bash`, 2026-10-21) and on the CI
runner: no `wait -n`, no associative arrays, no `mapfile`
**Primary Dependencies**: git, `sysctl -n hw.ncpu`; no new tool
**Storage**: each run's section output and status in one `mktemp -d`
directory, removed on exit
**Testing**: the repository's own `check.sh`; a new section, `checks/05-runner.sh`,
drives scratch copies of `check.sh` against fake sections in scratch
repositories; `checks/15-githooks.sh` keeps the hook's contract
**Target Platform**: macOS (Apple Silicon), as the rest of the repository
**Project Type**: shell tooling
**Performance Goals**: the hook on a documentation-only commit at most a
quarter of the full run; the full run below the sum of its sections (spec
SC-001, SC-003)
**Constraints**: one runner (docs/checks.md); strictness and verdict
unchanged; fail safe on any doubt about what a change affects
**Scale/Scope**: 17 sections and 145 tracked files on `main`; 23 sections on
feature 003's branch, four of them 21–100 s

## Constitution Check

*GATE: before Phase 0, re-checked after Phase 1.*

- **I. Declared, never hand-installed**: no new tool. Pass.
- **II. One owner per layer**: not affected. Pass.
- **III. One gate, seen red**: the hook, CI and a person still run
  `check.sh`, and each check means the same everywhere; the hook already
  passed a flag of its own (`--strict`), and now passes a second that chooses
  which of the same checks run. CI, which the ruleset requires green to merge,
  runs them all (R1). The selection, the fail-safe rule, the parallel runner,
  the early-stop rule and the declaration check are logic of their own: each
  gets a check in `checks/05-runner.sh` seen red on the behaviour broken by
  hand. The hook's changed contract is held by `checks/15-githooks.sh`, seen
  red first. Pass. Wording is unchanged; whether "run the same command" should
  say "the same script" is left to the owner (research R9).
- **IV. Apply and report are twins**: not applicable.
- **V. Upstream's files stay upstream's**: not applicable.
- **VI. The why beside the subject**: each `# covers:` line sits in the
  section it describes, and a section with none says why; docs/checks.md
  explains the tiers. Pass.

Post-design re-check: unchanged. Pass.

## Project Structure

### Documentation (this feature)

```text
specs/004-fast-checks/
├── spec.md
├── plan.md
├── research.md
├── quickstart.md
├── contracts/check-cli.md
├── checklists/requirements.md
└── tasks.md
```

No `data-model.md`: the only entities are the section, its declaration and the
shared helpers, defined in the contract.

### Source Code (repository root)

```text
check.sh                 # + --staged, the selection, the parallel runner
githooks/pre-commit      # runs check.sh --strict --staged
checks/lib/fixtures.sh   # new: one_step_only, machine_fixture (from 50, 60)
checks/05-runner.sh      # new: the runner's own checks, and the declarations' honesty
checks/*.sh              # + `# covers:` lines; 80-git-guard's exec_bits case moves to 10-lint
checks/10-lint.sh        # lints checks/lib/ too
docs/checks.md, README.md, CLAUDE.md   # the tiers, the declaration, the parallel run
```

## Complexity Tracking

None.
