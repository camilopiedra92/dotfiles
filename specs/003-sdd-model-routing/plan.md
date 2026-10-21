# Implementation Plan: Model routing per Spec Kit phase

**Branch**: `003-sdd-model-routing` | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/003-sdd-model-routing/spec.md`

## Summary

A Spec Kit workflow, `sdd-routed`, orchestrates a feature's phases —
order, checkpoints, loops, resume — and every agent step goes through one
dispatcher, `sdd-step agent`, that reads a declarative routing table: per
phase, the agent, model, effort, permission profile, output schema and time
limit. Opus for specify, clarify, plan, checklist, analyze, review and
converge; Sonnet for tasks; DeepSeek through the pi coding agent for
implementation; every agent step and every verify a contained pass
(contracts/pass.md) — an export with no `.git`, the agent in the worker
container, whose only destination is the run's egress proxy, its output a
patch judged against the step's writes before it is applied; verify with no model, as the
repository's check command. Each step loads only its profile's context — no
MCP servers — so same-model steps reuse the prompt cache. Every step whose
result is read leaves a JSON outcome file, structured at generation with
`--json-schema` where the agent produces it, validated against its schema,
and the run branches only on those. `sdd-run` is what the owner types; `sdd-step` is what the workflow's
deterministic steps call; `sdd-init` installs the workflow. Decisions and what
lost: [research.md](research.md).

## Technical Context

**Language/Version**: Bash for `sdd-run` and `sdd-step` (the repository's
scripts are Bash; `shellcheck` and `shfmt` run in `./check.sh`); YAML for the
workflow (Spec Kit workflow schema 1.0); JSON Schema (draft 2020-12) for the
outcome files; a Containerfile for the worker image.

**Primary Dependencies**: Spec Kit CLI 1.2.2 (workflow engine; the floor,
since every check runs against it, research R15; `uv-tools.txt`, moved in
dotfiles PR #154);
Claude Code CLI; new and approved by the owner on 2026-10-21: a container
runtime — Apple `container` 1.5.0, or colima if `container` cannot run the
firewall (research R5) — in the `Brewfile`, `check-jsonschema`
(`uv-tools.txt`), and, inside the image only, Node, `iptables`/`ipset`,
`@earendil-works/pi-coding-agent@1.3.0`, the Claude Code CLI at a pinned version, mise
and uv.

**Storage**: files only — the feature directory and its `.sdd/` outcome files,
the run state Spec Kit keeps under `.specify/workflows/runs/`, local git
config (`sdd.implement`, `sdd.check`), the Keychain items `claude-oauth` and
`deepseek-api`, read only by the run's egress proxy and judge.

**Testing**: `./check.sh`; a new `checks/91-sdd-routing.sh` driving `sdd-run`,
`sdd-step` and the workflow on the real Spec Kit engine, against stand-ins
for `claude`, the container runtime and `security` in scratch repositories, never the
network; CI installs the engine and `check-jsonschema` at their pins. The
schemas are checked against valid and invalid sample outcomes.

**Target Platform**: this Mac, macOS on Apple Silicon (constitution preamble).

**Project Type**: developer environment (scripts, manifests, checks).

**Performance Goals**: none of its own; SC-001 is a usage target.

**Constraints**: the credential never where FR-009 lists; no edit to Spec
Kit's files (constitution V); the agent sees only its export and its pass's
cache (FR-007).

**Scale/Scope**: one owner, a handful of features a week, at most a few runs
at once in separate worktrees.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | How this plan meets it |
|---|---|
| I. Declared, never hand-installed | `/usr/bin/python3`, which the egress proxy and config-guard run on, comes with the Command Line Tools that Homebrew's installer, an allowed bootstrap, installs; the container runtime (research R5) in the `Brewfile`, `check-jsonschema` in `uv-tools.txt` with a pinned reference; everything in the image from `containers/worker/Containerfile`, every input pinned by hash and the result checked against a committed inventory (FR-032, research R26); the workflow, settings and schemas live here and reach repositories through `sdd-init`. Docker Desktop, found installed and undeclared, is reported, not used. |
| II. One owner per layer | the container runtime is a program, so Homebrew; `check-jsonschema` a Python application, so `uv tool`; Node, pi, mise and uv only inside the image; the credentials in the Keychain, held only by the run's egress proxy on the host (research R23). |
| III. One gate, seen red | `sdd-run` and `sdd-step` have logic of their own; each behaviour gets a check in `checks/91-sdd-routing.sh`, seen red with it broken by hand; so do `init-firewall.sh` and `entrypoint.sh`, adapted from Anthropic's reference and owned here, not vendored (research R6). The workflow and the schemas are driven by the same checks. |
| IV. Apply and report are twins | The machine changes only through the `Brewfile`, `uv-tools.txt`, two links in `install.sh`, and — if T002 finds the chosen runtime's first start leaves state — an apply step in `install.sh` with its report in `./drift.sh`. CI gains `uv` the way it installs its other tools. The worker image and the per-run cache volumes are caches, rebuilt or removed by `sdd-step`. |
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
│   ├── routing.md          # the routing table, its layers and the dispatcher
│   ├── pass.md             # the contained pass every agent step and verify run
│   └── workflow.md         # sdd-routed's steps, models, gates, loops, outcomes
└── tasks.md
```

### Source Code (repository root)

```text
Brewfile                         # + the container runtime (research R5)
uv-tools.txt                     # + check-jsonschema
bin/
├── sdd-init.sh                  # + installs sdd-routed
├── sdd-run.sh                   # new
├── sdd-step.sh                  # new
└── sdd-egress-proxy.py          # new: the run's egress proxy, Python standard library
claude/speckit/
├── sdd-routed.yml               # new: the workflow
├── routing.yml                  # new: the routing table, one row per phase
├── profiles/                    # new: author, reader, implementer (inside the container)
└── schemas/                     # new: the routing table's and each outcome file's
    ├── routing-table.schema.json
    ├── routing-layer.schema.json
    ├── route.schema.json
    ├── routing.schema.json
    ├── phases.schema.json
    ├── clarify.schema.json
    ├── implement.schema.json
    ├── verify.schema.json
    ├── review.schema.json
    └── converge.schema.json
containers/worker/
├── Containerfile                # new
├── init-firewall.sh             # new: deny-by-default egress, Anthropic's reference pattern
├── entrypoint.sh                # new: the firewall first, then the agent or check command as node
├── models.json                  # new: DeepSeek provider entry for pi
├── egress-registries.txt        # new: package registries, read-only through the proxy's TLS inspection (FR-031, R25)
├── package.json                 # new: the Claude Code CLI and pi, for npm ci (FR-032, R26)
├── package-lock.json            # new: their whole tree with integrity hashes
├── inventory.sh                 # new: lists every Debian and npm package the image installs, with its version
├── inventory.txt                # new: that list for the committed recipe; prepare-worker refuses a build that differs
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
anything is built on it: which container runtime runs the firewall, and a
throwaway run (R5); a denied tool in `-p` (R4); gate options other than
approve (R3); what a failed, resumed and killed run leaves in `state.json`
(R11, R12); and config-guard on an empty `Write` and a lost `pyproject.toml`
table (R7). A pending item that comes out against the design stops the work
and goes to the owner, as the global instructions require.

## Complexity Tracking

None: the Constitution Check has no violation.
