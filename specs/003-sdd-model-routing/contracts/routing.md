# Contract: the routing table and `sdd-step agent`

## The run bundle

`sdd-run start` resolves the run directory once,
`SDD_RUN_DIR=$(git rev-parse --git-common-dir)/sdd/<run_id>` — git's own
directory, shared by every worktree of the repository and never committed —
exports it to every step, and writes into it before any step runs:

| File | What |
|---|---|
| `lock.json` | run id, `sdd-run`'s process id and its start time (FR-022) |
| `optin.json` | the repository's opt-in as read at start (`sdd.implement`) |
| `check.json` | the repository's check command as read at start (`sdd.check`) |
| `routing.json` | the merged effective table, each value with its layer |
| `profiles/*.json` | copies of the profiles, their hook commands rewritten to the bundle's absolute paths |
| `hooks/` | copies of `config-guard.sh` and `git-guard.sh` |
| `usage.jsonl` | appended by every agent attempt |

Every step reads its routing, profile, hooks and opt-in only from the bundle,
never from the repository or dotfiles, and `resume` reuses the bundle as it
is: what governs a run is fixed from its first step to its last. An opt-out
recorded after start is honoured as a downgrade — implementation runs on
Sonnet — and nothing can upgrade a run to the external provider mid-run
(FR-010). No profile can write the bundle (below).

## Layers (FR-027)

| Precedence | File or source | Versioned | Holds |
|---|---|---|---|
| 1, lowest | `~/dotfiles/claude/speckit/routing.yml` | in dotfiles | every phase's full row: the defaults |
| 2 | `<repo>/.claude/sdd-routing.yml` | in the routed repository | only the fields that repository changes |
| 3 | `<repo>/.claude/sdd-routing.local.yml` | no — `sdd-run routing --init-local` creates it and adds it to `$(git rev-parse --git-common-dir)/info/exclude` | only the owner's local changes |
| 4, highest | `sdd-run start --set <phase>.<field>=<value>` (repeatable) | no | one run's changes |

Overridable fields: a layer may set only `model` — within the row's agent's
family, a Claude id for `claude` rows and a DeepSeek id for `pi` rows —
`effort`, and `timeout`, up or down within the row's `max_timeout`. `agent`,
`profile`, `prompt`, `schema`, `result_to` and `max_timeout` belong to the
defaults alone, and
`routing-layer.schema.json` refuses them in a layer: a layer cannot send code
to another provider, widen a step's permissions, or drop a rule from a prompt.

Merge: per phase, per field; a higher layer replaces a field, never a whole
row, and adds no phase the defaults do not have. `--set` values are typed by
the schema (`timeout=900` is an integer). Validation: each layer
against `claude/speckit/schemas/routing-layer.schema.json`, the merged table
against `routing-table.schema.json`; any failure stops `sdd-run` naming the
layer, phase and field. The merged table is frozen in the run bundle (above);
a copy goes to `.sdd/routing.json` once the feature directory exists, as a
record. `sdd-run routing [--set …]` prints that table from
the repository root without starting a run. A row with `agent: pi` applies
only when `sdd.implement` opts the repository in; otherwise the run uses
`implement-sonnet` and says so, whatever the layers say.

## The defaults, `claude/speckit/routing.yml`

Validated by `./check.sh` against `routing-table.schema.json` (FR-001,
research R2). A row's fields:

| Field | Values | Meaning |
|---|---|---|
| `agent` | `claude` or `pi` | the harness |
| `model` | a full model id (`claude-opus-5-5`, `claude-sonnet-5-5`, `deepseek-flash`) | never an alias (spec, Assumptions) |
| `effort` | `low`, `medium`, `high`, `xhigh`, `max` | `--effort` for Claude, `--thinking` for pi (FR-021) |
| `profile` | a file name in `claude/speckit/profiles/` | the `--settings` the step runs with: permissions, tools (FR-026, research R4) |
| `prompt` | `/speckit-<command>` plus fixed arguments | what the agent is asked; the feature's paths and, for `specify`, the run's `spec` input are appended by the dispatcher |
| `schema` | a file name in `claude/speckit/schemas/`, or absent | passed as `--json-schema`; the result's `structured_output` is written to the step's outcome file (research R10) |
| `result_to` | a path relative to the feature directory, or absent | where the result's text is written (`analyze` → `analysis.md`) |
| `timeout` | seconds, 1 to `max_timeout` | the dispatcher's limit for the step |
| `max_timeout` | seconds; defaults only | the phase's ceiling; the workflow step's `timeout:` is this plus 300, so the dispatcher's limit always fires first (research R11) |

The rows on 2026-10-21:

Timeouts: `timeout` 3600 and `max_timeout` 7200 for every judgment row and for
review and converge; `timeout` 1800 and `max_timeout` 3600 for `tasks` and for
both implement rows. Each workflow step's `timeout:` in `sdd-routed.yml` is its
row's `max_timeout` plus 300, and `./check.sh` asserts the two files agree. A
layer may set `timeout` anywhere from 1 to `max_timeout`; a value beyond it is
refused by `sdd-run`, naming the ceiling (FR-018, research R11). The implement rows carry no schema:
`sdd-step implement` alone writes `implement.json`.

| Phase | agent | model | effort | profile | schema |
|---|---|---|---|---|---|
| `specify` | claude | claude-opus-5-5 | medium | judgment | — |
| `clarify-ask` | claude | claude-opus-5-5 | medium | judgment | clarify |
| `clarify-apply` | claude | claude-opus-5-5 | medium | judgment | — |
| `plan` | claude | claude-opus-5-5 | medium | judgment | — |
| `checklist` | claude | claude-opus-5-5 | medium | judgment | — |
| `analyze` | claude | claude-opus-5-5 | medium | readonly | — |
| `tasks` | claude | claude-sonnet-5-5 | medium | judgment | — |
| `implement-deepseek` | pi | deepseek-flash | high | — (the container is the boundary) | — |
| `implement-sonnet` | claude | claude-sonnet-5-5 | medium | implement-sonnet (composed per pass) | — |
| `review` | claude | claude-opus-5-5 | medium | readonly | review |
| `converge` | claude | claude-opus-5-5 | medium | judgment | converge |

## `sdd-step agent <phase>` (Claude rows)

Runs, from the repository root:

```
claude -p "<row.prompt> <feature paths>" \
  --model <row.model> --effort <row.effort> \
  --permission-mode dontAsk --setting-sources "" \
  --settings "$SDD_RUN_DIR/profiles/<row.profile>.json" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --output-format json [--json-schema <schema>]
```

with `CLAUDE_CODE_EFFORT_LEVEL` unset, stopped after `row.timeout`. Then:

- a result with `is_error` true, a `permission_denials` entry, or no result
  fails the step, naming the cause and, for a denial, the tool and where the
  profile is widened (spec, Edge Cases);
- `structured_output` goes to `.sdd/<phase>.json` when the row has a schema;
- the result's text goes to `row.result_to` when the row names one;
- a start line before the call and an end line after it — run id, phase,
  model, effort given, reported usage and effort — are appended to the run's
  `$SDD_RUN_DIR/usage.jsonl`, the one source
  `sdd-run usage <run_id>` reads (the DeepSeek pass appends the same lines); a start with no end
  is an attempt that reported nothing (FR-021, SC-001). Its stdout is a
  one-line summary; usage is not read from the run's state.

`--setting-sources ""` loads no settings file — not the owner's user
settings, whose allow rules would widen every profile, nor the routed
repository's `.claude/settings*.json` — so the profile passed with
`--settings` is a step's only source of permissions and hooks; each profile
therefore carries the config-guard and git-guard hooks itself (FR-026,
research R4). **Pending**: that this CLI accepts an empty source list, and
that the profile's hooks fire; T003 observes both, and if it does not,
`--setting-sources user` with an empty user allow list checked by `sdd-run`
is the fallback, recorded in research R4, together with what it checks: an
empty user allow list and no user hook other than the guards, which then run
from the user's settings rather than twice. **Pending** too: that project
skills (`/speckit-*`) and the project's CLAUDE.md — the constitution's import —
still load with no setting source; T003 observes it, and the fallback is
chosen by what it shows.

The `pi` row is run by `sdd-step implement` (contracts/sdd-step.md), with
`--model deepseek/<row.model> --thinking <row.effort>`.

## Profiles

| Profile | Allows |
|---|---|
| `judgment` | Read, Glob, Grep; Edit and Write in the worktree, plus `.specify/feature.json` by exact path, which Spec Kit's specify writes; `Bash` for each named Spec Kit script the phases run (`check-prerequisites.sh`, `setup-plan.sh`, `setup-tasks.sh`, `create-new-feature.sh`), with any arguments; read-only git |
| `readonly` | Read, Glob, Grep; read-only git |
| `implement-sonnet` | Read, Glob, Grep; Edit and Write limited to the pass's checkout; `Bash(<sdd.check>)` — not a file in `profiles/`: composed per pass by `sdd-step implement` (FR-023) |

"Read-only git" is exactly `Bash(git status:*)`, `Bash(git diff:*)`,
`Bash(git log:*)`, `Bash(git show:*)`, `Bash(git rev-parse:*)` and
`Bash(git branch --show-current)`; `git config`, `git commit` and every other
subcommand are denied.

Every profile is `dontAsk`: what it does not allow is denied, never asked.
Every profile denies Edit and Write on the git common directory (by absolute
path, so linked worktrees are covered), `.claude/**`, `.specify/**`,
`.sdd/**` (but `.specify/feature.json`), `CLAUDE.md`, `AGENTS.md` and `.git`
at any depth (a worktree's `.git` file included), and the run bundle: no step
can change a skill, a Spec Kit script, the instructions a later step loads,
an outcome file, the routing or its own permissions. Every profile also turns
on Claude Code's Bash sandbox (`sandbox.enabled`, `allowUnsandboxedCommands:
false`, no allowed network domain, writes limited to the worktree minus those
paths), so the operating system enforces the same limits on whatever a
permitted command runs (code.claude.com, sandboxing).
Profiles differ in permission rules only, never in the tools offered, so
the tool definitions — part of the cached prefix — stay the same across a
same-model group (research R16).
