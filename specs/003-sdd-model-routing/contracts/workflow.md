# Contract: the `sdd-routed` workflow

File: `claude/speckit/sdd-routed.yml`, Spec Kit workflow schema 1.0, installed
per repository with `specify workflow add`. Every `command` step uses
`integration: claude`; the model column is its `model:`.

## Inputs

| Input | Type | Default | Use |
|---|---|---|---|
| `spec` | string, required | — | the feature description, passed to `specify` |
| `spec_verdict`, `plan_verdict`, `stuck_verdict` | string, `enum: ["", approve, reject]` | `""` | bound to the gates below with `verdict_input`, so `sdd-run resume <id> approve` answers a gate without a terminal (R3) |

## Steps, in order

| # | id | Kind | Model / agent | Notes |
|---|---|---|---|---|
| 1 | `specify` | command `speckit.specify` | opus | args: `{{ inputs.spec }}` |
| 2 | `clarify-ask` | command `speckit.clarify` | opus | args tell it to run unattended: write up to five questions, each with options and its recommendation, to `<feature>/clarify-questions.md`, and edit nothing else |
| 3 | `has-questions` | shell | — | `sdd-implement-worker questions` prints `yes` or `no` from that file |
| 4 | `answer-clarify` | gate, inside `if` on step 3 | owner | `show_file: clarify-questions.md`; the owner writes answers there |
| 5 | `clarify-apply` | command `speckit.clarify`, inside the same `if` | opus | args: apply the answers in the file, ask nothing |
| 6 | `review-spec` | gate | owner | `verdict_input: spec_verdict`, `on_reject: abort` |
| 7 | `plan` | command `speckit.plan` | opus | |
| 8 | `checklist` | command `speckit.checklist` | opus | |
| 9 | `analyze` | command `speckit.analyze` | opus | |
| 10 | `review-plan` | gate | owner | `verdict_input: plan_verdict`; shows the checklist and the analysis |
| 11 | `tasks` | command `speckit.tasks` | sonnet | |
| 12 | `route` | shell | — | `sdd-implement-worker route` prints `deepseek` or `sonnet` (R9) |
| 13 | `build` | `do-while`, `max_iterations: 3` | — | the convergence loop (FR-014); body 13a–13e; condition: 13e's output does not report `converged` |
| 13a | `fix-loop` | `do-while`, `max_iterations: 3` | — | one attempt and at most two fix rounds (FR-015); body 13a1–13a2; condition: 13a2's output reports `VERIFY: FAIL` |
| 13a1 | `implement` | `if` on step 12 | deepseek: shell `sdd-implement-worker run`; sonnet: command `speckit.implement` on sonnet | on a fix round the worker reads `<feature>/verify.md` |
| 13a2 | `verify` | prompt step | sonnet | runs the project's one check command; writes `VERIFY: PASS` or `VERIFY: FAIL` and the failures to `<feature>/verify.md` and prints the marker |
| 13b | `fix-stuck` | gate, inside `if` 13a2 still reports FAIL | owner | `verdict_input: stuck_verdict`; nothing goes to a Claude model unasked |
| 13d | `review` | prompt step, a fresh review of the diff since the run's base | opus | marks the phase's tasks `[X]` only on `VERIFY: PASS` and a review with nothing blocking (FR-006) |
| 13e | `converge` | command `speckit.converge` | opus | `converged` ends the loop; `tasks_appended` goes round again |
| 14 | `converge-stuck` | gate, inside `if` 13e did not converge | owner | three passes ran with findings above LOW open |

## Guarantees

- Each `command` step is a fresh `claude -p` process (R2); nothing but the
  feature's files passes between steps.
- No step interpolates agent output into a `shell` step's `run` (the engine's
  own warning, docs "Interpolation and shell safety"): branches read fixed
  markers through `if` conditions.
- The workflow names no model outside this file; changing a phase's model is a
  one-line edit here.
