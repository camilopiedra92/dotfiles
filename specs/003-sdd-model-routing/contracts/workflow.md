# Contract: the `sdd-routed` workflow

File: `claude/speckit/sdd-routed.yml`, Spec Kit workflow schema 1.0, installed
per repository with `specify workflow add`. The workflow owns order,
checkpoints, loops and resume; it names no model, effort or permission. Every
step that runs an agent is a `shell` step calling `sdd-step agent <phase>`,
which takes everything else from that phase's row of the routing table
(contracts/routing.md, research R2). `<f>` is the feature directory; outcome
files live in `<f>/.sdd/` and are read only through `sdd-step outcome`
(research R10).

## Inputs

| Input | Type | Default |
|---|---|---|
| `spec` | string; required unless `resume_from` is set, when `sdd-run start --from` passes the feature's `spec.md` path | `""` |
| `resume_from` | `enum: ["", specify, plan, tasks, build]` | `""`; set only by `sdd-run start --from`; every phase before it is skipped (FR-022) |
| `clarify_verdict`, `spec_verdict`, `plan_verdict`, `done_verdict` | `enum: ["", approve, reject]` | `""` |
| `fix_verdict`, `converge_verdict` | `enum: ["", retry, abort]` | `""` |

Every gate binds one of them with `verdict_input` (research R3). The spec
text reaches the dispatcher through the run's `inputs.json`, never through a
`run` field (FR-016).

## Steps, in order

Agent steps are `shell` steps running `sdd-step agent <phase>`; the routing
row named in the Phase column decides agent, model, effort, profile, schema
and limit.

| # | id | Kind | Phase row | Writes | Notes |
|---|---|---|---|---|---|
| 1 | `specify` | agent | `specify` | `spec.md` | |
| 2 | `clarify-ask` | agent | `clarify-ask` | `clarify-questions.md`, `.sdd/clarify.json` | unattended: questions to the file with a recommendation each; the count as structured output |
| 3 | `has-questions` | shell `sdd-step outcome clarify` | — | — | prints `yes`/`no` |
| 4 | `answer-clarify` | gate in `if` 3 = yes | owner | — | `show_file: clarify-questions.md`; `clarify_verdict` |
| 5 | `clarify-apply` | agent, in the same `if` | `clarify-apply` | `spec.md` | applies the file's answers, asks nothing |
| 6 | `review-spec` | gate | owner | — | `spec_verdict`, reject aborts; then `sdd-step phase-done specify` |
| 7 | `plan` | agent | `plan` | plan artifacts | |
| 8 | `checklist` | agent | `checklist` | `checklists/` | |
| 9 | `analyze` | agent | `analyze` | `analysis.md` | Spec Kit's analyze is read-only; the dispatcher writes its report, the result's text, to the file the row names |
| 10 | `review-plan` | gate | owner | — | `plan_verdict`, shows `analysis.md`, reject aborts; then `sdd-step phase-done plan` |
| 11 | `tasks` | agent | `tasks` | `tasks.md` | then `sdd-step phase-done tasks` |
| 12 | `route` | shell `sdd-step route` | — | `.sdd/route.json` | records `deepseek`/`sonnet` for `implement` |
| 12.1 | `prepare-worker` | shell `sdd-step prepare-worker`, `timeout: 1800` | — | the worker image | builds it once, outside every pass's limit; both paths need it, since verify runs in it |
| 13 | `build` | `do-while`, `max_iterations: 3` | — | — | until `sdd-step outcome converge` prints `converged` (FR-014) |
| 13.1 | `fix-loop` | `do-while`, `max_iterations: 3` | — | — | until `sdd-step outcome verify` prints `pass` (FR-015) |
| 13.1.1 | `implement` | shell `sdd-step implement` | `implement-deepseek` or `implement-sonnet`, as `route` decided | patch applied and committed, `.sdd/implement.json` | both agents get the same brief, checkout, judgment and time limit (US2 AS6) |
| 13.1.2 | `verify` | shell `sdd-step verify` | — (no model, FR-020) | `.sdd/verify.json` | in the worker container, on a fresh export of `HEAD`, no network but the allow list |
| 13.2 | `fix-stuck` | gate in `if` verify = fail | owner | — | `fix_verdict`: `retry` runs exactly one more 13.1.1–13.1.2 round and comes back here if it fails; `abort` stops |
| 13.3 | `review` | agent | `review` | `.sdd/review.json` | fresh agent over the diff since the run's base, read-only profile; deleted or weakened tests are blocking (FR-019) |
| 13.4 | `converge` | agent | `converge` | `tasks.md`, `.sdd/converge.json` | findings by severity as structured output |
| 14 | `converge-stuck` | gate in `if` converge = open | owner | — | `converge_verdict`: `retry` runs one more 13 pass and comes back here if still open; `abort` stops |
| 15 | `review-done` | gate | owner | — | `done_verdict`: shows `review.json`; approve runs 16 |
| 16 | `mark` | shell `sdd-step mark` | — | `tasks.md` | marks `[X]` the tasks review passed, only if verify = pass and review has nothing blocking (FR-006); then `sdd-step phase-done build` |

Same-model steps are adjacent — 1–9 on Opus, 11 on Sonnet, 13.1.1 on the
implementing agent, 13.3–13.4 on Opus — so each step after the first of a
group reads its prefix from the prompt cache (research R16).

## Timeouts

Every agent step's `timeout:` is its routing row's `max_timeout` plus 300
seconds (contracts/routing.md), so the dispatcher's own limit — the effective
`timeout`, at most `max_timeout` — always fires first and cleans up;
`implement` (13.1.1), though run by `sdd-step implement` rather than
`sdd-step agent`, is an agent step for this rule: `timeout: 3900`, its rows'
`max_timeout` of 3600 plus 300; `verify` sets 3600; the other shell
steps keep Spec Kit's 300-second default (research R11).

## Guarantees

- Every agent step is a fresh process (research R2), with no MCP server and
  only its profile's tools (FR-026).
- No step interpolates agent output into a `shell` step's `run`; every branch
  compares a fixed token from `sdd-step outcome` (FR-016).
- A missing or invalid outcome file makes `sdd-step outcome` exit non-zero,
  failing the run at that step.
- The workflow changes only through `specify workflow add` in each repository
  (`sdd-run` refuses a stale copy, research R12); a phase's model or effort
  changes in the routing table, with no change here.
