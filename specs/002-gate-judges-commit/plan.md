# Implementation Plan: The commit gate judges the commit

**Branch**: `002-gate-judges-commit` | **Date**: 2026-10-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-gate-judges-commit/spec.md`

## Summary

`githooks/pre-commit` builds a judging tree from the index git hands it — a
throwaway repository borrowing this one's objects, with the commit's parent
as `HEAD` — runs `check.sh --strict` there, and removes it on every exit path
([research R1-R3](research.md)). `THIS_INDEX` and `this_repo_git`, which let
the checks read the commit's index from the working tree, are removed with
the tests that only covered them (R4).

## Technical Context

**Language/Version**: bash (the hook and checks, 3.2-compatible).

**Primary Dependencies**: git ≥ 2.5 for `--git-common-dir`; nothing new.

**Storage**: N/A

**Testing**: `./check.sh`; `pre_commit_gate` reworked (R5).

**Target Platform**: macOS, laptop and CI.

**Project Type**: shell tooling (dotfiles).

**Performance Goals**: a gated commit no more than 5 s slower (SC-003).

**Constraints**: nothing written to the user's working tree, index, stash,
refs or `.git` (FR-002).

**Scale/Scope**: `githooks/pre-commit`, `check.sh`, `checks/10-lint.sh`,
`checks/15-githooks.sh`, `checks/30-config.sh`, `checks/80-git-guard.sh`,
`docs/checks.md`.

## Constitution Check

| Principle | Verdict |
|---|---|
| I-II | Not touched. |
| III. One gate, seen red | The gate's new behaviour gets checks seen red per scenario (FR-005). |
| IV. Apply and report | Not touched. |
| V. Upstream's files | Not touched. |
| VI. The why beside the subject | The hook carries R1-R3's reasons as comments. |

Post-design re-check: unchanged.

## Project Structure

```text
githooks/pre-commit      # builds the judging tree, runs check.sh there, cleans up
check.sh                 # THIS_INDEX and this_repo_git removed
checks/10-lint.sh        # exec_bits calls git
checks/15-githooks.sh    # pre_commit_gate reworked
checks/30-config.sh      # english_only calls git; index part of its contract removed
checks/80-git-guard.sh   # THIS_INDEX parts of hook_git_env_dropped removed
docs/checks.md           # says the hook judges the commit
```

## Complexity Tracking

No violations.
