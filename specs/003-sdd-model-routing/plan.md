# Implementation Plan: Model routing per Spec Kit phase

**Branch**: `003-sdd-model-routing` | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/003-sdd-model-routing/spec.md`

## Summary

A Spec Kit workflow, `sdd-routed`, runs each phase of a feature as its own
headless agent process on the model routed to it: Opus for specify, clarify,
plan, checklist, analyze, review and converge; Sonnet for tasks and verify;
DeepSeek V4 Flash through the pi coding agent for implementation, inside an
Apple `container` VM that sees only the feature's worktree. A launcher,
`sdd-run`, checks the prerequisites, sets the headless permission mode and
starts or resumes the run. `sdd-init` installs the workflow. Decisions and
what lost: [research.md](research.md).

## Technical Context

**Language/Version**: Bash for the launcher and the runner (the repository's
scripts are Bash; `shellcheck` and `shfmt` in `./check.sh`); YAML for the
workflow (Spec Kit workflow schema 1.0); a Containerfile for the worker image.

**Primary Dependencies**: Spec Kit CLI 1.1.3 (workflow engine, `uv-tools.txt`);
Claude Code CLI; Apple `container` 1.5.0 (Homebrew, new); inside the image
only: Node 26, `@earendil-works/pi-coding-agent@1.3.0`, mise, uv.

**Storage**: files only — the feature directory, the run state Spec Kit keeps
under `.specify/workflows/runs/`, local git config for the opt-in, the
Keychain item `deepseek-api` for the credential.

**Testing**: `./check.sh`; a new `checks/91-sdd-routing.sh` driving `sdd-run`,
the runner and the workflow against stand-ins for `claude`, `container`,
`security` and `specify` in scratch repositories, never the network.

**Target Platform**: this Mac, macOS on Apple Silicon (constitution preamble).

**Project Type**: developer environment (scripts, manifests, checks).

**Performance Goals**: none of its own; SC-001 is a usage target.

**Constraints**: the credential never in a file or the run state (FR-009); no
edit to Spec Kit's files (constitution V); the worker sees only the worktree
(FR-007).

**Scale/Scope**: one owner, a handful of features a week, at most a few runs
at once in separate worktrees.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | How this plan meets it |
|---|---|
| I. Declared, never hand-installed | `container` goes in the `Brewfile`; everything in the image comes from `containers/pi-worker/Containerfile`, pinned (base by digest, pi by version); the workflow file lives here and reaches repositories through `sdd-init`. Docker Desktop, found installed and undeclared, is reported, not used. |
| II. One owner per layer | `container` is a program, so Homebrew; Node, pi, mise and uv exist only inside the image; the credential lives in the Keychain and enters the container on stdin. |
| III. One gate, seen red | `sdd-run` and the runner have logic of their own (prerequisite checks, opt-in branch, guarded-file verdict, usage sum): each gets checks in `checks/91-sdd-routing.sh`, each seen red with the behaviour broken by hand. The workflow file is driven by the same checks through a stand-in `claude`. |
| IV. Apply and report are twins | Nothing here changes the machine outside the Brewfile line and two links, which `install.sh` and `./drift.sh` already cover. The worker image is a cache keyed by the Containerfile's hash, rebuilt when missing. |
| V. Upstream's files stay upstream's | No file Spec Kit installs is edited; the workflow is installed through `specify workflow add`, and `config-guard.sh` is reused unchanged. |
| VI. The why beside the subject | Each non-obvious line carries its reason and date; the probes behind the design are cited from research.md. |

Result: passes; no violation to justify. Re-checked after design: unchanged.

## Project Structure

### Documentation (this feature)

```text
specs/003-sdd-model-routing/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── sdd-run.md          # the launcher's command line and outcomes
│   ├── worker.md           # the runner: what goes in and out of the container
│   └── workflow.md         # sdd-routed's steps, models, gates and loops
└── tasks.md
```

### Source Code (repository root)

```text
Brewfile                         # + container
bin/
├── sdd-init.sh                  # + installs sdd-routed
├── sdd-run.sh                   # new: launcher (start, resume, usage)
└── sdd-implement-worker.sh      # new: runs pi in the container, judges its diff
claude/speckit/
├── sdd-routed.yml               # new: the workflow
└── routing-settings.json        # new: allow list for headless Claude phases
containers/pi-worker/
├── Containerfile                # new
├── entrypoint.sh                # new: reads the credential from stdin
├── models.json                  # new: DeepSeek provider entry for pi
└── brief.md                     # new: the worker's rules (test-first, scope, no config edits)
checks/91-sdd-routing.sh         # new
docs/sdd-routing.md              # new: how to run it, and why it is built so
install.sh                       # + links sdd-run and the worker into ~/.local/bin
```

**Structure Decision**: everything lives in dotfiles, beside `sdd-init`, which
already owns how Spec Kit reaches a repository. Each repository gets its own
copy of the workflow through `specify workflow add`, but the steps call
`sdd-implement-worker` and read `routing-settings.json` on this machine, so
the workflow and the scripts it calls must move together; a separate
repository, as the presets have, would split them across two release
streams.

## Complexity Tracking

None: the Constitution Check has no violation.
