# Contract: the `sdd-routed` workflow

File: `claude/speckit/sdd-routed.yml`, Spec Kit workflow schema 1.0, installed
per repository with `specify workflow add`. The workflow owns order,
checkpoints, loops and resume; it names no model, effort or permission. Every
step that runs an agent is a `shell` step calling `"$SDD_STEP" agent <phase>`,
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

Every gate binds one of them with `verdict_input` (research R3); each gate
occurs once per run. The two places a run stops for the owner inside a loop —
13.2.1 and 13.5 — are not gates: a gate's approving verdict is never reset and
would answer its every later occurrence (research R3, T004), so they are
shell steps that consume a one-shot verdict file and otherwise fail the step,
which Spec Kit then resumes. The spec
text reaches the dispatcher through the run's `inputs.json`, never through a
`run` field (FR-016).

## Steps, in order

Agent steps are `shell` steps running `"$SDD_STEP" agent <phase>` — `SDD_STEP`
is the absolute path `sdd-run` exports, so no step finds a tool through a
`PATH`; the routing
row named in the Phase column decides agent, model, effort, profile, schema
and limit.

| # | id | Kind | Phase row | Writes | Notes |
|---|---|---|---|---|---|
| 0 | `prepare-worker` | shell `sdd-step prepare-worker`, `timeout: 1800` | — | the worker image | builds it once, before the first agent step, outside every pass's limit |
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
| 13 | `convergence` | `do-while`, `max_iterations: 50` (a safety bound; each pass past the third needs an owner's one-shot `retry`) | — | — | until `sdd-step stuck converge` prints `clear`; body 13.0–13.5 |
| 13.0 | `build` | `do-while`, `max_iterations: 3` | — | — | until `sdd-step outcome converge` prints `converged` (FR-014) |
| 13.1 | `fix-loop` | `do-while`, `max_iterations: 3` | — | — | until `sdd-step outcome verify` prints `pass` (FR-015) |
| 13.1.1 | `implement` | shell `sdd-step implement` | `implement-deepseek` or `implement-sonnet`, as `route` decided | patch applied and committed, `.sdd/implement.json` | both agents get the same brief, export, judgment and time limit (US2 AS6) |
| 13.1.2 | `verify` | shell `sdd-step verify` | — (no model, FR-020) | `.sdd/verify.json` | in the worker container, on a fresh export of `HEAD`, admitted by the proxy to the registries only |
| 13.2 | `retry-loop` | `do-while`, `max_iterations: 50` (safety bound) | — | — | while `fix-stuck` prints `retry`; body 13.2.1–13.2.3 |
| 13.2.1 | `fix-stuck` | shell `sdd-step stuck fix` | — | — | prints `clear` when verify passed; prints `retry` after consuming a one-shot owner's `retry` from the bundle; otherwise fails the step — stopping the run for the owner — naming `sdd-run resume <id> retry` and `sdd-run abort <id>` |
| 13.2.2 | `implement` | shell `sdd-step implement`, in an `if` on 13.2.1 = `retry` | as 13.1.1 | as 13.1.1 | exactly one more round per `retry` |
| 13.2.3 | `verify` | shell `sdd-step verify`, in the same `if` | — | `.sdd/verify.json` | |
| 13.3 | `review` | agent | `review` | `.sdd/review.json` | fresh agent over the diff since the run's base, mounted as `/input/diff.patch` (contracts/pass.md), `reader` profile; deleted or weakened tests are blocking (FR-019) |
| 13.4 | `converge` | agent | `converge` | `tasks.md`, `.sdd/converge.json` | findings by severity as structured output |
| 13.5 | `converge-stuck` | shell `sdd-step stuck converge` | — | — | prints `clear` when converge converged; prints `retry` after consuming a one-shot owner's `retry`, which runs one more convergence pass; otherwise fails the step naming `sdd-run resume <id> retry` and `sdd-run abort <id>` |
| 15 | `review-done` | gate | owner | — | `done_verdict`: shows `review.json`, the check changes (FR-029) and the automation changes (FR-030) the implement passes recorded; approve runs 16 |
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
