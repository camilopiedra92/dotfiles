# Data model: Model routing per Spec Kit phase

No database: each entity is a file or a setting that already has an owner.

| Entity | Where it lives | Fields that matter | Who writes it |
|---|---|---|---|
| Routing | `claude/speckit/sdd-routed.yml`, copied into each repository's `.specify/workflows/` by `specify workflow add` | per step: `model`, `integration`, gate `verdict_input`, loop `max_iterations` | this repository, through `sdd-init` |
| Run | `.specify/workflows/runs/<run_id>/` (`state.json`, `inputs.json`, `log.jsonl`), Spec Kit's | status (`running`, `paused`, `completed`, `failed`, `aborted`), current step, each step's `output` (stdout, which for a Claude step is its JSON result with `total_cost_usd` and `modelUsage`) | Spec Kit's engine |
| Opt-in | `git config --local sdd.implement` | `deepseek`, or absent | the owner, by hand, per repository |
| Credential | Keychain, generic password, service `deepseek-api` | the API key | the owner, `security add-generic-password -a "$USER" -s deepseek-api -w` |
| Clarify questions | `<feature>/clarify-questions.md` | up to five questions, options, recommendation, the owner's answer | `clarify-ask`, then the owner |
| Verify result | `<feature>/verify.md` | `VERIFY: PASS` or `VERIFY: FAIL`, the failing tests | `verify` |
| Worker image | local `container` image store, tag `sdd-pi-worker:<hash>` | the Containerfile's hash | `sdd-implement-worker run`, when absent |

## Run states as the owner sees them

`running` → `paused` at a gate (answered with `sdd-run resume <id> approve`)
→ `running` → … → `completed`. A missing prerequisite or a guarded file makes
it `failed`; after the cause is fixed, `sdd-run resume <id>` continues from the
failed step without redoing finished ones (docs, "Resume a Workflow").
