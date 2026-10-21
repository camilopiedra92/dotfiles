# Data model: Model routing per Spec Kit phase

No database: each entity is a file or a setting that already has an owner.

| Entity | Where it lives | Fields that matter | Written by |
|---|---|---|---|
| Workflow | `claude/speckit/sdd-routed.yml`, copied into each repository's `.specify/workflows/` by `specify workflow add` | `version`; gate `verdict_input`; loop `max_iterations`; step `timeout`; no model, effort or permission (contracts/workflow.md) | this repository, through `sdd-init` |
| Run | `.specify/workflows/runs/<run_id>/` (`state.json`, `inputs.json`, `log.jsonl`), Spec Kit's, read-only to our scripts | status (`running`, `paused`, `completed`, `failed`, `aborted`), current step, each step's `output` (a Claude step's JSON result with `total_cost_usd` and `modelUsage`) | Spec Kit's engine |
| Routing table | defaults `claude/speckit/routing.yml`; project `<repo>/.claude/sdd-routing.yml`; local `<repo>/.claude/sdd-routing.local.yml`; a run's `--set` — merged per FR-027 | per phase: `agent`, `model`, `effort`, `profile`, `prompt`, `schema`, `result_to`, `timeout` (contracts/routing.md) | this repository |
| Usage log | `<feature>/.sdd/usage.jsonl` | one line per agent step attempt: phase, model, effort given, effort and usage reported | `sdd-step agent`, `sdd-step implement` |
| Outcome files | `<feature>/.sdd/<step>.json`, one schema each in `claude/speckit/schemas/` | below | the step named |
| Clarify questions | `<feature>/clarify-questions.md` (Markdown, for the owner) | up to five questions, options, recommendation, the owner's answer | `clarify-ask`, then the owner |
| Opt-in | `git config --local sdd.implement` | `deepseek`, or absent | the owner |
| Run lock | `$(git rev-parse --git-dir)/sdd/<run_id>.json` | run id, `sdd-run`'s process id and its start time | `sdd-run` |
| Check command | `git config --local sdd.check` | the command verify runs | the owner |
| Credential | Keychain, generic password, service `deepseek-api` | the API key | the owner |
| Worker image | the container runtime's image store | tag `sdd-pi-worker:<hash>` | `sdd-step implement` |
| Tool cache | volume in the container runtime `sdd-cache-<run_id>` | — | `sdd-step implement`; removed when the run completes |

## Outcome files

Every one carries `schema` (its schema's id), `step`, `at` (ISO 8601) and the
fields below; anything else is refused (`additionalProperties: false`).

| File | Fields | Token `sdd-step outcome` prints |
|---|---|---|
| `routing.json` | the effective table: per phase and field, the value and the layer it came from; `speckit`, `claude_code` and container runtime versions | — (record, FR-021, FR-027) |
| `phases.json` | `done`: ordered list of `{phase: specify/plan/tasks/build, at}` | — (read by `sdd-run start --from`, FR-022) |
| `route.json` | `agent`: `deepseek`/`sonnet` | — (read by `implement`) |
| `clarify.json` | `questions`: integer 0–5 | `yes` when > 0, else `no` |
| `implement.json` (written only by `sdd-step implement`) | `agent` (`deepseek`/`sonnet`), `model` (the id served), `pi_version` or null, `commit` or null, `files`: list of paths, `usage`: pi's `{input, cached, output}` tokens or Claude's `{total_cost_usd, modelUsage}`, `seconds` | — (read by `usage`) |
| `verify.json` | `command`, `exit`: integer, `tail`: string | `pass` when `exit` is 0, else `fail` |
| `review.json` | `findings`: list of `{severity: CRITICAL/HIGH/MEDIUM/LOW, text, path?}`, `done`: list of task ids | `blocking` when any finding is above LOW, else `clear` |
| `converge.json` | `outcome`: `converged`/`tasks_appended`, `findings`: as in review | `converged` only when `outcome` is `converged` and no finding is above LOW, else `open` (FR-014) |

## Run states as the owner sees them

`running` → `paused` at a gate (answered with `sdd-run resume <id>
<verdict>`) → `running` → … → `completed`. A missing prerequisite, an invalid
outcome file, a guarded file or an agent error makes it `failed`; after the
cause is fixed, `sdd-run resume <id>` continues from the failed step without
redoing finished ones. A killed run: FR-022 and research R12 — the run's
process id lives in `$(git rev-parse --git-dir)/sdd/<run_id>.json`, never in
the feature directory, so it is never committed.
