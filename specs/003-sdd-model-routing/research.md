# Research: Model routing per Spec Kit phase

Decisions for `003-sdd-model-routing`, each with what was observed and what
lost. Probes ran on 2026-10-21 against Spec Kit 1.1.3 and were rerun the same
day on 1.2.2 (dotfiles PR #154); this feature requires 1.2.1 or newer (R11,
R15) and is built and checked on 1.2.2, in
throwaway repositories under the session scratchpad, with a stand-in `claude`
that records its arguments unless stated otherwise. "Pending" marks a claim
the first implementation tasks still have to observe on this machine.

## R1 — A workflow of our own on Spec Kit's engine, not an overlay

**Decision**: one workflow file, `sdd-routed`, installed per repository with
`specify workflow add`, run through `sdd-run` (R8).

**Observed**: an overlay on the built-in `speckit` workflow composes and routes
(`replace` of `specify` with `model: opus` dispatched
`claude -p "/speckit-specify …" --model opus`). But the base has four command
steps and two gates, routing replaces all four and adds a dozen steps, and
overlays "cannot add new inputs" (docs/reference/workflows.md,
"Limitations"), which every gate's verdict needs (R3).

**Alternatives**: the overlay — kept nothing of the base, and cannot declare
inputs. A preset carrying `model:` per command — dropped from the generated
skill (probe: `model: opus`, `effort: high` absent from
`.claude/skills/speckit-plan/SKILL.md`); upstream declined per-command models
(github/spec-kit#1287). Skill frontmatter `model:` inside one session — lasts
for the rest of the turn and rewrites the conversation into the new model's
prompt cache; per-step processes avoid both.

## R2 — Each judgment phase is a headless Claude process on its model

**Decision**: `command` steps with `integration: claude` and `model:
claude-opus-5-5` (specify, clarify, plan, checklist, analyze, converge) or
`claude-sonnet-5-5` (tasks); a `prompt` step on Opus for review. Full ids,
not the `opus`/`sonnet` aliases, so a model changes only by an edit here;
the ids are those this CLI reports today (session environment, 2026-10-21). Spec Kit runs `claude -p
<prompt> --model <m> --output-format json` (`integrations/base.py`,
`build_exec_args`). Verify runs no model (R10).

**Cost of the fresh start**: the median first turn of a session over the last
28 days carried 43,040 tokens of context (507 sessions, local transcripts).
Paid once per step; SC-001 measures whether it outweighs the saving.

## R3 — Every checkpoint is a gate with a verdict input

**Observed**: a `shell` step gets no terminal (probe: `[ -t 0 ]` false, `read`
got an empty line, stdout captured into `state.json`). A gate with no verdict
input pauses without a TTY, and a bound verdict input set on resume decides it
(docs, "Gate Verdict Inputs").

**Decision**: every gate binds a verdict input declared by the workflow,
`enum: ["", <its options>]`, default `""`, so `sdd-run resume <id> <verdict>`
answers any of them (FR-004). Clarify's questions go to
`<feature>/clarify-questions.md` (Markdown, for the owner); `clarify-ask` is
told through its arguments to write them there with a recommendation each and
to edit nothing else, and to write `clarify.json` saying how many it wrote;
the gate `answer-clarify` shows the file (`show_file`); `clarify-apply` runs
clarify again with "the answers are in clarify-questions.md; ask nothing".

**Pending**: the semantics of a gate's non-approve options (`retry` for
`fix-stuck`, R10) are read from the engine's code and observed in the first
task, before the workflow relies on them.

**Alternatives**: clarify by hand outside the workflow — the owner would pick a
model by hand (SC-005). Answers as a verdict — a verdict must match one of the
gate's options, so free answers do not fit.

## R4 — Headless permissions fail closed

**Decision**: `sdd-run` sets
`SPECKIT_INTEGRATION_CLAUDE_EXTRA_ARGS="--permission-mode dontAsk
--output-format json --settings <routing-settings.json>"` (`--output-format`:
R11), whose `allow` list holds the file tools,
`.specify/scripts/bash/*` and read-only git. Since verify runs no model (R10),
no judgment phase needs a project's check command, so one machine-wide list
serves every phase but one: the lighter model's implementation pass (R6),
whose settings add `Bash(<sdd.check>)` and limit `Edit` and `Write` to its
checkout, composed per pass by `sdd-step implement`.

**Pending**: what a denied tool looks like in `-p` output on this CLI (a
`permission_denials` field is expected, not yet observed) and whether the step
exits non-zero. The first task observes it; the step must fail naming the
refused tool, and `docs/sdd-routing.md` says where to widen the list.

**Why not**: `bypassPermissions` — refused by this machine's
`disableBypassPermissionsMode`. `auto` — a classifier decides; in the T3 Code
spike of 2026-10-18 an Auto mode accepted `config-guard`'s ask on `ruff.toml`
(sdd-decisions). `acceptEdits` alone — leaves Bash to the empty allowlist,
which in `-p` refuses every script Spec Kit's phases run. The env var is per
run, not per step (`_apply_extra_args_env_var`).

## R5 — Apple's `container` as the contained runtime

**Decision**: Apple's `container` (Homebrew formula `container`, 1.5.0, "Linux
containers using lightweight virtual machines"), declared in the `Brewfile`.

**Why**: one lightweight VM per container (Virtualization.framework), so the
agent is behind a kernel boundary of its own rather than a namespace in a
shared VM; a Homebrew formula, open source, no desktop app or daemon licence.

**Egress**: the allow list is `containers/pi-worker/egress.txt` — DeepSeek's
API host and the registries the image's toolchain installs from (npm, PyPI,
mise's sources) — one file the spec's three mentions all point to.

**Pending**: the macOS version it requires (`brew info` printed none), whether
its networking can restrict egress to the hosts in that file (FR-007), and a throwaway
container run on this machine. The first task settles all three; if egress
cannot be restricted by the runtime, the decision is reopened before anything
is built on it, not worked around.

**Alternatives**: Docker Desktop — installed on this machine but declared in
no `Brewfile` (drift, reported separately), one shared VM for every container,
a commercial licence above a company size. OrbStack — proprietary, paid for
commercial use. colima — a shared Lima VM. pi's own sandbox extension — runs
in pi's process on the host, so the boundary is the agent's own code.

## R6 — A disposable checkout, mounted alone

**Decision**: for each implementation pass, `sdd-step implement` commits the
feature directory, then creates a detached git worktree of that commit in a temporary directory —
tracked files only, so no untracked `.env` or ignored secret reaches the agent
— and mounts it alone at `/work`. Afterwards it takes the pass's changes as a
patch (`git diff --binary` plus new files), judges it (R7), applies it to the
feature's worktree, commits, and removes the checkout. A pass that fails,
times out or crashes leaves the feature's worktree untouched, so resume finds
it clean (US2 AS7). The Sonnet path uses the same checkout, judgment and time limit,
running `claude -p` on the host in it rather than in the VM: Claude is under
the headless permissions of R4 plus `Bash(<sdd.check>)`, so it can see its
tests fail (FR-023), and no code leaves for a new provider; its JSON result
goes into `implement.json` for `sdd-run usage`. Every
checkout, container and volume is labelled with its run id, so `sdd-step
cleanup` can remove what a killed pass left.

**Tool cache**: a volume per run, `sdd-cache-<run_id>`, removed when the run
completes, so concurrent runs share no writable state. Ceiling: each run
installs its toolchain afresh; if that takes long enough to matter, a
read-only shared cache populated on the host is the next step.

**Image**: `containers/pi-worker/Containerfile`, digest-pinned Node 26 base,
`@earendil-works/pi-coding-agent@1.3.0` (`npm view` 2026-10-21; the
`@mariozechner` package is deprecated in its favour), mise and uv, and
DeepSeek's provider entry for pi's `models.json` (DeepSeek's "pi mono" page:
`openai-completions` at `https://api.deepseek.com`, models
`deepseek-v4-flash` and `deepseek-v4-pro`). **Corrected 2026-10-21**: the API
itself lists `deepseek-flash` and `deepseek-v4-pro` (`GET /models` with the
owner's key, HTTP 200), so the page's `deepseek-v4-flash` is not an id it
serves; `models.json` uses the ids `/models` returns, and the first
implementation task checks them against `/models` again before a run relies on
them. Tagged with the Containerfile directory's hash and built
when the tag is missing: a cache of a declared file (constitution IV).

**Credential**: written to the container's stdin, read once by the entrypoint
into pi's environment inside the VM; pi's session directory is outside `/work`
and inside the VM, discarded with it (FR-009).

**Git stays on the host**: the worker gets no git; baseline, patch and commit
are taken on the host.

## R7 — Guarded configuration, one source of truth

**Decision**: each path the patch creates, changes or deletes is passed to
`claude/config-guard.sh` as the `Write` call that would produce its new
content (empty for a deletion); an `ask` fails the step naming the path, with
nothing applied (FR-008). **Pending**: that the guard asks on an empty `Write`
to a whole-file config and on a `pyproject.toml` that loses a checker table;
the check for R7 drives both.

**Alternatives**: a second list of patterns — two lists that drift apart; the
guard's own header names `pyproject.toml`'s `[tool.*]` tables as the reason it
is not a list of file names.

## R8 — `sdd-run` and `sdd-step`

**Decision**: two scripts, each with checks (constitution III). `sdd-run` is
what the owner types: prerequisites, the permission arguments of R4, the
workflow copy's version against this repository's, then `specify workflow
run` or `resume`, and `usage`. `sdd-step` is what the workflow's `shell` steps
call: `route`, `verify`, `implement`, `outcome`, `mark` and `cleanup` (R10, R6), so every decision the
run takes is a deterministic command with checks of its own.

## R9 — Opt-in and check command are local git config

**Decision**: `git config --local sdd.implement deepseek` opts a repository
in; `git config --local sdd.check "<command>"` declares its check command.
`sdd-run start` stops before any phase when `sdd.check` is absent, naming the
command that sets it (FR-011). The opt-in instruction `sdd-step route` prints
names DeepSeek's terms of service and privacy policy (US3 AS3).

**Why local, not versioned**: the opt-in is this owner's consent, on this
machine; a versioned flag would opt in every clone of a public repository.
The check command is a fact about the project and could be versioned, but
there is no file every repository already has that holds it in a
machine-readable way, and inventing one per repository is a convention for
one consumer; local config keeps both settings in one place.

## R10 — Outcome files, validated; verify without a model

**Decision**: every step writes `<feature>/.sdd/<step>.json`, validated against
`claude/speckit/schemas/<step>.schema.json` by `sdd-step outcome <step>`, which
prints a fixed token the workflow's `if` and `do-while` conditions compare
(`pass`/`fail`, `converged`/`open`, `yes`/`no`) and exits non-zero on a
missing or invalid file (FR-016). Verify is `sdd-step verify`: it runs
`sdd.check`, and writes the exit status and the tail of its output (FR-020).
Review and converge are told through their arguments to write their outcome
file with findings by severity.

**Source**: proposed by the owner, checked against Anthropic's engineering
posts. "How we built our multi-agent research system": "Subagent output to a
filesystem to minimize the 'game of telephone'". "Effective harnesses for
long-running agents": state in `claude-progress.txt`, a JSON feature list and
git; JSON because "the model is less likely to inappropriately change or
overwrite JSON files compared to Markdown files"; a feature marked passing
only after testing, and editing or removing tests unacceptable.

**Validator**: `check-jsonschema` (python-jsonschema's CLI), declared in
`uv-tools.txt` — a new dependency, approved by the owner on 2026-10-21
together with `container` and the worker image's contents. The
alternative, a hand-written stdlib check per outcome, makes the schema code
instead of a contract another tool can read.

**Rejected**: Claude Code's `--json-schema`, which constrains the output as it
is generated and so is stronger than validating after; Spec Kit passes extra
arguments per run, not per step (R4), so each step cannot get its own schema.
Reopen if Spec Kit adds per-step integration arguments for Claude.

**Loops**: `build` (convergence, at most three passes, FR-014) holds
`fix-loop` (one attempt and at most two fix rounds, FR-015), so a run makes at
most nine implementation passes. `fix-stuck` offers `retry` (exactly one more
implement-and-verify round) and `abort`; `converge-stuck` offers `retry` (one
more convergence pass) and `abort`. Without retries a run makes at most nine
implementation passes. Converge counts as converged only when its outcome is
`converged` and it lists no finding above LOW.

**Observed**: a `shell` step exiting non-zero fails the whole run, so loop
conditions read `sdd-step outcome`'s printed token, and a non-zero exit is kept
for what must stop the run (probe: a `do-while` on an exit-code condition
ended `failed` on its first pass).

## R11 — Measuring SC-001

**Correction**: an earlier version of this entry said a Claude step's result
lands in `state.json`. It does not on 1.1.3: `command` and `prompt` steps
stream to the terminal and keep empty `stdout` — the probe had only seen a
`shell` step captured, and the claim generalised it. Upstream fixed it in
1.2.1 with opt-in capture (github/spec-kit#4957), so this feature requires
Spec Kit ≥ 1.2.1 and runs on 1.2.2.

**Decision**: every Claude step sets `capture: true` and an explicit
`timeout` (a captured `command` step otherwise stops at 600 seconds, too
short for plan or converge): 3600 for the judgment phases, 1800 for tasks.
Shell steps have a limit of their own — 300 seconds unless set
(`workflows/step/shell/__init__.py`, `config.get("timeout", 300)`, read on
1.2.2) — enforced by killing the shell, which would orphan a running
`container` or `claude`. So `implement` sets `timeout: 2100`, its maximum limit
plus 300 seconds, `verify` to 3600, and `sdd-step implement` enforces its limit
first, stopping its agent and cleaning up before Spec Kit's limit can fire.
Any leftover from a kill the script could not see is removed by `cleanup`
(R6).
Captured steps are dispatched without `--output-format json`, so `sdd-run`
adds it to `SPECKIT_INTEGRATION_CLAUDE_EXTRA_ARGS`; observed on 1.2.2 with a
stand-in `claude`: `-p /speckit-specify probe --permission-mode dontAsk
--output-format json --model claude-opus-5-5`, and the step's `stdout` in
`state.json` held the JSON result. Since no decision reads an agent's text
(R10), JSON on every step changes nothing else. Captured text is kept in
`state.json` unredacted (upstream's warning), which holds no secret here:
the credential never reaches a Claude step (FR-009). `sdd-run usage <run_id>` sums every attempt per model, failed and
resumed ones included, and the provider's tokens from the worker's outcomes.
**Pending**: that a failed or resumed step's earlier attempt is still in
`state.json` or `log.jsonl`; the first task observes it, and if it is not,
`sdd-run` records each attempt's result itself before resuming.

## R12 — Interrupted runs and stale copies

**Run id**: `sdd-run` generates it and passes it to the engine as
`SPECKIT_WORKFLOW_RUN_ID` (read on 1.2.2: `engine.py` uses it when set,
else `uuid4()[:8]`), so the lock can be named before the run begins.

**Interrupted** (FR-022): `sdd-run` writes the run id, its own process id
and that process's start time (`ps -o lstart= -p <pid>`) to
`$(git rev-parse --git-dir)/sdd/<run_id>.json` at start and resume —
inside git's own directory, per worktree, never committed. A `phase-done`
shell step after each approved checkpoint, and after tasks, appends the phase
to `<feature>/.sdd/phases.json`; `--from` starts at the first phase not in it. On resume, a run in state
`running` whose recorded process is gone is reported with the phases that will
run again — the engine refuses to resume it (`engine.py`, 1.2.2: only `paused`
or `failed` runs resume) — and restarted with `sdd-run start --from <feature dir>`,
whose `resume_from` input makes every phase before the first unfinished one
a skipped `if`. Spec Kit 1.2.2 says a `running` run is not resumable, and its
code has no handling for a process that died (grep of `workflows/` for a stale
or orphaned run: nothing). **Pending**: the first task kills a run mid-step
and records what `state.json` holds, to confirm the `running` state FR-022
relies on. A run interrupted with Ctrl-C is a different case: the engine marks
it `paused` with no gate (`engine.py`, 1.2.2, `KeyboardInterrupt`), so
`sdd-run resume <id>` without a verdict cleans up and lets the engine run the
interrupted step again. Spec Kit's state files are never edited.

**Stale copy**: the workflow's `version` field is compared by `sdd-run` with
this repository's file; a mismatch stops the run, naming the `specify workflow
add` command that replaces the copy (US1 AS7).

## R15 — The engine's version is checked, not assumed

The workflow's `requires.speckit_version` is advisory (`engine.py`, read on
1.2.2: "the advisory pre-conditions documented for workflows"), so
`sdd-run` checks `specify version` ≥ 1.2.1 itself before any step and stops
naming the `uv-tools.txt` pin and `./install.sh` (FR-024).

## R14 — Effort per model

**Decision**: `routing-settings.json`, passed with `--settings`, sets
`modelSettings` — `{"claude-opus-5-5": {"effortLevel": "medium"},
"claude-sonnet-5-5": {"effortLevel": "medium"}}` — and `sdd-run` unsets
`CLAUDE_CODE_EFFORT_LEVEL` before any step (FR-021). pi gets DeepSeek's
`high` reasoning level explicitly.

**Observed in the docs** (code.claude.com, model-config and settings,
2026-10-21): effort resolves as an explicit choice (`CLAUDE_CODE_EFFORT_LEVEL`,
`--effort`, `/effort`) first, then settings (`modelSettings` per model, or
`effortLevel`), then the model's default — `medium` for Opus 5.5 and Sonnet
5.5. `--settings` sits above user, project and local files, below managed.
`max` is accepted by neither settings key. This machine's user settings hold
`medium` for both models, saved through `/effort`; the shell sets
`CLAUDE_EFFORT=medium`, a name Claude Code does not document. **Pending**: a
probe that a `--settings` level wins over the user file's for a `-p` run, and
how the result reports the level. If it does not win, FR-021 cannot be met
by settings, and the work stops for the owner: the remaining levers are an
exported variable or `--effort`, both per run, not per model. The configured
levels are recorded in `.sdd/routing.json` at every start and resume.

**Why medium**: the owner's policy (`docs/claude-settings.md`) is each
model's default unless measured otherwise, and story-workers' decision 0001
already writes a level only to decouple it from the session's. Writing the
defaults out does the same here: a `/effort high` in an interactive session,
or an exported variable, no longer reaches a routed run. DeepSeek's pi
configuration maps every level below the highest to `high` (DeepSeek's "pi
mono" page), so `high` is its floor.

**Alternatives**: `high` or `xhigh` for the judgment phases — plausible for
plan, review and converge, but unmeasured, and it spends the allowance this
feature exists to save; reopen with a one-story A/B. Effort per step rather
than per model — Spec Kit passes extra arguments per run (R4), so each step's
model is the only lever; reopen if Spec Kit adds per-step arguments, together
with R10's `--json-schema`.

## R13 — Time and spend

**Decision**: `sdd-step implement` ends a pass after 30 minutes
(`sdd.implementTimeout` may lower it; a value above 1800 is refused, because
the step's `timeout` in the workflow is a fixed number, 2100, and the inner
limit must always fire first), stopping the container or the `claude`
process; the provider's
prepaid balance is the hard ceiling; each worker outcome records pi's reported
tokens, and `sdd-run usage` prices them from `models.json` (FR-018). macOS has
no `timeout`; the limit is the script's own, around `container stop`.
