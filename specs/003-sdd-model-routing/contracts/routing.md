# Contract: the routing table and `sdd-step agent`

## `claude/speckit/routing.yml`

One row per phase, validated against `claude/speckit/schemas/routing-table.schema.json`
by `sdd-run` before any step and by `./check.sh` (FR-001, research R2). A
row's fields:

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

| Phase | agent | model | effort | profile | schema |
|---|---|---|---|---|---|
| `specify` | claude | claude-opus-5-5 | medium | judgment | — |
| `clarify-ask` | claude | claude-opus-5-5 | medium | judgment | clarify |
| `clarify-apply` | claude | claude-opus-5-5 | medium | judgment | — |
| `plan` | claude | claude-opus-5-5 | medium | judgment | — |
| `checklist` | claude | claude-opus-5-5 | medium | judgment | — |
| `analyze` | claude | claude-opus-5-5 | medium | readonly | — |
| `tasks` | claude | claude-sonnet-5-5 | medium | judgment | — |
| `implement-deepseek` | pi | deepseek-flash | high | — (the container is the boundary) | implement |
| `implement-sonnet` | claude | claude-sonnet-5-5 | medium | implement-sonnet | implement |
| `review` | claude | claude-opus-5-5 | medium | readonly | review |
| `converge` | claude | claude-opus-5-5 | medium | judgment | converge |

## `sdd-step agent <phase>` (Claude rows)

Runs, from the repository root:

```
claude -p "<row.prompt> <feature paths>" \
  --model <row.model> --effort <row.effort> \
  --permission-mode dontAsk --settings claude/speckit/profiles/<row.profile>.json \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --output-format json [--json-schema <schema>]
```

with `CLAUDE_CODE_EFFORT_LEVEL` unset, stopped after `row.timeout`. Then:

- a result with `is_error` true, a `permission_denials` entry, or no result
  fails the step, naming the cause and, for a denial, the tool and where the
  profile is widened (spec, Edge Cases);
- `structured_output` goes to `.sdd/<phase>.json` when the row has a schema;
- the result's text goes to `row.result_to` when the row names one;
- the step's model, effort, reported usage and reported effort are appended
  to `.sdd/usage.jsonl` for `sdd-run usage` (FR-021, SC-001).

The `pi` row is run by `sdd-step implement` (contracts/sdd-step.md), with
`--model deepseek/<row.model> --thinking <row.effort>`.

## Profiles

| Profile | Allows |
|---|---|
| `judgment` | Read, Edit, Write, Glob, Grep; `Bash(.specify/scripts/bash/*)`; read-only git |
| `readonly` | Read, Glob, Grep; read-only git |
| `implement-sonnet` | Read, Glob, Grep; Edit and Write limited to the pass's checkout; `Bash(<sdd.check>)` — composed per pass by `sdd-step implement` (FR-023) |

Every profile is `dontAsk`: what it does not allow is denied, never asked.
