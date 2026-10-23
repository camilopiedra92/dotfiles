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

**Observed** (T004, 2026-10-21, Spec Kit 1.2.2): a gate treats only an option
named `reject` or `abort` as a rejection (`workflows/step/gate/__init__.py`);
any other choice approves, and its bound verdict input is never reset, so it
answers every later occurrence of the gate by itself — a `retry` bound once
ran a three-pass loop to its end without asking again. A failed shell step
is re-executed by `resume` (its two attempts both in `log.jsonl`); a run whose
process is killed stays `running` and `resume` refuses it ("Cannot resume run
… with status 'running'"). Spec Kit's `check-prerequisites.sh` with
`SPECIFY_FEATURE_DIRECTORY` and `create-new-feature.sh` work in an export with
no `.git`; the latter numbered the next feature and wrote
`.specify/feature.json` as `{"feature_directory":"specs/<n>-<slug>"}`.
**Decision**: the two stops inside loops — `fix-stuck` and `converge-stuck` —
are shell steps (`sdd-step stuck`), not gates: they fail the step to stop the
run, and `sdd-run resume <id> retry` writes a one-shot verdict file they
consume, so each `retry` buys exactly one round and the next stop asks again.

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
## R24 — T003: Claude Code in the worker, through a token-injecting gateway

**Observed** (T003, 2026-10-21, Claude Code 2.1.306 in a `node:24-bookworm-slim`
container on Apple `container` 1.6.0, its firewall allowing only a gateway
container on a network made for the probe): with `ANTHROPIC_BASE_URL` at the
gateway and `CLAUDE_CODE_OAUTH_TOKEN=placeholder`, the gateway replacing the
`Authorization` header with the owner's `claude-oauth` token read from its
own stdin, `claude -p` answered (`POST /v1/messages -> 200`, `is_error`
false, model `claude-sonnet-5-5`); the agent's container could not reach
`api.anthropic.com` directly and held no real token in its environment.
Against a `git archive` export of this repository with no `.git`:

- `--setting-sources ""` loaded neither the project's skills nor its
  CLAUDE.md (the agent listed no `speckit-*` skill and no constitution);
  `--setting-sources project` loaded all ten `speckit-*` skills and the
  constitution through CLAUDE.md's import. **Decision**: `--setting-sources
  project`. The export's tracked `.claude/settings.json` then applies inside
  the container; it can widen what an agent may do there, which the container,
  the gateway and the patch's `writes` list bound.
- `--json-schema` returned the requested `structured_output`.
- A refused tool left the exit status 0 and listed the tool in
  `permission_denials`, so the dispatcher reads that field.
- A profile that `deny`s Edit and Write removes those tools from the model's
  tool list, changing the cached prefix. Two profiles differing only in their
  `allow` lists kept the prefix: an Opus call with the `reader` profile right
  after one with `author` read its whole prefix from the cache (18,502 read, 0
  written). **Decision**: profiles allow, never deny; under `dontAsk` an
  unallowed tool is refused at call time anyway.
- A minimal step's context was about 18.5K tokens, against 43K on the host
  with the owner's MCP servers (R16). The JSON result carries no effort level,
  so the usage log records the level given, not one reported.

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

**Observed** (T016, 2026-10-21): `containers/worker/` built with `container
build` in about 70 seconds. Run on a network of its own with `NET_ADMIN` and
`NET_RAW`, `SDD_PROXY` naming a stand-in proxy container (Python's
`http.server`) on it: the command ran as `node` with `NoNewPrivs: 1` and every
capability set empty (`CapPrm`, `CapEff`, `CapBnd` all zero); the stand-in
answered HTTP 200; `1.1.1.1:443`, the host gateway `192.168.64.1` and a DNS
lookup all failed; its environment held only the entrypoint's allow list; pi's
`models.json` carried the proxy's URL and was still owned by `node`. Claude
Code 2.1.306, pi 1.3.0, Python 3.11.2, mise 2026.10.7 and uv 0.13.0 answered
`--version`. Installed with `--ignore-scripts`, `claude` was only a stub
printing how to run its postinstall; the image runs that one script by name
(`install.cjs`, which copies the native binary from npm's optional dependency,
offline). Neither `ipset` nor a resolver is installed: with the proxy as the
only destination (R23) the firewall allows one address and resolves nothing,
so R5's "ipset of allowed domains" no longer applies.
Run with the pass's mounts (`/work`, `/bundle` read-only holding a filled
`models.json`, a cache volume at `/cache`): the command started in `/work` as
`node` and wrote there; pi's `models.json` in node's home was the bundle's;
`/cache` was node's and npm's and uv's caches pointed into it; a
`models.json` whose `baseUrl` was `https://api.deepseek.com` stopped the
container before its firewall, naming the file.

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

**Observed** (T006, 2026-10-21, pi 1.3.0 in a firewalled Apple container,
its `models.json` pointing `baseUrl` at a gateway container that replaced a
placeholder key with the owner's `deepseek-api` key read from its own
stdin): the agent's container could not reach `api.deepseek.com` directly;
`GET /models` through the gateway listed `deepseek-flash` with the name
`DeepSeek-V4.1-Flash`; `pi -p --mode json --no-session --model
deepseek/deepseek-flash --thinking high` answered (`POST /chat/completions ->
200`, about $0.00016) and reported the model as the bare alias
`deepseek-flash`. So the alias is accepted as unpinned (spec, Assumptions),
and the egress proxy records, at the start of each run, the `/models` name
behind the configured id in the bundle's `routing.json`, so a change of the
model behind the alias shows between runs.

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

**Observed** (T005, 2026-10-21): run from a copy in the bundle with
`PATH=/usr/bin:/bin`, the guard answered `ask` to an empty `Write` to
`ruff.toml` (how a deletion is judged) and to a `pyproject.toml` that lost
`[tool.ruff]`, and gave no decision for an ordinary source file. Run instead
with the owner's `PATH` from a directory holding a planted `mise.toml`
(`python = "3.12"`), mise's shim for `python3` began downloading and
installing Python 3.12.15 and the guard printed no decision — failing open,
and installing a runtime because of a file an agent could write. The install
was removed after the probe (`mise uninstall python@3.12.15`). This is what
the fixed `PATH` and bundle working directory of contracts/pass.md prevent; the
guard's own use as an interactive hook in an untrusted repository has the same
exposure and is outside this feature.

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
most nine implementation passes. `fix-stuck` takes `retry` (exactly one more
implement-and-verify round) or `abort` (R3: one-shot, not a gate); `converge-stuck` takes `retry` (one
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
context is the export plus its profile. (Correction, R24: the export's own
skills and CLAUDE.md load only with `--setting-sources project`, which also
loads its tracked `.claude/settings.json`, bounded by the container.)

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

**Observed** (2026-10-21, the first real pass, after Phase 2): in a scratch
repository, `prepare-worker`, `egress-proxy` with the owner's `claude-oauth`
from the Keychain, and `sdd-step agent plan` on a Sonnet row whose prompt
asked for one file: Claude Code 2.1.306 ran in the firewalled worker as
`node`, reached Anthropic only through the proxy (`POST /v1/messages ->
anthropic 200`, twice), wrote the file; the judge passed it and it landed as
one commit, `plan: 001-smoke (claude-sonnet-5-5)`, in 5.5 seconds for
$0.066. The credential was in no log. Claude Code also opened its own
`CONNECT api.anthropic.com:443` (non-essential traffic) outside
`ANTHROPIC_BASE_URL`; the proxy refused each, and Python's default handler
printed a traceback per client reset. The worker now sets
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and the proxy logs a reset as one
line; a second run showed only the two API calls. After `egress-proxy` is
stopped, the proxy container and the run's network are gone within the
runtime's stop grace period (seen at 3 s still present, at 11 s gone).

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

**Observed** (review of Phase 2, 2026-10-21): from the worker, as `node`, with
its firewall up, an `AF_VSOCK` connection to every port from 1 to 65535 on
CID 1 (local) and CID 2 (the host) was reset, none accepted, and the guest's
own CID answered ENODEV: the firewall filters IP only, and no vsock service
was reachable around it. The registries include `github.com` and its release
hosts, which mise's downloads need; a `git push` to an account the agent
names is the accepted smuggling channel above, as an `npm publish` is.

Residuals named by that review and accepted, each with its reason: `git
archive` applies the repository's own attribute filters, which only the
owner configures (no agent writes `.git` or `.gitattributes`); the worker
image's tag names its recipe (containers/worker/), not its bits — apt
packages and npm's transitive dependencies are not pinned, so a rebuild after
an image is deleted may differ, and drift.sh reports the pins that are; the
proxy starts a thread per connection with no cap, since a run has one pass
at a time (its client and upstream connections time out and are closed on
every path).

**Alternatives**: credentials on the container's stdin with an exact-value
scan — encoded copies pass it; Claude Code's sandbox credential masking —
host-side and Claude-only, not for pi; mitmproxy — a new dependency where the
standard library suffices for a plain-HTTP gateway and a `CONNECT` tunnel;
blocking every automation path in the patch — legitimate features add hooks
and CI, as this one adds checks.

## R27 — What runs in the worker, and what belongs outside it

**Decision** (2026-10-21, the owner's review of the image): the image holds the
runtime only — the agents, the firewall and entrypoint, the inventory script,
and the tools the agents and Spec Kit call there: `rg` and `fd` (pi's grep
and find tools need them and otherwise download them at run time), `jq` and
PyYAML (Spec Kit's scripts parse JSON with jq, falling back to fragile
grep/sed, and resolve preset templates with PyYAML), `xz` and `unzip` (mise's
downloads), `make` and `ps` (check commands). No git: the export has no
history, and without it no pass holds a push client. What governs a run —
the implementing agent's brief, pi's models and their prices, the registries
the proxy lets passes read — lives in `claude/speckit/` and is frozen in each
run's bundle at start, like the routing table: changing it rebuilds no image
and changes no run in progress.

**Observed** (the first real run, 2026-10-21): Spec Kit 1.2.2's specify skill
creates the feature directory with `mkdir`, `cp` and a `printf` redirected
into `.specify/feature.json`, not with `create-new-feature.sh`. Claude Code's
permission rules match a `Bash(<prefix>:*)` prefix only up to a word boundary
(`mkdir -p specs/:*` does not match `mkdir -p specs/001-x`), and a shell
redirect into a file is a file write matched by path (`Edit(<path>)`), not by
the bare `Edit` rule; probed with `claude -p --permission-mode dontAsk`. The
first fix allowed those commands one by one; the plan phase then ran
`SPECIFY_FEATURE_DIRECTORY=… setup-plan.sh --json; echo; cat spec.md` — an
environment prefix and a compound command no prefix rule matches — the third
distinct denial in three phases.

**Decision** (2026-10-21, the owner's choice): inside the container the
agents may use the shell; the phases that only read (analyze, review) get it
without Edit or Write. This is Anthropic's devcontainer pattern — Claude Code
with permissions open because a firewalled container is the boundary — and
here the boundary is stronger: the firewall reaches only the proxy, the proxy
admits only the provider's endpoints and reads from the registries, and the
judge applies nothing outside the phase's writes, nothing in the protected
set, nothing holding a credential. The profiles were defence in depth; a
per-command allow list broke Spec Kit's own agents on every version and
prompt, and kept the implementer from running tests other than the check
command. The pass also gives each agent `SPECIFY_FEATURE_DIRECTORY`, which
contracts/pass.md promised and the agent had to invent; the entrypoint passes
it only as `/work/specs/<nnn>-<slug>`.

**Decision** (2026-10-21, the owner's review of the brief): both
implementers run Spec Kit's own implement command through Spec Kit's native
integration for their agent — Claude's skill `/speckit-implement`, and pi's
prompt `/speckit.implement` from `specify integration install pi`, committed
in `.pi/prompts/` — so the procedure is Spec Kit's, in one place, for both.
The run's brief is cut to what the contained run changes (where the agent is,
that the run marks tasks and writes outcome files, what stops the pass, the
fix round) and goes to each agent's system prompt with
`--append-system-prompt`, which Claude Code and pi both take (seen in the
worker); the user prompt is the command alone. `.pi/` joins the protected set,
as `.claude/` is: both instruct a later agent. `sdd-run` refuses a run opted in
to DeepSeek whose pi integration is not committed.

**Observed** (the real run, 2026-10-21, after the shell opened): plan,
checklist and analyze ran, then tasks and three build rounds, and the run
stopped, correctly, at converge_stuck — but two faults of the workflow showed.
analyze ran before tasks and found nothing to analyze (Spec Kit's analyze
compares spec, plan and tasks). And each Sonnet implement pass changed nothing
in about 14 seconds: Spec Kit's implement **STOP**s to ask whether to proceed
when checklist items are unchecked (31 were), and in `-p` mode nobody answers;
the pass counted "no change" as success, and nothing kept what the agent said.
**Decision**: Spec Kit's order, with the owner's process from the global
instructions: plan, checklist, a fresh review of each checklist marking what it
verifies (`checklist-review`), tasks, analyze, then the plan checkpoint, which
shows the unchecked items and whose approval answers implement's question —
the owner's to answer — as the brief tells the implementer. A change-less
implement pass fails where it cannot be progress (the run's first
implementation, a fix round), showing what the agent said; every agent's answer
is kept in the bundle's `results/`.

**Review of US1** (2026-10-21), the pass's side, each a check seen red: the
implementer may not mark tasks — Spec Kit's implement tells it to, the brief
says not to, and the judge decides: checkbox changes in `tasks.md` go back to
the baseline's, named, and the rest of the patch goes on (refusing a whole
legitimate pass over a tick would cost more than it protects), so a tick never
skips `mark`'s conditions and a tick-only pass is no change; pi's usage is the
sum over every assistant message, each carrying its own (pi 1.3.0
docs/json.md); the review reads the feature's own commits as a patch series,
not the repository since the feature began, which let unrelated work in;
dropped ignored paths are recorded in `implement.json`, and only the
repository's ignore rules count (git read the owner's `~/.config/git/ignore`
even with no global config); every pass keeps its answer, raw output
included when there is no result. Outside specify the pass sets
`SPECIFY_FEATURE_NO_PERSIST=1`, Spec Kit's own switch for orchestrators
(issue #4128), so its scripts no longer rewrite `feature.json`; the export's
copy of it and the comparison by meaning are gone with the rewrite.

**Alternatives**: the brief and pi's models inside the image — every edit
would rebuild it and they would not be frozen per run; git in the image — a
push client with no use; build-essential — only projects with native
extensions lacking wheels need it; a trigger to revisit. A Spec Kit preset
for the brief — a preset changes the implement command for every use in the
repository, interactive sessions included, while the brief's statements hold
only inside the contained run; making them conditional would be a hack. The
brief in the user prompt — it mixes the run's context into the task and
restated Spec Kit's procedure; the system prompt is where a harness puts the
environment. pi reading Claude's skill file — a second copy of the procedure
in another agent's format, when Spec Kit ships pi's own.

## R28 — A run's code and governance, frozen with it

**Finding** (the US1 review, 2026-10-21): the routing table, profiles, brief and
prices were frozen per run, but not the code that runs them: the outcome
schemas, `sdd-step` and `sdd-pass` were read from `~/dotfiles` at every step,
and the proxy, which holds the credentials, was copied from it at every start;
a branch switch or an edit there mid-run changed a run in progress. `resume`
also refused unless the installed workflow matched dotfiles' — while the
engine resumes from its own per-run copy.

**Decision**: `sdd-run start` copies the code a run executes into the bundle's
`code/`, in dotfiles' layout (`bin/`, `claude/speckit/schemas/`,
`claude/config-guard.sh`, `containers/worker/`), and points `tools.json`'s
`sdd-step` there; `sdd-step` and `sdd-pass` resolve their root from their own
path, which is then the bundle's, so nothing in either needed to change.
`resume` reads gates from the run's own workflow copy and checks only what the
moment needs (Spec Kit's version, the runtime, the token). One run at a time
per worktree — Spec Kit's feature pointer is the worktree's — and a run
belongs to its worktree; `start --from` sets the pointer to the feature it
names, and a resume refuses a pointer moved since.

**Alternatives**: a version check of the live code against the bundle's —
it would only refuse, not keep the run running; reading the feature from the
bundle in every step instead of Spec Kit's pointer — Spec Kit's own scripts,
inside the agents, read the pointer, so both must agree anyway.

**Second round** (the US1 review, 2026-10-22). *Finding*: `report()` pinned
whatever `.specify/feature.json` named at its first call; in a worktree a
feature had run in before, a specify that failed before writing the pointer
pinned the old feature, wrote the run's `routing.json` into it, and the
resume after specify refused the run's own feature (reproduced on check 95's
stand-ins and on the real engine, check 96). *Decision*: the bundle's
`feature.json` has two writers — `start --from`, and the specify pass, which
writes it beside the pointer once its change is applied (Spec Kit's
`create-new-feature.sh` writes the pointer only when it makes a feature; the
pass is the one place that makes it in a run) — and `sdd-run` only reads it:
`routing.json` goes into that feature, and a dead run's advice names it.
`start` also refuses while another run's process is alive, whatever Spec Kit
holds for it. *Rejected*: pinning at `report()` a pointer that differs from
the one `start` found — it infers who moved the pointer instead of being told
by the one writer, and would pin a pointer moved by hand while the run paused
before specify.

*Recorded, not fixed* (LOW, same review):
- `pin_feature` runs before `write_bundle`, `cleanup` and `prepare-worker`,
  so a failure there leaves the pointer moved to `--from`'s feature with no
  run to show for it; harmless to Spec Kit, which reads it as a switch of
  feature, but not undone.
- Ticks are taken back only for implement passes (`sdd-pass.py`
  `take_back_ticks`), while the `tasks` and `converge` rows also write
  `tasks.md` (`routing.yml`): an agent there could tick a task the review has
  not found done. Not fixed: the review's own `done` list is what marks tasks
  at `review_done`, and those rows author the task list itself.
- Unsettled: a repository whose committed `.specify/scripts` predate
  `SPECIFY_FEATURE_NO_PERSIST` (#4128) would have its scripts rewrite the
  pointer in every non-specify pass, which the pass then refuses as a write
  outside its row; only the host CLI's version (≥ 1.2.2) is checked, not the
  scripts the repository carries. Not tested.

**Third round** (the review of 8ca7458, 2026-10-22). *Finding* (MEDIUM): the
dead-run advice split on whether the bundle pinned a feature, but `start
--from` needs a phase recorded done in `.sdd/phases.json`; a run that died
between specify's apply and `specify_done` was sent to a `start --from` that
refuses (reproduced on check 95's stand-ins, dying in `clarify_ask`).
*Decision*: the advice splits on whether any phase is done
(`from_inputs_left`, the test `start --from` itself applies); with none, start
anew, naming the feature directory specify left behind so the owner removes
it before the new start numbers its feature beside it. Check 95, N4.

*Recorded, not fixed* (same review):
- Runs started before 8ca7458 resume on their own frozen `sdd-pass`, which
  never writes the bundle's `feature.json`: they get no `routing.json` in
  their feature, no moved-pointer refusal, and a dead one is told to start
  anew even with phases done. Transitional: it ends with those runs.
- The usage end line was withheld on its JSON-escaped form (`sdd-pass.py`
  `run_agent`, `run.withhold(..., json.dumps(...))`), so a credential holding
  a character `json.dumps` escapes (`"`, `\`, a control or non-ASCII one)
  would not be replaced there; the line is written before the judge, and the
  judge's `scan` did not cover it either, since it too read `structured` and
  the usage as `json.dumps(...)` (read in the code at 052c94b). *Fixed*
  after 2a57cd6 (2026-10-22): `Run.withhold` takes a decoded JSON value too
  and replaces within its strings, keys included, before the usage line is
  serialised, and `Pass.scan` matches the raw value in every decoded string
  of the result's text, `structured_output` and usage (`strings()` in
  `sdd-pass.py`). Check 91, `sdd_no_leak_escaped`: a sentinel holding a
  quote, a backslash and U+00E9, returned only in `structured_output`, only in
  the usage (as a model's name, as a field's value) or in the result's text.
  Red before the fix: the review in `structured_output` succeeded and wrote
  the value into `review.json`; both usage cases succeeded and left it,
  escaped, in `usage.jsonl` and `implement.json`; the result-text case was
  already refused (the text was scanned raw). Seen red again with each half
  of the fix reverted by hand.

## R29 — What an agent said, withheld of every credential before it is kept

**Finding** (US2's leak check, T044, 2026-10-22, against stand-ins): the judge
scanned an agent's files, result text and `structured_output`, but what the
run keeps or prints of an agent was never scanned: the answer in `results/`
(written whatever happened, so the owner can read why), the usage line in
`usage.jsonl` (written before the judge, so a failed attempt still counts),
and the messages of a failing pass, which quote the agent — an `is_error`
result, a denied command, its stderr. A sentinel credential in a result's text
was refused as a patch and then kept in `results/`; one in an error result was
printed.

**Decision**: every sink of agent text — the `results/` answer, the usage line,
the failing pass's message — goes through one function that replaces the exact
value of every credential of the run with its Keychain item's name, reading
them as the scanner does and failing closed: an answer that cannot be scanned
is withheld whole. The usage reported by an agent is also scanned by the
judge, since `implement.json` records it.

**Alternatives**: scanning once, early, in the result's parser — the error
paths raise before any scan, and each sink added later would have to remember
it; dropping a pass's answer whenever it holds a credential — loses the one
record of why the pass failed, which is what `results/` is for (R27);
refusing the pass alone — the refusal was already there, and the leak was in
what the run kept after refusing.

## R30 — Claude's usage, held to the contract pi is held to

**Finding** (2026-10-22, reading `sdd-pass.py` at 2a57cd6 against
contracts/sdd-step.md, implement step 3): the contract fails a pass whose
response names another model or lacks a usage field, for either implementer,
but only pi's parser enforced it; Claude's defaulted `total_cost_usd` to 0
and `modelUsage` to `{}`, so a Claude pass reporting no usage was counted
free — the defect US2 closed for pi — and its model was taken from the row,
never from what served.

**Observed** (2026-10-22): `claude -p --output-format json --model
claude-sonnet-5-5 "Reply with the single word ok."` returns
`total_cost_usd` (0.1066 in the owner's run, 0.0989 in a second run the same
day) and `modelUsage` keyed by model id:
`{"claude-sonnet-5-5": {"inputTokens", "outputTokens", "cacheReadInputTokens",
"cacheCreationInputTokens", "costUSD", ...}}`, the configured model alone in
both runs.

**Decision**: a Claude result lacking a numeric `total_cost_usd` or a
non-empty `modelUsage` object fails the pass, nothing applied. `modelUsage`
must hold the row's configured model with its tokens (`inputTokens` and
`outputTokens` integers); otherwise the pass fails naming the models that
reported tokens. Other models beside it — Claude Code may use an auxiliary
model for its own background work — are no refusal: implement.json's usage
and the usage.jsonl end line keep the whole `modelUsage`, and the model
recorded is the configured one, which served. The end line is written before
the refusal, as pi's is, so a refused attempt still counts. Contracts are
silent on judgment passes; they share the parser, so the rule holds for
every Claude pass (one parser, one rule), and contracts/pass.md step 8 now
says so. Check 91, `sdd_claude_usage`.

**Alternatives**: requiring `modelUsage` to hold only the configured model —
it would refuse legitimate runs where Claude Code reports an auxiliary model;
narrowing the contract to pi — a Claude pass reporting no usage would be
counted free, the defect US2 closed for pi.

## R31 — A provider's refusal, in the proxy's words

**Finding** (T047, attempt 6, 2026-10-22, docs/sdd-routing.md): DeepSeek
answered the sentinel key with 401 "Your api key: \*\*\*\*d5be is invalid",
the key's last four characters, and the proxy relayed the provider's answer
verbatim, body and headers. With the real key, part of it would reach the
agent. The judge and the withholding (R29) look for the exact value only.

**Decision** (superseded by R33: the rewrite became an allow-list of 2xx, the
block-list of statuses having been found too narrow): when a provider whose
credential the proxy injects (Anthropic, DeepSeek) answers 401 or 403, the proxy relays the status with a JSON body of
its own, `{"error": {"type": "provider_refused_credential", "status",
"message"}}`, naming the status and that the provider refused the run's
credential, and none of the provider's body or headers (`WWW-Authenticate`
and any other: none of them is needed to read a refusal, and any could
describe the key). It logs the refusal with its status, host and path,
never the body. Every other status passes through as before. Check 93,
`ep_refusal`, against a stand-in provider whose 401 and 403 quote the
injected credential's tail in the body and two headers; seen red on the
relay before the change, and again with the branch disabled by hand.

**Alternatives**: scanning for key fragments in the judge — four characters
match by chance in ordinary text, and by the time the judge reads the
agent's output the fragment has already reached the agent, which could
have sent it anywhere the pass may reach; dropping only the provider's
`WWW-Authenticate` header and rewriting the body — the next provider's
header or wording would need its own rule, where relaying nothing of a
refusal needs none.

## R32 — The stand-in proxy lives as the real one, not for a fixed time

**Finding** (2026-10-22): one full `./check.sh`, with three suites running
in parallel on this laptop, failed check 96 `e2e` with "sdd-step: the bundle
has no proxy-ca.pem: the run's egress proxy is not running" at
`fix_loop:verify:2`; it passed alone and in later runs. The hypothesis
handed over — the real proxy exits when its heartbeat file stops changing,
and under load the writer stalls past the timeout — does not hold for this
check: the writer is sdd-run's main loop (`beat()` every 2 seconds,
`HEARTBEAT_SECONDS`), the timeout is 60 seconds (`heartbeat_seconds` in
`sdd-pass.py`'s start line), a 30-period margin, but check 96 never runs
`sdd-egress-proxy.py` at all: the stand-in runtime
(`checks/sdd/standins/container`) answers a run naming it with a fake proxy
that printed its ready line and then ran `sleep 300`, ignoring the
heartbeat. When that sleep ends, `sdd-step egress-proxy`'s wait returns and
its `finally` removes `proxy-ca.pem` and `proxy.json` while the run goes on;
the next pass fails with this message. Reproduced without load (the scratch
runner ran check 96's `e2e` alone with the stand-in's `sleep 300` rewritten
to a shorter one): with 3 seconds, "failed at fix_loop:verify:1" with this
message; with 4, at `fix_loop:implement:2`; with 5, and with 300, it passed
(the third `sdd-run` call, the one that failed, took 7 seconds unloaded).
What was not reproduced is the load itself: the flake needs that call to
take more than 300 seconds, about 40 times its unloaded time, and nothing
else in check 96 removes the file (the only writers of `proxy-ca.pem` are
`start_proxy`'s leftover removal and `egress_proxy`'s `finally`, and no
`container stop` names the proxy in that check), so the fixed lifetime is
the cause by elimination, the load that crossed it observed only once.

**Decision**: the stand-in's fake proxy keeps the real proxy's lifetime: it
runs until stopped, or until `admissions/heartbeat` (resolved through the
`-v` mount, as the stand-in resolves `/work`) has not changed for the start
line's `heartbeat_seconds`. A live run's stand-in proxy then cannot die of
elapsed time, and one an interrupted check abandoned still exits once its
heartbeat stops or its scratch directory is gone. Check 91's own proxy
cases, where no sdd-run beats, touch the heartbeat while their proxy runs.
Check 91, `sdd_standin_proxy_lifetime`: red on the `sleep 300` stand-in
("still running four seconds after its last heartbeat"), and red with the
heartbeat loop replaced by a 3-second sleep by hand ("exited although its
heartbeat changed").

**Alternatives**: a longer sleep (an hour) — still a fixed lifetime a slow
enough machine crosses, and an interrupted check leaves a process behind for
the hour; running until stopped, with no bound — an interrupted check leaves
it forever, since `sdd-step egress-proxy` runs in a session of its own and
outlives a killed sdd-run; changing the real proxy's heartbeat (liveness
from the run's process, or a wider window) — the real proxy was not the
cause, and its margin is 30 writer periods. A stall of the writer alone
does end the real proxy while the run lives — sdd-run stopped by a signal
while its passes go on — which is what the heartbeat is for when sdd-run is
killed; not changed here, and not a cause of this failure.

## R25 — Read-only registries: TLS inspection at the egress proxy

**Finding** (owner's review of R23, 2026-10-21): with `CONNECT` tunnels to the
registries, a pass could publish (`npm publish`, a `PUT`) or push (`git push`,
a `POST` to `git-receive-pack`) the repository to an account it names, the one
smuggling channel whose sink an attacker can read.

**Spike** (2026-10-21, throwaway, in the worker image on Apple `container`): a
proxy made a certificate authority with `openssl` in its own container, signed
one certificate per registry host, terminated each `CONNECT` with the host's
certificate (ALPN `http/1.1`) and forwarded to the real host over verified
TLS. In the worker, with the authority added to the system store and
`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` pointing at
it: `npm install left-pad@1.3.0`, `uv pip install six==1.16.0` and `mise
install jq@1.7.1` (GitHub release, via `mise-versions.jdx.dev`) all worked; a
`PUT` to `registry.npmjs.org` was refused with 403. npm also sent `POST
/-/npm/v1/security/advisories/bulk` (its audit); the image has no `git`.

**Decision** (FR-031): the proxy terminates TLS for the registry hosts with
an authority made at its start, whose key stays in its container; its
certificate reaches the worker through the bundle and the entrypoint installs
it; only `GET` and `HEAD` are forwarded, on `github.com` only
`/<owner>/<repo>/releases/download/…` and `/<owner>/<repo>/archive/…`; npm's
audit is turned off in the worker, so no read needs another method.

**Observed** (T062, 2026-10-21, the built proxy and the pinned worker
`sdd-worker:a1a9cc8aef8b`, a real run): a Claude pass as before (two `POST
/v1/messages`, 200); a verify pass whose check command installed `left-pad`
with npm, `six` with uv and `jq` with mise, all through the inspected
registries; in the same pass a `PUT` to `registry.npmjs.org`, a `POST` to
`github.com/…/git-receive-pack` and a `GET` of a GitHub page that is not a
release download were refused with 403 and logged; `npm publish` of a name
nobody owns reached its `PUT` and failed `E403`, refused by the proxy. A client
closing TLS without its close-notify left one log line (`SSLEOFError`).

**Review of Phase 2b** (2026-10-21), each finding now a check seen red: the
path rule held on the raw target, so a query (`/o/r?/archive/`) passed it —
it now holds on the path alone, refusing dot segments and encoded dots or
slashes; the agent's headers rode its reads, User-Agent among them, which
PyPI publishes per download — only the headers a download needs go on, with
the proxy's own User-Agent; a token retired while its tunnel was open still
read — the admission is read on every request; archive downloads redirect
to `codeload.github.com`, which was not listed — it is, archives only; the
authority now carries critical name constraints to the registries' names.
Run again for real after those fixes: the name-constrained authority was
accepted by npm, uv, mise and curl in the worker, an archive came through
codeload, and the query bypass was refused. The leaves' validity starts at
the proxy's clock; each run's proxy is new, and Apple's VMs take the host's
clock, so no skew was seen.

**Alternatives**: mitmproxy or Squid's ssl-bump — a new dependency where the
standard library and the image's `openssl` suffice; an allowlist by SNI alone
— it cannot see the method, so publishing stays open; installing dependencies
in a step without an agent and running every agent offline — an implementer
could no longer add a dependency the tasks need; registry mirrors (Verdaccio,
devpi) — a service per ecosystem to run and keep current.

## R26 — A worker image reproducible in its packages

**Finding** (owner's review of R23, 2026-10-21): apt packages and npm's
transitive dependencies were unpinned, so a rebuild could differ.

**Observed** (2026-10-21): two `container build --no-cache` runs of one
three-line recipe, `SOURCE_DATE_EPOCH` set, gave different image digests;
`--output` takes only `type` and `dest`, and an unknown `rewrite-timestamp`
option left the build hung. Bit-identical images are out of reach with this
builder.

**Decision** (FR-032): every input pinned by hash — the base by digest, apt
from `snapshot.debian.org` at a fixed date with exact versions, npm from
`containers/worker/package-lock.json` with `npm ci` (integrity hashes), mise
and uv by checksum — and an inventory of every installed Debian and npm
package with its version, committed beside the recipe; `prepare-worker`
reads the built image's inventory and refuses any difference. drift.sh reports
the snapshot's age and the pins behind upstream, so the pins move on purpose.

**Observed** (T060, T061, 2026-10-21): on the base the tag pointed at that
evening (`55fb5f5a…`, the second move that day, caught by drift.sh), two
`container build --no-cache` runs gave different digests (`0c4a5099…`,
`b17ddf10…`) and the same 254-line inventory: 131 Debian packages, 120 npm
packages (the lockfile's, filtered to linux/arm64/glibc, exactly), node
24.22.1, mise 2026.10.17, uv 0.13.4. The base's snapshot did not move with
its digest (`20261020T213255Z` both times), nor did the five pinned Debian
versions. `prepare-worker` built the recipe, accepted it, and refused a
planted difference naming the package. A check compares the lockfile with
the inventory, so a Dependabot PR that moves only the lockfile fails in CI
until the inventory is regenerated.

**Observed** (2026-10-21): `container build -q` hung with no output for
half an hour (twice: here and in the reproducibility spike), while the same
build without `-q` finished in under ninety seconds with no cache;
`prepare-worker` never passes `-q`.

**Alternatives**: Nix or apko/melange — reproducible bits, at the price of a
second build toolchain beside the one the machine already runs; Docker with
BuildKit's `rewrite-timestamp` — Docker Desktop is installed but undeclared
here, and Apple `container` was chosen (R5); recording only the image digest
— a rebuild would always differ and the check would say nothing.

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

## R33 — The fresh review of US2 (T048)

**Findings** (2026-10-22, a review in a fresh context; each fixed test first,
seen red for the predicted reason, then the fix, then the fix broken by hand
and seen red again):

1. pi's missing-usage guard was unguarded by a check (`if False:` kept the
   case green: the traceback it left satisfied "exit 1 and the word usage"),
   and `usage: {}` was accepted as zero tokens, a null or text count raised an
   uncaught TypeError. pi's usage is now an integer `input` and `output` (and
   an integer `cacheRead` when present), else a clean PassFailed.
2. The proxy's 401/403 rewrite (R31) was a block-list; see the decision below.
3. Withholding ran after truncation (the stderr tail, the error result, a
   denied request's input), so a credential across the cut stopped matching and
   a fragment printed. Withhold first, cut after. The tail of the schema
   validator's message in `stage_outcome` is not changed: it can only echo what
   the scan has already passed, since the scan runs on the structured output
   before the outcome is staged, so no credential can be in it.
4. Changed file names were not scanned, and the judge's messages, which name
   paths, were not withheld. Names are scanned like content; judge, scan and
   the non-regular-file message are withheld.
5. A Claude result line that is not an object (`[]`, `"x"`, `null`) raised
   AttributeError; it is now "the agent returned no JSON object result".

**Decision for 2**: an allow-list. A 2xx is relayed unchanged, streaming as
before. Every other status keeps its code and gets the proxy's own JSON body,
`{"error": {"type", "status", "message"}}`, `type` being `provider_refused`
(401, 403), `provider_rate_limited` (429) or `provider_error`, and a message
that says only that the provider answered that status and its own message is
not relayed: it does not claim a refused credential, since a WAF's 403 or a
model-not-allowed 403 is not one (the review's LOW finding 6). Headers are
those of the proxy's own body and a `Retry-After` that is a plain number of
seconds, so retries on 429 and 529 keep working; no `Location`, `Set-Cookie`,
`WWW-Authenticate` or request id. The log line has status, provider, host and
path. What is lost: the provider's own error text, kept out on purpose; the
owner reads the status and the proxy's log. Check 93 `ep_refusal`, against a
stand-in quoting the credential's tail in the body and in several headers, covers
400, 401, 402, 403, 407, 429, 500, 503 and a 302 with a Location, and a 200
unchanged; red before the change, and red again with the allow-list put back
to the block-list, with `Retry-After` relayed unchecked and with it dropped.

**Alternatives**: keeping the block-list and extending it to the statuses seen
— the next status or header would need its own rule, where relaying nothing of
a non-2xx needs none; relaying a status class (4xx) — a 400 or 402 body can
quote a key as well as a 401; relaying a `Retry-After` verbatim — it is
provider text like any header, so only a number is let through.
