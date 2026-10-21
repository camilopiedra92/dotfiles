# Contract: the routing table and `sdd-step agent`

## Layers (FR-027)

| Precedence | File or source | Versioned | Holds |
|---|---|---|---|
| 1, lowest | `~/dotfiles/claude/speckit/routing.yml` | in dotfiles | every phase's full row: the defaults |
| 2 | `<repo>/.claude/sdd-routing.yml` | in the routed repository | only the fields that repository changes |
| 3 | `<repo>/.claude/sdd-routing.local.yml` | no — `sdd-run` adds it to the repository's `.git/info/exclude` when it creates it | only the owner's local changes |
| 4, highest | `sdd-run start --set <phase>.<field>=<value>` (repeatable) | no | one run's changes |

Merge: per phase, per field; a higher layer replaces a field, never a whole
row, and adds no phase the defaults do not have. Validation: each layer
against `claude/speckit/schemas/routing-layer.schema.json`, the merged table
against `routing-table.schema.json`; any failure stops `sdd-run` naming the
layer, phase and field. Record: `.sdd/routing.json` holds the effective table
with each value's layer. `sdd-run routing [--set …]` prints that table from
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
| `timeout` | seconds | the dispatcher's limit; the workflow step's `timeout:` is this plus 300 (research R11) |

The rows on 2026-10-21:

Timeouts: 3600 seconds for every judgment row and for review and converge,
1800 for `tasks` and for both implement rows. The workflow's step `timeout:`
is the default row's value plus 300, fixed in `sdd-routed.yml`; a layer may
lower a row's `timeout` but not raise it above the workflow's minus 300, which
`sdd-run` refuses (FR-018, research R11). The implement rows carry no schema:
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
  --permission-mode dontAsk --setting-sources user \
  --settings claude/speckit/profiles/<row.profile>.json \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --output-format json [--json-schema <schema>]
```

with `CLAUDE_CODE_EFFORT_LEVEL` unset, stopped after `row.timeout`. Then:

- a result with `is_error` true, a `permission_denials` entry, or no result
  fails the step, naming the cause and, for a denial, the tool and where the
  profile is widened (spec, Edge Cases);
- `structured_output` goes to `.sdd/<phase>.json` when the row has a schema;
- the result's text goes to `row.result_to` when the row names one;
- a start line before the call and an end line after it — phase, model,
  effort given, reported usage and effort — are appended to
  `.sdd/usage.jsonl`, the one source `sdd-run usage` reads; a start with no end
  is an attempt that reported nothing (FR-021, SC-001). Its stdout is a
  one-line summary; usage is not read from the run's state.

`--setting-sources user` loads the owner's user settings — the
config-guard and git-guard hooks — and not the routed repository's
`.claude/settings*.json`, whose allow rules would otherwise widen the
profile (FR-026, research R4).

The `pi` row is run by `sdd-step implement` (contracts/sdd-step.md), with
`--model deepseek/<row.model> --thinking <row.effort>`.

## Profiles

| Profile | Allows |
|---|---|
| `judgment` | Read, Edit, Write, Glob, Grep; `Bash(.specify/scripts/bash/*)`; read-only git |
| `readonly` | Read, Glob, Grep; read-only git |
| `implement-sonnet` | Read, Glob, Grep; Edit and Write limited to the pass's checkout; `Bash(<sdd.check>)` — not a file in `profiles/`: composed per pass by `sdd-step implement` (FR-023) |

Every profile is `dontAsk`: what it does not allow is denied, never asked.
Profiles differ in permission rules only, never in the tools offered, so
the tool definitions — part of the cached prefix — stay the same across a
same-model group (research R16).
