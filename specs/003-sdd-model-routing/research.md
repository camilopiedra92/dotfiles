# Research: Model routing per Spec Kit phase

Decisions for `003-sdd-model-routing`, each with what was observed and what
lost. Probes ran on 2026-10-21 against Spec Kit 1.1.3 (`specify version`) in
throwaway repositories under the session scratchpad, with a stand-in `claude`
that records its arguments unless stated otherwise.

## R1 — A workflow of our own on Spec Kit's engine, not an overlay

**Decision**: one workflow file, `sdd-routed`, installed per repository with
`specify workflow add`, run with `specify workflow run sdd-routed`.

**Observed**: an overlay on the built-in `speckit` workflow composes and routes
(`replace` of `specify` with `model: opus` dispatched
`claude -p "/speckit-specify …" --model opus`). But the base has four command
steps and two gates, and routing replaces all four and adds clarify,
checklist, analyze, verify, review and converge; and overlays "cannot add new
inputs" (docs/reference/workflows.md, "Limitations"), which the gate verdicts
of R3 need.

**Alternatives**: the overlay — kept nothing of the base it tracks, and cannot
declare inputs. A preset carrying `model:` per command — the frontmatter is
dropped from the generated skill (probe: `model: opus`, `effort: high` absent
from `.claude/skills/speckit-plan/SKILL.md`), and upstream declined
per-command models (github/spec-kit#1287, "Your coding agent is in
control"). Skill frontmatter `model:` inside one session — the switch lasts
for the rest of the turn and rewrites the conversation into the new model's
prompt cache; per-step processes avoid both.

## R2 — Each phase is a headless Claude process on its model

**Decision**: `command` steps with `integration: claude` and `model: opus` or
`model: sonnet`. Spec Kit runs `claude -p <prompt> --model <m> --output-format
json` (`integrations/base.py`, `build_exec_args`).

**Cost of the fresh start**: the median first turn of a session over the last
28 days carried 43,040 tokens of context (507 sessions, local transcripts).
Paid once per phase; SC-001 measures whether it outweighs the saving.

## R3 — Clarify's questions go to a file and a gate

**Observed**: a `shell` step gets no terminal (probe: `[ -t 0 ]` false, `read`
got an empty line, stdout captured into `state.json`), so an interactive
clarify cannot run inside a step. A gate with no verdict input pauses when
there is no TTY and prompts when there is one (docs, "Gate Verdict Inputs").

**Decision**: `clarify-ask` (Opus) is told through its arguments to write its
questions, each with options and its recommendation, to
`<feature>/clarify-questions.md` and not to edit the spec; the gate
`answer-clarify` shows that file (`show_file`); the owner writes answers in it
and approves; `clarify-apply` (Opus) runs clarify again with "the answers are
in clarify-questions.md; ask nothing". An empty file (no questions) skips the
gate through an `if` step.

**Alternatives**: run clarify outside the workflow by hand — the owner would
pick a model by hand (SC-005). Verdict inputs carrying the answers — a gate
verdict must match one of its options, so free answers do not fit.

## R4 — Headless permissions fail closed

**Decision**: the launcher (R8) sets
`SPECKIT_INTEGRATION_CLAUDE_EXTRA_ARGS="--permission-mode dontAsk --settings
<routing settings>"`, the routing settings holding an explicit `allow` list:
the file tools, `.specify/scripts/bash/*`, read-only git, and the project's
check command for `verify`. Anything else is refused, and the refusal is in
the JSON result's `permission_denials` (field name from memory of the CLI's
output, **not yet observed on this version**: the first implementation task
confirms it), which the run reports (spec, edge
case "a permission the headless agent was not given").

**Why not**: `bypassPermissions` — refused by this machine's
`disableBypassPermissionsMode`. `auto` — a classifier decides; in the T3 Code
spike of 2026-10-18 an Auto mode accepted `config-guard`'s ask on `ruff.toml`
(sdd-decisions). `acceptEdits` alone — leaves Bash to the empty allowlist,
which in `-p` refuses every script Spec Kit's phases run. The env var is per
run, not per step (`_apply_extra_args_env_var`), so one allow list covers
every Claude phase; the narrower per-step list would need `shell` steps
calling `claude` directly, losing the native dispatch.

## R5 — Apple's `container` as the contained runtime

**Decision**: Apple's `container` (Homebrew formula `container`, 1.5.0, "Linux
containers using lightweight virtual machines"), declared in the `Brewfile`.

**Why**: one lightweight VM per container (Virtualization.framework), so the
agent is behind a kernel boundary of its own rather than a namespace in a
shared VM; a Homebrew formula, open source, no desktop app or daemon licence;
this machine is macOS on Apple Silicon (constitution, preamble), which is all
it supports. **Not yet verified here**: the first implementation task runs
`container system start` and a throwaway container on this machine before
anything is built on it.

**Alternatives**: Docker Desktop — installed on this machine but declared in
no `Brewfile` (drift, reported separately), a shared VM for every container,
and a commercial licence above a company size. OrbStack — proprietary, paid
for commercial use. colima — a shared Lima VM, the same isolation as Docker
Desktop with more moving parts. pi's own sandbox extension — runs in pi's
process on the host, the boundary is the agent's own code.

## R6 — The worker image and what it is given

**Decision**: `containers/pi-worker/Containerfile` in this repository, from a
digest-pinned Node 26 base, installing `@earendil-works/pi-coding-agent@1.3.0`
(`npm view` 2026-10-21: 1.3.0; `@mariozechner/pi-coding-agent` deprecated in
its favour), mise and uv, and DeepSeek's provider entry for pi's
`models.json` (DeepSeek's "pi mono" integration page: `openai-completions`
API at `https://api.deepseek.com`, models `deepseek-v4-flash` and
`deepseek-v4-pro`). The image is tagged with the Containerfile's hash and built
by the runner when that tag is missing, so it is a cache of a declared file,
not machine state (constitution IV).

**What the container sees**: the feature's worktree at `/work`, read-write,
and nothing else from the host; a named volume for mise's tool cache. The
credential enters on the container's stdin, read once by the entrypoint into
the agent's environment, so it never lands in a file, an image layer, a
container's stored configuration or the run's state (FR-009).

**Git stays on the host**: a worktree's `.git` is a file pointing outside the
mount, so the worker gets no git; the runner takes the baseline, the diff and
the commits on the host.

## R7 — Guarded configuration, one source of truth

**Decision**: after the worker exits, the runner feeds each changed file to
`claude/config-guard.sh` as the `Write` tool call that would have produced it;
an `ask` from the guard fails the step naming the file (FR-008).

**Alternatives**: a second list of patterns in the runner — two lists that
drift apart; the guard's own header names `pyproject.toml`'s `[tool.*]`
tables as the reason it is not a list of file names.

## R8 — A launcher, `sdd-run`

**Decision**: `bin/sdd-run.sh`, linked as `sdd-run`, is what the owner types:
it checks the prerequisites (FR-011), sets the extra arguments of R4, and
execs `specify workflow run sdd-routed -i spec=…`, or `resume` with a run id.
Logic of its own, so it ships with a check (constitution III).

## R9 — Opt-in is local git config

**Decision**: `git config --local sdd.implement deepseek` opts a repository
in; absent, implementation runs on Sonnet through `speckit.implement` (FR-010).

**Why local, not versioned**: consent is this owner's, on this machine, with
this credential. A versioned flag would opt in every clone of a public
repository, and would be a change to review in every repository that adopts
it.

## R10 — Verify, review and converge

**Decision**: after the worker, `verify` (Sonnet) runs the project's one check
command and writes `PASS` or `FAIL` and the failures; a `do-while` sends
failures back to the worker at most twice (FR-015), then a gate. `review`
(Opus) reads the diff in a fresh process. `converge` (Opus) runs in a
`do-while` of at most three passes (FR-014), stopping when its output says
converged.

**Observed**: a `shell` step exiting non-zero fails the whole run, so loop
conditions read step output, not exit codes (probe: `do-while` with an
exit-code condition ended `failed` on the first pass).

## R11 — Measuring SC-001

**Decision**: each Claude step's JSON result carries `total_cost_usd` and
`modelUsage`; it lands in the run's `state.json` (probe: step `output` holds
`stdout`). `bin/sdd-run.sh usage <run_id>` sums it per model. The eval runs on
the story-workers repository's `checkout` fixture, one arm routed and one arm
with every step on Opus and implementation through `speckit.implement`.
