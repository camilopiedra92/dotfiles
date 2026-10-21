# Implementation Plan: Model routing per Spec Kit phase

**Branch**: `003-sdd-model-routing` | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/003-sdd-model-routing/spec.md`

## Summary

A Spec Kit workflow, `sdd-routed`, runs each phase of a feature as its own
step: Opus for specify, clarify, plan, checklist, analyze, review and
converge; Sonnet for tasks; DeepSeek V4 Flash through the pi coding agent for
implementation, in a disposable checkout inside an Apple `container` VM; and
verify with no model, as the repository's check command. Every step leaves a
JSON outcome file validated against a schema, and the run branches only on
those. `sdd-run` is what the owner types; `sdd-step` is what the workflow's
deterministic steps call; `sdd-init` installs the workflow. Decisions and what
lost: [research.md](research.md).

## Technical Context

**Language/Version**: Bash for `sdd-run` and `sdd-step` (the repository's
scripts are Bash; `shellcheck` and `shfmt` run in `./check.sh`); YAML for the
workflow (Spec Kit workflow schema 1.0); JSON Schema (draft 2020-12) for the
outcome files; a Containerfile for the worker image.

**Primary Dependencies**: Spec Kit CLI 1.1.3 (workflow engine, `uv-tools.txt`);
Claude Code CLI; new and approved by the owner on 2026-10-21: Apple
`container` 1.5.0 (`Brewfile`), `check-jsonschema` (`uv-tools.txt`), and,
inside the image only, Node 26, `@earendil-works/pi-coding-agent@1.3.0`, mise
and uv.

**Storage**: files only — the feature directory and its `.sdd/` outcome files,
the run state Spec Kit keeps under `.specify/workflows/runs/`, local git
config (`sdd.implement`, `sdd.check`), the Keychain item `deepseek-api`.

**Testing**: `./check.sh`; a new `checks/91-sdd-routing.sh` driving `sdd-run`,
`sdd-step` and the workflow against stand-ins for `claude`, `container`,
`security` and `specify` in scratch repositories, never the network. The
schemas are checked against valid and invalid sample outcomes.

**Target Platform**: this Mac, macOS on Apple Silicon (constitution preamble).

**Project Type**: developer environment (scripts, manifests, checks).

**Performance Goals**: none of its own; SC-001 is a usage target.

**Constraints**: the credential never where FR-009 lists; no edit to Spec
Kit's files (constitution V); the agent sees only its checkout and its run's
cache (FR-007).

**Scale/Scope**: one owner, a handful of features a week, at most a few runs
at once in separate worktrees.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | How this plan meets it |
|---|---|
| I. Declared, never hand-installed | `container` in the `Brewfile`, `check-jsonschema` in `uv-tools.txt` with a pinned reference; everything in the image from `containers/pi-worker/Containerfile`, pinned (base by digest, pi by version); the workflow, settings and schemas live here and reach repositories through `sdd-init`. Docker Desktop, found installed and undeclared, is reported, not used. |
| II. One owner per layer | `container` is a program, so Homebrew; `check-jsonschema` a Python application, so `uv tool`; Node, pi, mise and uv only inside the image; the credential in the Keychain, entering the VM on stdin. |
| III. One gate, seen red | `sdd-run` and `sdd-step` have logic of their own; each behaviour gets a check in `checks/91-sdd-routing.sh`, seen red with it broken by hand. The workflow and the schemas are driven by the same checks. |
| IV. Apply and report are twins | The machine changes only through the `Brewfile`, `uv-tools.txt` and two links in `install.sh`, which `./drift.sh` already reports on. The worker image and the per-run cache volumes are caches, rebuilt or removed by `sdd-step`. |
| V. Upstream's files stay upstream's | No file Spec Kit installs is edited, and its run state is never written by our scripts; the workflow reaches a repository only through `specify workflow add`; `config-guard.sh` is reused unchanged. |
| VI. The why beside the subject | Each non-obvious line carries its reason and date; the probes and sources behind the design are cited from research.md. |

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
│   ├── sdd-run.md          # the owner's command
│   ├── sdd-step.md         # the workflow's deterministic steps and the worker
│   └── workflow.md         # sdd-routed's steps, models, gates, loops, outcomes
└── tasks.md
```

### Source Code (repository root)

```text
Brewfile                         # + container
uv-tools.txt                     # + check-jsonschema
bin/
├── sdd-init.sh                  # + installs sdd-routed
├── sdd-run.sh                   # new
└── sdd-step.sh                  # new
claude/speckit/
├── sdd-routed.yml               # new: the workflow
├── routing-settings.json        # new: allow list for headless Claude steps
└── schemas/                     # new: one JSON Schema per outcome file
    ├── clarify.schema.json
    ├── implement.schema.json
    ├── verify.schema.json
    ├── review.schema.json
    └── converge.schema.json
containers/pi-worker/
├── Containerfile                # new
├── entrypoint.sh                # new: reads the credential from stdin
├── models.json                  # new: DeepSeek provider entry for pi
├── egress.txt                   # new: the hosts the worker may reach
└── brief.md                     # new: the implementing agent's rules (FR-017)
checks/91-sdd-routing.sh         # new
docs/sdd-routing.md              # new: how to run it, and the eval's result
install.sh                       # + links sdd-run and sdd-step into ~/.local/bin
```

**Structure Decision**: everything lives in dotfiles, beside `sdd-init`, which
already owns how Spec Kit reaches a repository. Each repository gets its own
copy of the workflow through `specify workflow add`, but the steps call
`sdd-step` and read the settings and schemas on this machine, so the workflow
and what it calls move together; a separate repository, as the presets have,
would split them across two release streams.

## Phase order

The first tasks settle every "pending" in research.md on this machine before
anything is built on it: `container`'s macOS requirement, egress control and a
throwaway run (R5); a denied tool in `-p` (R4); gate options other than
approve (R3); what a failed, resumed and killed run leaves in `state.json`
(R11, R12); and config-guard on an empty `Write` and a lost `pyproject.toml`
table (R7). A pending item that comes out against the design stops the work
and goes to the owner, as the global instructions require.

## Complexity Tracking

None: the Constitution Check has no violation.
