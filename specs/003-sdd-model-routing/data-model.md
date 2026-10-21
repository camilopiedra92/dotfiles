# Data model: Model routing per Spec Kit phase

No database: each entity is a file or a setting that already has an owner.

| Entity | Where it lives | Fields that matter | Written by |
|---|---|---|---|
| Workflow | `claude/speckit/sdd-routed.yml`, copied into each repository's `.specify/workflows/` by `specify workflow add` | `version`; gate `verdict_input`; loop `max_iterations`; step `timeout`; no model, effort or permission (contracts/workflow.md) | this repository, through `sdd-init` |
| Run | `.specify/workflows/runs/<run_id>/` (`state.json`, `inputs.json`, `log.jsonl`), Spec Kit's, read-only to our scripts | status (`running`, `paused`, `completed`, `failed`, `aborted`), current step, each step's `output` (the dispatcher's one-line summary; usage is in the usage log) | Spec Kit's engine |
| Routing table | defaults `claude/speckit/routing.yml`; project `<repo>/.claude/sdd-routing.yml`; local `<repo>/.claude/sdd-routing.local.yml`; a run's `--set` — merged per FR-027 | per phase: `agent`, `model`, `effort`, `profile`, `prompt`, `writes`, `schema`, `result_to`, `timeout`, `max_timeout` (contracts/routing.md) | this repository |
| Usage log | `$SDD_RUN_DIR/usage.jsonl`, per run | a start and an end line per agent step attempt: run id, phase, model, effort given, effort and usage reported | `sdd-step agent`, `sdd-step implement` |
| Outcome files | `<feature>/.sdd/<step>.json`, one schema each in `claude/speckit/schemas/` | below | the step named |
| Clarify questions | `<feature>/clarify-questions.md` (Markdown, for the owner) | up to five questions, options, recommendation, the owner's answer | `clarify-ask`, then the owner |
| Opt-in | `git config --local sdd.implement` | `deepseek`, or absent | the owner |
| Run bundle | `$SDD_RUN_DIR/` = `$(git rev-parse --git-common-dir)/sdd/<run_id>/`: `lock.json`, `optin.json`, `check.json`, `tools.json`, `routing.json`, `profiles/`, `hooks/`, `usage.jsonl` (contracts/routing.md) | — | `sdd-run`, `sdd-step` |
| Check command | `git config --local sdd.check` | the command verify runs | the owner |
| Credentials | Keychain, generic passwords, services `claude-oauth` (the owner's token from `claude setup-token`) and `deepseek-api` (the DeepSeek key) | read only by the egress proxy and the judge's scanner, in memory | the owner |
| Worker image | the container runtime's image store | tag `sdd-worker:<hash of containers/worker/>` | `sdd-step prepare-worker` |
| Tool caches | volumes `sdd-cache-implement-<run_id>` and `sdd-cache-verify-<run_id>`, never shared | — | implement passes; verify; removed when the run completes |
| Egress proxy | a container per run, on the run's own network `sdd-<run_id>` (`sdd-step egress-proxy`) | the run's credentials in memory (the DeepSeek key only when opted in); per-pass admission | `sdd-run`; stopped when its `specify` child exits, and exits itself after a minute without `sdd-run`'s heartbeat |

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
| `verify.json` | `command`, `exit`: integer, `tail`: string, `check_changes` and `automation_changes`: lists of paths (FR-029, FR-030) | `pass` when `exit` is 0, else `fail` |
| `review.json` | `findings`: list of `{severity: CRITICAL/HIGH/MEDIUM/LOW, text, path?}`, `done`: list of task ids | `blocking` when any finding is above LOW, else `clear` |
| `converge.json` | `outcome`: `converged`/`tasks_appended`, `findings`: as in review | `converged` only when `outcome` is `converged` and no finding is above LOW, else `open` (FR-014) |

## Run states as the owner sees them

`running` → `paused` at a gate (answered with `sdd-run resume <id>
<verdict>`) → `running` → … → `completed`. A missing prerequisite, an invalid
outcome file, a guarded file or an agent error makes it `failed`; after the
cause is fixed, `sdd-run resume <id>` continues from the failed step without
redoing finished ones. A killed run: FR-022 and research R12 — the run's
process id lives in the run bundle, `$SDD_RUN_DIR/lock.json`, never in
the feature directory, so it is never committed.
