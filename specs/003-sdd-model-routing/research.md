# Research: Model routing per Spec Kit phase

Decisions for `003-sdd-model-routing`, each with what was observed and what
lost. Probes ran on 2026-10-21 against Spec Kit 1.1.3 and were rerun the same
day on 1.2.2 (dotfiles PR #154); this feature requires 1.2.2, the version its checks run against (R15) and is built and checked on 1.2.2, in
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

## R2 — Every agent step goes through one dispatcher and a routing table

**Decision**: Spec Kit's workflow engine orchestrates — order, checkpoints,
loops, resume, run state — and every step that runs an agent is a `shell`
step calling `sdd-step agent <phase>`. The dispatcher reads one declarative
table, `claude/speckit/routing.yml`, with a row per phase: `agent`
(`claude` or `pi`), `model` (full id), `effort`, `profile` (the permissions
and context the step gets, R4, R16), `schema` (for steps whose result is
structured, R10) and `timeout`. It runs `claude -p "/speckit-<phase> …"`
with that row's flags, or the pi worker for implementation (R5, R6).

**Observed** (Spec Kit 1.2.2, `integrations/base.py`,
`validate_runtime_config`): the Claude integration does not override it, so a
`command` step with `integration_args` or `integration_options` is refused
("does not support per-step 'integration_args'"); a Claude `command` step
can set its model and nothing else, and every other flag is per run
(`SPECKIT_INTEGRATION_CLAUDE_EXTRA_ARGS`). Effort, permissions, context and
output schema per step therefore cannot come from native `command` steps on
this version. No upstream issue or pull request asks for it (searched
2026-10-21).

**Why this is not a workaround**: a `shell` step is the engine's supported
primitive for running a command, and the dispatcher reimplements only the
part of Spec Kit's dispatch this feature needs (`claude -p <prompt> <flags>`,
`integrations/base.py`, about ten lines), under checks of its own. **Reopen**:
when Spec Kit's Claude integration accepts per-step arguments, the agent
steps go back to native `command` steps with the table's values as
`integration_args`.

**Alternatives**: native `command` steps — model per step only (above).
One interactive session with judgment phases in it and only implement
scripted (the independent audit's smaller design, 2026-10-21) — fewer parts
and no cold start per phase, but no per-step model, effort or permissions, the
owner's stated requirement; the cold start it avoids is measured in R16 and
mostly cached away. A per-phase Claude Code subagent — fixed model per agent
definition, but no effort, schema or permission profile per call, and it
runs inside a session the workflow cannot checkpoint.

Full ids, not the `opus`/`sonnet` aliases ("To pin to a specific version,
use the full model name", code.claude.com model-config).
## R3 — Every checkpoint is a gate with a verdict input

**Observed**: a `shell` step gets no terminal (probe: `[ -t 0 ]` false, `read`
got an empty line, stdout captured into `state.json`). A gate with no verdict
input pauses without a TTY, and a bound verdict input set on resume decides it
(docs, "Gate Verdict Inputs").

**Decision**: every gate binds a verdict input declared by the workflow,
`enum: ["", <its options>]`, default `""`, so `sdd-run resume <id> <verdict>`
answers any of them (FR-004). Clarify's questions go to
`<feature>/clarify-questions.md` (Markdown, for the owner); `clarify-ask` is
told through its prompt to write them there with a recommendation each and to
edit nothing else, and returns the count as structured output (`--json-schema`)
that the dispatcher writes to `clarify.json` (R2, R10);
the gate `answer-clarify` shows the file (`show_file`); `clarify-apply` runs
clarify again with "the answers are in clarify-questions.md; ask nothing".

**Pending**: the semantics of a gate's non-approve options (`retry` for
`fix-stuck`, R10) are read from the engine's code and observed in the first
task, before the workflow relies on them.

**Alternatives**: clarify by hand outside the workflow — the owner would pick a
model by hand (SC-005). Answers as a verdict — a verdict must match one of the
gate's options, so free answers do not fit.

## R4 — Headless permissions fail closed, one profile per step

*Since R21 the boundary is the worker container and each step's write allow
list; the profiles below remain inside it as least privilege, and the
host-side `--setting-sources` and sandbox questions no longer bear on safety.*

**Decision**: every Claude step runs with `--permission-mode dontAsk` and
the `--settings` file its routing row names — a profile in
`claude/speckit/profiles/` (names as of R21). `author` (specify, clarify, plan, checklist, tasks, converge) allows the
file tools, the named Spec Kit scripts (R19) and exact read-only git; `reader` (analyze,
review) allows reading and nothing that writes; every step also runs with
`--setting-sources ""`, so its profile — which carries the config-guard and
git-guard hooks — is its only source of permissions and hooks, and neither the
owner's user settings nor the routed repository's can widen it (pending T003,
which also checks that project skills and CLAUDE.md still load; fallback:
`--setting-sources user` with an empty user allow list and no user hook but
the guards, both checked by `sdd-run`); `implement-sonnet` allows the file
tools limited to its checkout and `Bash(<sdd.check>)`, composed per pass by
`sdd-step implement`. A denied call is denied, not asked, so an unattended
step never waits and never does what its profile does not allow.

**Observed in the docs** (code.claude.com, headless, read 2026-10-21):
`dontAsk` "denies every call that would otherwise prompt, which is useful for
locked-down CI runs", and denials are listed in the result's
`permission_denials`. **Pending**: that a denial makes the step exit
non-zero on this CLI version; the first task observes it, and the dispatcher
fails the step naming the refused tool either way.

**Why not**: `bypassPermissions` — refused by this machine's
`disableBypassPermissionsMode`. `auto` — a classifier decides; in the T3 Code
spike of 2026-10-18 an Auto mode accepted `config-guard`'s ask on `ruff.toml`
(sdd-decisions). One allow list for every step — wider than any one step
needs (least privilege); possible only while flags were per run (R2).
## R5 — The worker's runtime: a container with a deny-by-default firewall

**Decision**: pi runs in a Linux container built on Anthropic's reference
devcontainer pattern (`anthropics/claude-code/.devcontainer`, read
2026-10-21): an `ipset` of allowed domains, `iptables -P OUTPUT DROP`, a
`REJECT` for everything else, the `NET_ADMIN` and `NET_RAW` capabilities
granted only for the firewall script that runs at start, and the agent as the
non-root user `node`. The allowed domains are `containers/worker/egress-registries.txt` plus the pass's provider host:
DeepSeek's API host and the registries the toolchain installs from.

**Why the firewall lives in the container, not the runtime**: Apple's
`container` documents isolation between networks but no egress allow list
(`docs/networking.md`, read 2026-10-21), so the runtime alone cannot meet
FR-007; the reference pattern enforces it inside the container on any runtime
that grants `NET_ADMIN`, which is the published way to do it.

**Runtime**: Apple `container` (Homebrew formula, one VM per container) if it
grants `NET_ADMIN` and its kernel has netfilter; otherwise colima (Homebrew
formula, open source, a Lima VM) with the Docker CLI. **Pending**: the first
task tries the firewall script under Apple `container` and records the
result; colima is the fallback, decided by that observation, not assumed.
Docker Desktop, found installed and undeclared, is not used: it is drift on
this machine and carries a commercial licence above a company size.

**Alternatives**: Claude Code on DeepSeek's Anthropic-compatible endpoint
inside Claude Code's own sandbox — measured in the spike of 2026-10-21 (R17)
at equal quality, but Anthropic "doesn't support routing Claude Code to
non-Claude models through any gateway" (code.claude.com, llm-gateway), so it
may break in any release; its sandbox also covers shell commands only, not
the file tools. pi's own sandbox extension — runs in pi's process, so the
boundary is the agent's own code. A proxy written here in front of Apple
`container` — a component of our own where a published pattern exists.
**Observed** (T002, 2026-10-21, macOS 27.0.1, `container` 1.6.0 from Homebrew;
the formula's caveat names `container system start`): `container system start
--enable-kernel-install` started the services and downloaded the default
kernel to `~/Library/Application Support/com.apple.container/kernels/` (29 MB
in all); its launchd services are registered for the session, no
LaunchAgent plist is written, so they do not survive a reboot. A
`debian:bookworm-slim` container run with `--cap-add CAP_NET_ADMIN --cap-add
CAP_NET_RAW` installed `iptables` and, with `OUTPUT` set to DROP and one host
allowed, reached `registry.npmjs.org` (HTTP 200) and was refused
`example.com`. A host server bound to the network's gateway address
(`192.168.64.1`) could not start before a VM existed — the bridge interface
appears only while one runs — and binding it to `0.0.0.0` would expose it to
the local network. Two containers on the default network (`192.168.64.0/24`)
did reach each other: a container whose firewall allowed only the other's
address on one port got HTTP 200 from it and was refused both the host and
the internet. **Runtime chosen: Apple `container`**, declared in the `Brewfile`;
colima was not needed. Its kernel is applied by `install.sh` (step 6b) and
reported by `drift.sh` (seen red with the kernel moved away); `sdd-run` starts
the services when they are not running.

## R6 — A disposable checkout, mounted alone

*The checkout described here — a detached git worktree — is superseded by R20
and R21: a `git archive` export with no `.git` (contracts/pass.md). The image,
credential and git-on-the-host decisions stand.*

**Decision**: for each implementation pass, `sdd-step implement` commits the
feature directory, then creates a detached git worktree of that commit in a
temporary directory — tracked files only, so no untracked `.env` or ignored
secret reaches the agent — and mounts it alone at `/work`. Afterwards it takes
the pass's changes as a patch (`git diff --binary` plus new files), judges it
(R7), applies it to the feature's worktree, commits, and removes the
checkout. A pass that fails, times out or crashes leaves the feature's
worktree untouched, so resume finds it clean (US2 AS7). The Sonnet path uses
the same checkout, judgment and time limit, running `claude -p` on the host
in it under the `implementer` profile (R4); superseded by R21, where it runs in the worker container; no code leaves for a new
provider, and its JSON result goes into `implement.json`. Every checkout,
container and volume is labelled with its run id, so `sdd-step cleanup` can
remove what a killed pass left.

**Tool cache**: a volume per run, `sdd-cache-<run_id>`, removed when the run
completes, so concurrent runs share no writable state. Ceiling: each run
installs its toolchain afresh; if that takes long enough to matter, a
read-only shared cache populated on the host is the next step.

**Image**: `containers/worker/Containerfile`, digest-pinned Node base,
`@earendil-works/pi-coding-agent@1.3.0` (`npm view` 2026-10-21; the
`@mariozechner` package is deprecated in its favour), mise, uv, `iptables` and
`ipset`, the firewall script of R5 and a non-root `node` user; DeepSeek's
provider entry for pi's `models.json` from DeepSeek's "pi mono" page with the
id the API serves: `GET /models` with the owner's key lists `deepseek-flash`
and `deepseek-v4-pro` (HTTP 200, 2026-10-21), not the page's
`deepseek-v4-flash`, and the spike of R17 ran on `deepseek-flash`. Tagged with
the Containerfile directory's hash and built when the tag is missing: a cache
of a declared file (constitution IV).

**Credential**: written to the container's stdin, read once by the entrypoint
into pi's environment inside the container, after the firewall is up; pi's
session directory is outside `/work` and discarded with the container
(FR-009). Observed in R17's spike: `read -r` from stdin, no file, no argument.

**Git stays on the host**: the worker gets no git; baseline, patch and commit
are taken on the host.
**Firewall and entrypoint scripts**: `init-firewall.sh` is adapted from
Anthropic's reference (`anthropics/claude-code/.devcontainer/init-firewall.sh`,
read 2026-10-21) — the allow list read from `egress-registries.txt` and the pass's provider host instead of hard-coded
domains — so it is owned and checked here (constitution III), not vendored;
its source and date sit in a comment beside it (constitution VI).

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
what the owner types: prerequisites, the run id, the
workflow copy's version against this repository's, then `specify workflow
run` or `resume`, and `usage`. `sdd-step` is what the workflow's `shell` steps
call: `agent` (R2, which also writes a row's `result_to`, such as analyze's report), `route`, `verify`, `implement`, `outcome`, `phase-done`, `mark` and `cleanup` (R10, R6), so every decision the
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
Clarify-ask, review and converge return their outcome as structured output
(`--json-schema`), which the dispatcher writes to the outcome file; review's
`reader` profile could not write it itself.

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

**Structured output at generation**: the steps whose result is structured —
clarify-ask, review and converge — run with `--json-schema <their schema>`, which
constrains the output as it is generated (code.claude.com, headless:
`structured_output` in the result); the dispatcher writes that object to the
outcome file, and `sdd-step outcome` still validates it, so a schema drift
fails loudly at either end. This was rejected while flags were per run; the
dispatcher of R2 makes it per step.

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
`shell` step captured, and the claim generalised it. Upstream added opt-in capture in
1.2.1 (github/spec-kit#4957); the dispatcher of R2 no longer relies on it, and
the floor is 1.2.2 for the reason R15 gives.

**Decision**: every agent step is a `shell` step (R2), whose stdout the
engine keeps in `state.json` (probe, 1.2.2); the dispatcher prints a one-line
summary there, and usage goes to the run's usage log (contracts/routing.md),
the one source `sdd-run usage` reads.
Shell steps stop at 300 seconds unless set (`workflows/step/shell/__init__.py`,
`config.get("timeout", 300)`, read on 1.2.2), by killing the shell, which
would orphan a running agent. So every agent step's `timeout:` in the workflow
is a ceiling — its routing row's `max_timeout` plus 300 seconds, a literal the
workflow schema requires — and the dispatcher enforces the effective `timeout`,
never above `max_timeout`, first, stopping its agent and cleaning up before Spec Kit's
limit can fire; `verify` sets 3600. Any leftover from a kill the script could
not see is removed by `cleanup` (R6). Captured text is kept in `state.json`
unredacted (upstream's warning), which holds no secret here: the credential
never reaches a Claude step (FR-009). `sdd-run usage <run_id>` sums every attempt per model, failed and
resumed ones included, and the provider's tokens from the worker's outcomes.
**Where SC-001 is measured**: on story-workers' eval harness
(`tests/eval/run.sh`, `usage.py`, three recorded evals), not by a protocol
written here. Four review rounds on an ad-hoc protocol in this feature kept
finding new gaps — the fixture's committed `specs/`, the commands
story-workers' workers run, failed-run rules — each of which the harness
already settles (hermetic setup, committed states, counted / not counted /
refused exits, version matching, held-out tests). Measuring from tasks onward
is exact rather than a shortcut: every earlier phase runs on Opus in both
arms. Correction, the same day: the harness runs single-step arms only (one
`claude -p /speckit-implement` per run), so it does not "already settle" a
multi-step arm's gates and counting; SC-001 now fixes those, and T052
extends the harness to them. Three counted runs per arm on both fixtures,
from Anthropic's "Demystifying evals for AI agents". The routed arm starts with `sdd-run start --from`, the fixture's state
carrying `.sdd/phases.json` with specify and plan done.

**Pending**: that a failed or resumed step's earlier attempt is still in
`state.json` or `log.jsonl`; the first task observes it, and if it is not,
`sdd-run` records each attempt's result itself before resuming.

## R12 — Interrupted runs and stale copies

**Run id**: `sdd-run` generates it and passes it to the engine as
`SPECKIT_WORKFLOW_RUN_ID` (read on 1.2.2: `engine.py` uses it when set,
else `uuid4()[:8]`), so the lock can be named before the run begins.

**Interrupted** (FR-022): `sdd-run` writes the run id, its own process id
and that process's start time (`ps -o lstart= -p <pid>`) to
the run bundle's `lock.json`, `$SDD_RUN_DIR`, at start and resume — inside
git's common directory, shared by the repository's worktrees, never
committed (R19). A `phase-done`
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
`sdd-run` checks `specify version` itself before any step and stops naming the
`uv-tools.txt` pin and `./install.sh` (FR-024). The floor is 1.2.2, the
version every check of FR-025 runs against: the ≥ 1.2.1 floor recorded
earlier was for `command`-step capture, which the dispatcher of R2 no longer
uses, and no older version has been checked.

## R14 — Effort per step

**Decision**: each row of the routing table names its effort, and the
dispatcher passes it as `--effort <level>`, which takes precedence over every
settings file (code.claude.com, model-config: an explicit choice first, then
settings, then the model's default). `sdd-run` unsets
`CLAUDE_CODE_EFFORT_LEVEL`, which would otherwise win over the flag's peers
in the environment. pi gets `--thinking <level>` from the same table.

**Levels**: `medium` for every Claude step — the documented default for Opus
5.5 and Sonnet 5.5, so writing it changes nothing today and only shields a
run from an interactive `/effort` or an exported variable; `high` for the pi
step, DeepSeek's floor (its pi configuration maps every lower level to
`high`). A higher level for plan, review or converge is a change to measure
on one story first, then a one-line edit of the table.

**Observed** (2026-10-21, R16's probe): changing effort between two otherwise
identical `-p` calls on the same model read the same cached prefix as an
unchanged repeat (18,052 tokens either way), so effort per step does not
break the prompt cache.
## R16 — Context per step: no MCP servers, the cache kept warm

(Profiles differ in permission rules only, never in tools offered, so the
tool definitions in the cached prefix match across a same-model group;
whether a profile change still moves the prefix is observed by T003.)

**Decision**: every Claude step runs with `--strict-mcp-config` and an empty
MCP configuration, and with only the tools its profile names. The workflow
keeps steps on the same model together (specify to analyze on Opus, then
tasks, then implementation, then review and converge on Opus).

**Observed** (2026-10-21, five identical minimal `claude -p` calls on Sonnet
5.5 in a scratch repository, Claude Code 2.1.306):

| Call | Context | Cache written | Cache read |
|---|---|---|---|
| with the owner's MCP servers | 43,637 | 32,174 | 11,461 |
| the same again | 45,256 | 27,202 | 18,052 |
| the same, effort changed | 44,670 | 26,616 | 18,052 |
| no MCP servers | 22,944 | 11,480 | 11,462 |
| no MCP servers, again | 22,944 | 0 | 22,942 |

The owner's MCP servers double each step's context and keep the prefix from
matching between processes, so even an identical repeat rewrote 27K tokens to
the cache. Without them a second step on the same model reads its whole
prefix from the cache, at about a tenth of the price. A change of model
starts a new cache (caches are per model), which is why same-model steps are
grouped.

## R17 — DeepSeek through pi and through Claude Code, measured

**Observed** (2026-10-21, one task, a throwaway repository: a `parse_duration`
function from a spec, test-first, scored by 19 held-out tests the agents did
not see; same prompt, `deepseek-flash` both times):

| | Claude Code on DeepSeek's endpoint, sandboxed | pi in a container |
|---|---|---|
| Finished | yes | yes |
| Held-out tests | 19/19 | 19/19 |
| Own tests | 35 | 53 |
| Turns / tool errors | 15 / 0 | 8 / 1 |
| DeepSeek cost | about $0.0125 | about $0.0027 |

Both work at equal quality on this task; pi used about a fifth of the tokens.
One task: directional. pi is kept (R5) because it is the path DeepSeek
documents and supports and it runs inside a full container boundary; Claude
Code on DeepSeek is unsupported by Anthropic.

## R18 — Layered routing configuration

**Decision**: the routing table merges four layers (contracts/routing.md):
defaults in dotfiles, a versioned project file, a git-ignored local file, and
a run's `--set` overrides; per phase and per field; validated layer by layer
and merged; recorded with each value's source.

**Source**: Claude Code's own settings model — "managed settings, command
line, project local, shared project, user", where "a key set at a higher level
overrides the same key set lower down" and the local file stays out of git
(code.claude.com, settings, read 2026-10-21) — and `specify workflow resolve`,
which prints each step's source layer.

**Why the opt-in is not a layer**: a versioned routing file would otherwise
opt in every clone of a public repository (research R9).

**Alternatives**: one table in dotfiles — no per-repository or per-run change
without editing a shared file; environment variables per field — no
validation of the whole and no provenance; Spec Kit workflow overlays — they
cannot hold values the workflow does not carry (research R2).

## R19 — The run bundle and defence in depth

*The bundle stands. Its host-side defences — deny lists and Claude Code's Bash
sandbox around agents running on the host — are superseded by R21, which runs
every agent step in the worker container.*

**Finding** (fresh-context analysis, 2026-10-21): with profiles, hooks, skills
and the opt-in read live, a judgment step allowed `Bash(.specify/scripts/bash/*)`
and unrestricted Write could write a script there and run it — `git config
sdd.implement deepseek` would have sent code to DeepSeek without the owner's
opt-in — or edit a later step's skill or profile.

**Decision**: what governs a run is copied into a bundle in git's common
directory at start (contracts/routing.md) and read only from there; the
opt-in is frozen with it and can only be downgraded mid-run. Profiles allow
Bash for named scripts and exact read-only git subcommands only, and deny Edit
and Write on git's directory, `.claude/**`, `.specify/**`, `.sdd/**` and the
bundle. Claude Code's Bash sandbox runs under every profile with no network
and writes limited to the worktree minus those paths, so the operating system
enforces what the rules state (code.claude.com, sandboxing: "a boundary that
the operating system enforces around the shell commands").

**Alternatives**: rules alone — one hole in a pattern is a hole; the sandbox
alone — it covers shell commands, not the file tools; running every Claude
step in a container — the strongest boundary, but the Claude steps need the
owner's subscription login inside it, which this feature does not move.

## R20 — The threat model, and what follows from it

**Finding** (adversarial analysis, 2026-10-21): a disposable checkout that is a
git worktree has a `.git` file the agent can rewrite, so a host-side `git diff`
could run a hook it planted (`core.fsmonitor`); verify ran model-written tests
on the host; the patch and the judgment steps could change skills,
`CLAUDE.md` or `.sdd/` files later steps read; specify must write
`.specify/feature.json`; a cold image build could eat the margin before Spec
Kit's own limit.

**Threat model**: the implementing and judging agents are untrusted authors.
What they write is data until judged; nothing they wrote runs outside the
container; nothing that governs the run is within their reach; no host tool
reads anything they wrote as configuration. Scoped in R23: against mistakes
and planted instructions, with two residual risks accepted.

**Decisions that follow**: the disposable copy is a `git archive` export with
no `.git`, and the patch is a `git diff --no-index` run outside any repository
with system and global configuration disabled; verify runs in the worker
container on a fresh export, egress limited to the allow list, for both paths;
the patch is refused if it touches the protected set (`.git*`, `.claude/**`,
`.specify/**`, `.sdd/**`, `CLAUDE.md`, `AGENTS.md`), and the profiles deny
writing it, except `.specify/feature.json` by exact path; the image is built
by its own step before the first pass, and an implement pass's limit covers
the whole pass; the check command is frozen in the bundle.

**Alternatives**: chasing vectors one by one — every round of review found
another. A container for every Claude step was rejected here at first because
the subscription login would have to enter it; R21 adopts it, with the token
`claude setup-token` documents for scripts. The protected set listed above is
superseded by contracts/pass.md's.

## R21 — Every agent step is a contained pass

**Finding** (adversarial analysis, 2026-10-21): enforcing R20 by listing
forbidden files kept leaving the next file out. Proven: an untracked
`mise.toml` in a directory makes mise refuse to run `python3` there ("Config
files in …/mise.toml are not trusted", exit 1), and config-guard, which fails
open, then passes everything. The judgment agents, as untrusted as the
implementers, wrote straight into the worktree host tools run in.

**Decision**: every agent step and every verify run the same contained pass
(contracts/pass.md): a `git archive` export with no `.git`, the agent in the
worker container behind the firewall, its output returned as a patch computed
outside any repository with git's configuration disabled and absolute paths,
judged against the row's positive `writes` list — deny by default, like the
firewall — then applied by git with hooks and fsmonitor off on a worktree no
agent touched. Claude runs in the container with the owner's subscription
token from `claude setup-token` ("a one-year OAuth token for CI pipelines and
scripts", requiring a Pro, Max, Team or Enterprise plan; code.claude.com,
authentication, read 2026-10-21), read from the Keychain item `claude-oauth`
(how it reaches the provider is R23's egress proxy; no container holds it). The container's home holds no
settings, MCP server or global CLAUDE.md of the owner's, so each step's
context is the export plus its profile — what R4 and R16 sought with
`--setting-sources ""`, here by construction.

**What it replaces**: host-side profiles with deny lists and Claude Code's
Bash sandbox as the boundary for the judgment steps (R4, R19), and the
pending question of `--setting-sources ""`. The sandbox and the deny lists
were defence by enumeration; the container and the write allow list are
defence by construction.

**Cost**: every routed run needs the container runtime and the owner's
Claude token; each pass starts a container (seconds). The prompt cache is
held by the API, not the machine, so R16's cache reuse is unchanged.
`--bare`, the mode the headless docs recommend for scripts, does not read the
subscription token, so it is not used.

**Alternatives**: host-side enforcement by deny lists (R19) — refuted by the
`mise.toml` finding; Claude Code's sandbox — covers shell commands, not the
file tools or host tools run afterwards; an API key for the Claude steps —
billed per token outside the subscription this feature exists to save.

## R22 — No MCP server in any pass, and when that would change

**Decision**: no pass loads an MCP server (FR-026). The owner's servers carry
the owner's credentials — mail, documents, a brokerage account that can place
orders, a car — and an unattended agent working on untrusted output has no
business near them; they also doubled each step's context and broke the cache
between steps (R16). No Spec Kit phase needs one: every phase works from the
repository's files.

**Reopen when** a phase needs something only an MCP server provides — the
likely case is current library documentation (Context7) for plan or
implement. The design then is a per-row `mcp` list in the routing defaults
(never in a layer), limited to servers that hold no credential of the
owner's, each server's host added to that pass's firewall allow list only,
and the list frozen in the run bundle like every other input that governs a
run. A server holding the owner's credentials never runs in an unattended
pass. Not built now: no phase asks for it, and an extension point nobody uses
is code to maintain for nothing.

## R23 — The egress proxy, and the threat model's scope

**Finding** (sixth review round, 2026-10-21): an agent holding a credential in
its environment can always smuggle it out encoded — the exact-value scan
misses base64 — through any host it may reach, a package registry included;
and a cache shared between the implementer and verify let an implementer plant
a tool verify would run. Each round had found new channels of this kind.

**Decision**: no agent's container holds a credential. A proxy (contracts/pass.md,
"The egress proxy") is every agent container's only destination. Since T002
(R5) it runs in a container of its own — its own VM — on a network created for
the run, not as a host process: a host listener would have to bind every
interface, the bridge address existing only while a VM runs. The proxy: it holds the credentials, adds them to requests bound for the
provider's API — the LLM-gateway arrangement Claude Code documents, including
for subscription OAuth traffic forwarded to Anthropic (code.claude.com,
llm-gateway, read 2026-10-21) — tunnels the package registries for implement
and verify passes, and refuses everything else; the container's firewall
allows only the proxy, so no DNS leaves it either. Caches are per pass kind,
never shared between implementer and verify. The proxy is written in Python's
standard library and runs on the worker image's Python, with checks
(constitution III); its credentials reach it on its container's stdin.

**Scope**: protected against agents' mistakes and against instructions
planted in what they read (prompt injection) — the credentials, the machine,
the run's governance and its checks. Accepted, written in the spec's
Assumptions and not defended further: a deliberately malicious agent smuggling
repository code out encoded through a host it is allowed to reach; a planted
automation file (hook, CI workflow, editor task) running after the owner
merges it, which FR-030 lists at the last checkpoint. Security practice
states a threat model's limits rather than chasing every channel: each of the
six review rounds found another, and the owner's merge review is the control
these two are left to.

**Alternatives**: credentials on the container's stdin with an exact-value
scan — encoded copies pass it; Claude Code's sandbox credential masking —
host-side and Claude-only, not for pi; mitmproxy — a new dependency where the
standard library suffices for a plain-HTTP gateway and a `CONNECT` tunnel;
blocking every automation path in the patch — legitimate features add hooks
and CI, as this one adds checks.

## R13 — Time and spend

**Decision**: `sdd-step implement` ends a pass at the effective implement
row's `timeout`, 1800 seconds by default; a routing layer may set it anywhere
up to the row's `max_timeout`, 3600, and a value beyond is refused, because
the step's `timeout` in the workflow is a fixed 3900 and the inner limit must
always fire first; an earlier version allowed only lowering the limit, an
artefact of setting the workflow's timeout at the default rather than at a
ceiling; it stops the container
or the `claude` process; the provider's
prepaid balance is the hard ceiling; each worker outcome records pi's reported
tokens, and `sdd-run usage` prices them from `models.json` (FR-018). macOS has
no `timeout`; the limit is the script's own, around `container stop`.
