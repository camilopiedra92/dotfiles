# Implementation Plan: Checks for the scripts with logic and no check

**Branch**: `001-script-checks` | **Date**: 2026-10-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-script-checks/spec.md`

## Summary

Four scripts with logic of their own have no check: `githooks/pre-push`,
`githooks/pre-commit`, `bump-tools.sh` and `bin/dev-nuke.sh`. Each gets a
check in `checks/` that drives the real script against scratch fixtures —
scratch git repositories, synthetic pin files, stub commands — and is seen red
once per acceptance scenario with the script broken by hand. The reset runs
under a hermetic `PATH`, so a command the stubs miss fails rather than acts.
The only script change is an environment default for the reset's socket path
([research R6](research.md#r6-the-socket-path)).

## Technical Context

**Language/Version**: bash 3.2 (macOS `/bin/bash`) for the checks, like the
rest of `checks/`.

**Primary Dependencies**: none new; git, coreutils already on the machine and
the runner.

**Storage**: N/A

**Testing**: `./check.sh`, which sources `checks/*.sh`; shellcheck and shfmt
cover the new files through `checks/10-lint.sh`.

**Target Platform**: macOS on Apple Silicon, laptop and the CI runner.

**Project Type**: shell tooling (dotfiles).

**Performance Goals**: the four checks add under 10 s to a full run (SC-003).

**Constraints**: no network, no real remote, no process, socket, DNS or memory
touched; nothing written outside a `mktemp -d` directory removed on return.

**Scale/Scope**: 4 scripts, 24 acceptance scenarios, 3 files in `checks/`,
one line changed in `bin/dev-nuke.sh`, one paragraph in `docs/checks.md`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict |
|---|---|
| I. Declared, never hand-installed | Not touched: nothing installed. |
| II. One owner per layer | Not touched. |
| III. One gate, seen red | This feature's purpose: four scripts gain checks, each seen red per scenario (FR-004). Passes once delivered. |
| IV. Apply and report are twins | Not touched. |
| V. Upstream's files stay upstream's | The pin-updater check uses synthetic pin files, never the real `ci.yml` or checksums. Passes. |
| VI. The why beside the subject | Each stub set and the socket default carry a comment with their reason. Passes. |

Post-design re-check: unchanged; the one script change (R6) keeps the
script's normal behaviour (FR-005).

## Project Structure

### Documentation (this feature)

```text
specs/001-script-checks/
├── plan.md
├── research.md
├── quickstart.md
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

No `data-model.md` (no data) and no `contracts/` (nothing external consumes
these checks).

### Source Code (repository root)

```text
checks/
├── 15-githooks.sh       # new: pre-commit and pre-push
├── 20-tool-versions.sh  # + bump-tools.sh
└── 55-dev-nuke.sh       # new: dev-nuke under a hermetic PATH
bin/dev-nuke.sh          # socket path read from DEV_NUKE_PG_SOCKET, default unchanged
docs/checks.md           # the summary paragraph names the new checks
```

**Structure Decision**: the existing one-file-per-area layout of `checks/`
([research R1](research.md#r1-where-the-checks-live)).

## Complexity Tracking

No violations.
