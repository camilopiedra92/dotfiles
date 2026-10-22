# Routed Spec Kit runs

`sdd-run` takes a feature from a description to marked tasks through Spec Kit's
own phases, each on the model, effort and permissions a routing table gives it,
each agent contained, and the owner answering at three checkpoints. The design
and its evidence are in `specs/003-sdd-model-routing/` (research R1–R27); this
page is how to use it. Every claim below was observed on 2026-10-21 unless it
says otherwise.

## What runs where

| Phase | Agent | Why |
|---|---|---|
| specify, clarify, plan, checklist, checklist review, analyze, review, converge | Claude Opus | judgment |
| tasks | Claude Sonnet | mechanical decomposition |
| implement | Claude Sonnet, or DeepSeek through pi when the repository opts in | the bulk of the tokens |
| verify | no model | the repository's own check command |

`sdd-run routing` prints the effective table, each value with the layer it came
from. Every agent runs inside the worker container (Apple `container`), whose
only route out is the run's egress proxy: the proxy holds the credentials,
forwards only the endpoints the agents call, and lets passes read — never write
to — the package registries. Nothing an agent writes reaches the repository
until the judge has checked it against the phase's allowed paths, the
protected set (`.git*`, `.claude/`, `.pi/`, `.specify/`, `.sdd/`, `CLAUDE.md`,
`AGENTS.md`, `.mcp.json`…) and the credentials' exact values; then it is one
commit, named after the phase and the model.

## Once per machine

`./install.sh` installs the container runtime and its kernel, `check-jsonschema`
and Spec Kit, and links `sdd-run` and `sdd-step` into `~/.local/bin`. The two
credentials live in the Keychain and nowhere else; create them in a terminal of
their own (each command prompts for the secret, so it never lands in history):

```sh
claude setup-token        # prints the long-lived subscription token
security add-generic-password -U -a "$USER" -s claude-oauth -w
security add-generic-password -U -a "$USER" -s deepseek-api -w   # only for DeepSeek
```

## Once per repository

Spec Kit with the routed workflow (until `sdd-init` installs it, T050):

```sh
specify init --here --integration claude
specify workflow add <dotfiles>/claude/speckit/sdd-routed.yml
git config --local sdd.check './check.sh'      # what verify runs, in the worker
```

To implement on DeepSeek instead of Sonnet — DeepSeek's terms of service and
privacy policy then apply to the code it reads:

```sh
specify integration install pi                 # Spec Kit's own pi integration
git add .pi && git commit -m "spec kit: pi integration"
git config --local sdd.implement deepseek
```

`sdd-run` refuses a DeepSeek opt-in whose pi integration is not committed: pi
runs Spec Kit's `/speckit.implement` from it, as Claude runs its skill.

## A run

```sh
sdd-run start "a description of the feature"
```

It stops at each checkpoint and prints the command that answers it:

- `answer_clarify`, only when clarify has questions: each question in
  `specs/<feature>/clarify-questions.md` carries a recommendation; write
  `**Answer:** <option>` under each, then `sdd-run resume <id> approve`.
- `review_spec`: read `spec.md`; `approve` or `reject` (reject ends the run).
- `review_plan`, after tasks and analyze: read `plan.md`, `tasks.md`,
  `analysis.md` and the checklist items the fresh checklist review left
  unchecked. Approving is your answer to implement's question whether to go on
  with unchecked items.
- `review_done`: read `.sdd/review.json` and the check and automation changes
  it lists; approving marks the tasks review found done.

Other stops say what answers them:

- `fix_stuck` or `converge_stuck`, after three rounds without a passing check
  or a converged review: `sdd-run resume <id> retry` buys exactly one more
  round; `sdd-run abort <id>` ends the run.
- A failed step prints the step's own message; once the cause is fixed,
  `sdd-run resume <id>` runs it again.
- A run whose process died cannot be resumed (Spec Kit refuses a run it still
  reads as running): `sdd-run start --from specs/<feature>` starts a new run
  that skips the phases already finished.

The run's own files are in its bundle, `$(git rev-parse --git-common-dir)/sdd/<id>/`:
the frozen routing table, profiles and brief, `usage.jsonl`, and `results/`,
every agent's final answer — the first place to look when a pass did something
unexpected.

## Cost

```sh
sdd-run usage <id>
```

prints every attempt per model at list price, failed and resumed ones
included, and names attempts that reported nothing. The first complete real
run — a small Python function with five tests, Opus for judgment, Sonnet for
tasks and implementation — reported $0.54 for its last run of the build.

## Changing the routing

A layer may change only a phase's `model` (within its agent's family),
`effort` and `timeout` (up to the phase's ceiling): it cannot send code to
another provider, widen permissions or drop a rule.

| Layer | Where | Versioned |
|---|---|---|
| defaults | `claude/speckit/routing.yml` in dotfiles | yes |
| repository | `.claude/sdd-routing.yml` | yes |
| local | `.claude/sdd-routing.local.yml` (`sdd-run routing --init-local` creates it, git-excluded) | no |
| one run | `sdd-run start --set plan.effort=high` | no |

## Why some things are the way they are

- **Agents use the shell inside the container.** Allowing commands one by one
  broke Spec Kit's own agents three times in three phases of the first real
  run; the container, the proxy and the judge are the boundary, as in
  Anthropic's devcontainer (research R27).
- **The brief goes to the system prompt, not a Spec Kit preset.** Its rules hold
  only inside a contained run; a preset would change implement for every
  interactive use too (research R27).
- **The worker image is reproducible in its packages, not its bits.** Apple's
  builder gives one recipe different digests; every input is pinned by hash
  and `prepare-worker` refuses an image whose package inventory differs from
  the committed one (research R26).
- **Registries are read-only.** The proxy inspects their TLS with an authority
  made for the run, name-constrained to the registries, and forwards only
  `GET` and `HEAD` (research R25).
