# Contract: the `sdd-routed` workflow

File: `claude/speckit/sdd-routed.yml`, Spec Kit workflow schema 1.0, installed
per repository with `specify workflow add`. Model steps use `integration:
claude`; the model column is their `model:`. `<f>` is the feature directory;
outcome files live in `<f>/.sdd/` and are read only through `sdd-step outcome`
(research R10).

## Inputs

| Input | Type | Default |
|---|---|---|
| `spec` | string, required | — |
| `clarify_verdict`, `spec_verdict`, `plan_verdict`, `done_verdict` | `enum: ["", approve, reject]` | `""` |
| `fix_verdict`, `converge_verdict` | `enum: ["", retry, abort]` | `""` |

Every gate binds one of them with `verdict_input` (R3).

## Steps, in order

| # | id | Kind | Model | Writes | Notes |
|---|---|---|---|---|---|
| 1 | `specify` | command `speckit.specify` | opus | `spec.md` | |
| 2 | `clarify-ask` | command `speckit.clarify` | opus | `clarify-questions.md`, `.sdd/clarify.json` | args: unattended, questions to the file with a recommendation each, edit nothing else |
| 3 | `has-questions` | shell `sdd-step outcome clarify` | — | — | prints `yes`/`no` |
| 4 | `answer-clarify` | gate in `if` 3 = yes | owner | — | `show_file: clarify-questions.md`; `clarify_verdict` |
| 5 | `clarify-apply` | command `speckit.clarify` in the same `if` | opus | `spec.md` | args: apply the file's answers, ask nothing |
| 6 | `review-spec` | gate | owner | — | `spec_verdict`, reject aborts |
| 7 | `plan` | command `speckit.plan` | opus | plan artifacts | |
| 8 | `checklist` | command `speckit.checklist` | opus | `checklists/` | |
| 9 | `analyze` | command `speckit.analyze` | opus | `.sdd/analyze.md` | |
| 10 | `review-plan` | gate | owner | — | `plan_verdict`, reject aborts |
| 11 | `tasks` | command `speckit.tasks` | sonnet | `tasks.md` | |
| 12 | `route` | shell `sdd-step route` | — | — | prints `deepseek`/`sonnet` |
| 13 | `build` | `do-while`, `max_iterations: 3` | — | — | until `sdd-step outcome converge` prints `converged` (FR-014) |
| 13.1 | `fix-loop` | `do-while`, `max_iterations: 3` | — | — | until `sdd-step outcome verify` prints `pass` (FR-015) |
| 13.1.1 | `implement` | `if` on 12 | deepseek: shell `sdd-step implement`; sonnet: prompt step with the same brief (FR-017) | patch applied and committed, `.sdd/implement.json` | the Sonnet path's prompt makes it write no task marks and the same outcome file |
| 13.1.2 | `verify` | shell `sdd-step verify` | none (FR-020) | `.sdd/verify.json` | |
| 13.2 | `fix-stuck` | gate in `if` verify = fail | owner | — | `fix_verdict`: `retry` runs `fix-loop` once more, `abort` stops |
| 13.3 | `review` | prompt step | opus | `.sdd/review.json` | fresh agent over the diff since the run's base; deleted or weakened tests are blocking (FR-019) |
| 13.4 | `converge` | command `speckit.converge` | opus | `tasks.md`, `.sdd/converge.json` | args: write the outcome file with findings by severity |
| 14 | `converge-stuck` | gate in `if` converge = open | owner | — | `converge_verdict` |
| 15 | `review-done` | gate | owner | — | `done_verdict`: shows `review.json`; approve runs 16 |
| 16 | `mark` | shell `sdd-step mark` | — | `tasks.md` | marks `[X]` the tasks review passed, only if verify = pass and review has nothing blocking (FR-006) |

## Guarantees

- Every model step is a fresh `claude -p` process (research R2).
- No step interpolates agent output into a `shell` step's `run`; every branch
  compares a fixed token from `sdd-step outcome` (FR-016).
- A missing or invalid outcome file makes `sdd-step outcome` exit non-zero,
  failing the run at that step.
- Changing a phase's model is a one-line edit here, followed by `specify
  workflow add` in each repository (`sdd-run` refuses a stale copy, R12).
