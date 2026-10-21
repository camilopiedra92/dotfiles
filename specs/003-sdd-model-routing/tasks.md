# Tasks: Model routing per Spec Kit phase

**Input**: Design documents from `specs/003-sdd-model-routing/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: requested. Every story here has logic of its own (constitution III,
global instructions), so each story's test tasks come first, run once before
the code exists, and each must fail for the reason its case predicts (a missing
script is stubbed so the failure is the behaviour's, not collection's). Every
check in `checks/91-sdd-routing.sh` is seen red with its behaviour broken by
hand before it is trusted (SC-006).

**Organization**: Phase 1 settles every "Pending" in research.md on this
machine; one that comes out against the design stops the work and goes to the
owner (plan.md, "Phase order"). Phase 2 builds what every path needs — the
schemas, the worker container and the contained pass (contracts/pass.md) —
because every agent step and every verify run through it (research R21). Then
one phase per user story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1, US2, US3 from spec.md

---

## Phase 1: Setup — settle the pending observations

**Purpose**: observe on this machine what the design rests on. Each task records its result, with date and command, in research.md under the entry it settles. Before T003, the owner creates the Claude token (`claude setup-token`) and stores it as the Keychain item `claude-oauth`.

- [ ] T001 Declare `check-jsonschema` with a pinned reference in `uv-tools.txt` and the container runtime T002 settles on in the `Brewfile` (owner-approved 2026-10-21); install each with the command `install.sh` runs for it; confirm `./drift.sh` is clean for both
- [ ] T002 Probe the container runtime (research R5): under Apple `container` — the macOS version it requires, what its first start leaves on the machine, a throwaway run with one scratch directory mounted, and whether it grants `NET_ADMIN`/`NET_RAW` so Anthropic's reference `init-firewall.sh` runs and blocks a host outside its list while reaching one inside; if it cannot, the same probe under colima with the Docker CLI. Record which runtime passed and why in research R5; if its first start leaves state, add its apply step to `install.sh` and its report to `drift.sh` here (constitution IV). If neither passes, stop and take it to the owner
- [ ] T003 Probe Claude Code inside a throwaway container of that runtime, behind the firewall, with no credential in it: `ANTHROPIC_BASE_URL` points at a throwaway plain-HTTP gateway on the host that replaces a placeholder `CLAUDE_CODE_OAUTH_TOKEN` with the real token from the Keychain (research R4, R10, R14, R16, R21, R23): a `-p` call authenticates on the owner's subscription through it; `--setting-sources ""` is accepted and a tracked `.claude/settings.json` in the export adds nothing to the profile; `--effort` given against the level the result reports; `--json-schema` returning `structured_output`; a `dontAsk` denial's `permission_denials` and exit status; `--strict-mcp-config` with no server and the context it saves; that a project skill (`/speckit-plan`) and the project's CLAUDE.md with its constitution import load from a `git archive` export with no `.git`; that two consecutive Opus calls with the `author` then the `reader` profile read their shared prefix from the cache. Record in those entries; if the token cannot be used this way, stop and take it to the owner
- [ ] T004 [P] Probe Spec Kit 1.2.2 (research R3, R11, R12, R21): a gate's `retry` and `abort` inside a `do-while`; that a failed then resumed step's earlier attempt is still in `state.json` or `log.jsonl`; what `state.json` holds after the run's process is killed mid-step; that `create-new-feature.sh`, `setup-plan.sh` and `check-prerequisites.sh` work in an export with no `.git` when `SPECIFY_FEATURE_DIRECTORY` is set. Record in those entries
- [ ] T005 [P] Probe `claude/config-guard.sh` (research R7, R21): its verdict on a `Write` with empty content to `ruff.toml` and on a `pyproject.toml` that loses `[tool.ruff]`; and that, run by absolute interpreter path with the working directory in a directory holding an untrusted `mise.toml`, it still decides instead of failing open. Record in R7
- [ ] T006 Probe pi 1.3.0 in that runtime behind the firewall (research R5, R6, R17): the flags R17's spike used; that `deepseek-flash` answers through the `models.json` entry with its `baseUrl` at the throwaway gateway, which adds the key, while the container reaches nothing but the gateway; that `/models` still lists the ids R6 records; the `model` field a chat response reports (if it is the bare alias, record it as unpinned; if it is any other id, stop for the owner). Record in R6

**Checkpoint**: every "Pending" in research.md is observed. Commit research.md.

---

## Phase 2: Foundational — schemas, the worker and the contained pass

**Purpose**: what every story stands on: the schemas, the CI that runs the checks, the worker image and the contained pass every agent step and verify run through.

- [ ] T007 Install `uv` in `.github/workflows/ci.yml` the way the other CI tools are installed — a pinned version, its checksum in `.github/tool-checksums.txt`, moved by `bump-tools.sh` — then `uv tool install` the `uv-tools.txt` entries `specify-cli` and `check-jsonschema` at their pins; extend "installed tools match the ci.yml pins" to `uv`, extend `checks/20-tool-versions.sh`'s `bump_tools` check with a `uv` entry and see it red, add `uv` to ci.yml's step that asserts the tools are the pinned versions; see a CI run green before relying on any check below
- [ ] T008 Create `checks/91-sdd-routing.sh` with its section header and the stand-ins its checks share: a scratch repository set up with `specify init --here --force --integration claude` on a temporary `HOME`; a stand-in container runtime that runs the mounted command in a scratch directory standing for the container and records its mounts, capabilities, user, network list and stdin; stand-ins for `claude` and `pi` that record every argument and return a canned JSON result whose `structured_output` and file edits come from a fixture directory; a stand-in `security`. The real Spec Kit 1.2.2 engine runs the workflow (FR-025); nothing reaches the network or the real Keychain
- [ ] T009 Test first, in `checks/91-sdd-routing.sh`: every schema in `claude/speckit/schemas/` — `routing-table`, `routing-layer`, `route`, `routing`, `phases`, `clarify`, `implement`, `verify`, `review`, `converge` — accepts its valid sample and refuses a missing field, an extra field and a wrong enum value (`check-jsonschema`); `sdd-step outcome <step>` prints each step's token from a valid file and exits non-zero on a missing or invalid one (FR-016); run it red against empty schemas (`{}`) and a stub `bin/sdd-step.sh` that exits 0
- [ ] T010 [P] Write the schemas in `claude/speckit/schemas/` with the common fields `schema`, `step`, `at` and the fields of data-model.md "Outcome files", quoted there (`severity: CRITICAL/HIGH/MEDIUM/LOW`, `questions: integer 0–5`, `outcome: converged/tasks_appended`, `agent: deepseek/sonnet`, `additionalProperties: false`); `routing-layer.schema.json` allows only `model`, `effort` and `timeout` per phase (contracts/routing.md)
- [ ] T011 Implement `sdd-step outcome` in `bin/sdd-step.sh` (contracts/sdd-step.md): validate with `check-jsonschema`; print `yes/no`, `pass/fail`, `blocking/clear`, `converged/open` as data-model.md defines them, `converged` only when `outcome` is `converged` and no finding is above LOW; T009 green
- [ ] T012 [P] Test first: the contained pass (contracts/pass.md, FR-028, research R20, R21) against the stand-in runtime — the export comes from `git archive` with tracked files only and no `.git`; the baseline export stays untouched; the patch is computed by the system `git` by absolute path, with `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, a fixed `PATH` and the working directory in the bundle, so a `mise.toml`, `.envrc`, `.gitattributes` or `.git` file planted in the export is never read on the host; a path outside the row's `writes` stops the pass naming it; for an implement row, a path in the protected set stops it, and an `ask` from the bundle's `config-guard.sh` stops it; a judge that fails to run fails the pass; the patch is applied with hooks and fsmonitor off and committed once; at the row's `timeout` the container is stopped and nothing applied; both exports and the container are removed whatever happened; the credential reaches the container only on stdin; verify runs the frozen check command in the container, admitted by the proxy to the registries only, with its own cache volume, never the implementer's, and no patch; every host git command — the pre-pass commit, apply, `mark` — runs with system and global configuration off, `hooksPath=/dev/null` and fsmonitor off, so a planted `githooks/pre-commit` (dotfiles' own `core.hooksPath`) never runs; a symlink, a submodule or a mode other than 644/755 in the patch stops the pass; a patch, result or `structured_output` holding a credential's exact value stops the pass naming the credential, not showing it; a judgment pass reaches only its provider's host, an implement pass its provider and the registries, verify the registries; every host step starts in the bundle with a fixed `PATH`, so a `mise.toml` or `.tool-versions` in a worktree changes nothing
- [ ] T013 [P] Test first: `containers/worker/init-firewall.sh` and `entrypoint.sh` against stand-ins for `iptables`, `ipset`, `dig`/`getent` and `gosu` that record their calls (constitution III) — the OUTPUT policy is DROP before any allow rule; only the proxy's address and loopback are allowed; a REJECT ends the chain; the firewall allows the egress proxy's address and nothing else, DNS included; the entrypoint runs it before anything else and starts the agent as `node`; no credential is in its environment or arguments
- [ ] T014 [P] Test first: `bin/sdd-egress-proxy.py` against a local stand-in upstream (contracts/pass.md "The egress proxy", FR-007, FR-009, research R23) — a request bound for a provider's API reaches it with the placeholder replaced by the credential fed at start, and the credential appears in no log or response; a pass admitted to its provider only is refused the registries and the other provider; verify is admitted to the registries only; `CONNECT` to any other host is refused and logged; the credential is read once through a pipe and never written; run red against a stub
- [ ] T015 Run T012–T014 once against stubs; confirm each fails for the reason its case predicts
- [ ] T016 Write `containers/worker/`: `Containerfile` (Node base pinned by digest, `iptables`, `ipset`, `@earendil-works/pi-coding-agent@1.3.0`, the Claude Code CLI at a pinned version, mise, uv, a non-root `node` user), `init-firewall.sh` (adapted from Anthropic's reference, its source and date in a comment beside it, research R6), `entrypoint.sh`, `egress-registries.txt` (the registries research R5 names) and `models.json` (the ids `/models` returned in T006 and their per-token prices from DeepSeek's pricing page, with the date read); T013 green
- [ ] T017 Implement the contained pass in `bin/sdd-step.sh` (contracts/pass.md), with `prepare-worker` and `cleanup` (contracts/sdd-step.md); T012 green
- [ ] T018 Implement `bin/sdd-egress-proxy.py` (Python standard library, run by `/usr/bin/python3`) and `sdd-step egress-proxy`; its test green
- [ ] T019 Add to `drift.sh` a report of the worker image's pins against upstream — pi's and the Claude Code CLI's latest versions and the Node base's current digest — as it reports `uv-tools.txt` pins behind upstream (constitution V), with its check in `checks/` seen red
- [ ] T020 Close Phase 2: `./check.sh` green; each new check seen red with its behaviour broken by hand; a fresh-context review of the phase's diff, its findings fixed or recorded with the reason

**Checkpoint**: an agent can run in the worker, and nothing it writes reaches the repository unjudged.

---

## Phase 3: User Story 1 — each phase on its own model (Priority: P1) 🎯 MVP

**Goal**: a feature runs from one command through every phase on its routed model and effort, with checkpoints, outcome files and, while not opted in, implementation by Sonnet — every agent step a contained pass.

**Independent test**: quickstart.md 1–10 against the stand-ins, with the repository not opted in.

### Tests for User Story 1 (first, each run red before its code exists)

- [ ] T021 [P] [US1] Check routing and dispatch (quickstart 1, FR-001, FR-002, FR-019, FR-021, FR-025, FR-026): every agent step runs `sdd-step agent <phase>`, a contained pass whose `claude` call carries its effective row's `--model` (Opus for specify, clarify, plan, checklist, analyze, review and converge; Sonnet for tasks) and `--effort`, its profile, `--permission-mode dontAsk`, `--permission-prompts none`, `--strict-mcp-config` with no server, `--output-format json`, and `--json-schema` where the row has one; no call carries `--resume` or `--continue`; each judgment step's patch is limited to its row's `writes` (plan writing outside the feature directory, specify creating a second directory, or a `.specify/feature.json` naming another directory, is refused); verify makes no `claude` call; same-model steps run adjacent; `structured_output` lands in the row's outcome file and analyze's text in `analysis.md`; each attempt has a start and an end line with the run id in `usage.jsonl`; a `permission_denials` entry fails the step naming the tool; review's prompt makes a deleted or weakened test blocking and reads the run's diff from `/input/diff.patch`; every agent step's workflow `timeout` equals its row's `max_timeout` plus 300 (implement 3900); the engine's run id equals `SPECKIT_WORKFLOW_RUN_ID`
- [ ] T022 [P] [US1] Check checkpoints (quickstart 2, FR-004): without a TTY the run pauses at each gate and prints the `sdd-run resume` command; `approve` continues and `reject` aborts, for every gate in contracts/workflow.md
- [ ] T023 [P] [US1] Check clarify through a file (quickstart 3, FR-005): two canned questions pause the run at `answer-clarify` and `clarify-apply` runs after approval; zero questions skip the gate
- [ ] T024 [P] [US1] Check loops and retries (quickstart 5, FR-014, FR-015, FR-017): a check command that always fails gives three implement passes then `fix-stuck`; `retry` gives exactly one more; on a fix round the brief names `.sdd/verify.json`; a converge that never converges gives three passes then `converge-stuck`
- [ ] T025 [P] [US1] Check marking (quickstart 6, FR-006): `sdd-step mark` refuses on `verify` = fail or `review` = blocking, and marks only the task ids `review.json` lists
- [ ] T026 [P] [US1] Check `prepare-worker` and verify (FR-028): the image is built by the workflow's first step, before `specify`; a missing image fails a pass rather than build inside its limit; verify runs in the container with the registries only, never on the host
- [ ] T027 [P] [US1] Check `sdd-run` prerequisites (contracts/sdd-run.md, FR-011, FR-021, FR-024, US1 AS7): each missing one stops with exit 1 naming it — Spec Kit older than 1.2.2, no `.specify/`, the workflow missing or at an older version, no container runtime, no `claude-oauth` Keychain item, a host tool missing from the owner's `PATH`, `sdd.check` unset; `CLAUDE_CODE_EFFORT_LEVEL` is unset before any step; `.sdd/routing.json` records every effective value with its layer
- [ ] T028 [P] [US1] Check the Sonnet implementation pass (quickstart 7–8, FR-008, FR-018, FR-023, US2 AS6–7): a created, changed or deleted `ruff.toml`, a `pyproject.toml` without `[tool.ruff]`, or any path in the protected set, stops the pass with nothing applied; a judged patch is applied and committed as `implement: <feature> (claude-sonnet-5-5)`; a limit raised or lowered within `max_timeout` is honoured and one beyond 3600 refused; a crash leaves the feature's worktree unchanged; `implement.json` is written only by `sdd-step implement`, with the usage from the JSON result; a patch that changes the frozen check command's own script, or a file config-guard covers, is recorded as a check change; one that adds a git hook (the repository's `core.hooksPath` or `.husky/`), an editor task or an executable file is recorded as an automation change; verify carries both, check changes block until the owner approves `review-done`, and `review-done` lists both (FR-029, FR-030)
- [ ] T029 [P] [US1] Check interrupted runs (FR-022): a lock naming a dead process (process id and start time) makes `cleanup` remove that run's exports and containers and `resume` report the phases that will run again; `sdd-run start --from <feature dir>` passes `spec.md`, skips every phase in `.sdd/phases.json`, and is refused when none is finished; a run paused outside a gate resumes with no verdict and reruns the interrupted step; a reused process id is not taken for dead
- [ ] T030 [P] [US1] Check `sdd-step route` (contracts/sdd-step.md, FR-010, US3 AS3): it reads the opt-in frozen in the bundle; opted in writes `route.json` with `deepseek`; not opted in writes `sonnet` and prints the opt-in line naming DeepSeek's terms of service and privacy policy; an opt-in made after start does not change the route
- [ ] T031 [P] [US1] Check `sdd-run usage` (contracts/sdd-run.md, SC-001's counting): from two canned runs' `usage.jsonl` it reports only the named run; it sums every attempt per model at list price, failed and resumed ones included, lists attempts with a start and no end, or no usage, as unreported, prices pi's tokens from `models.json`, and prints the totals
- [ ] T032 [P] [US1] Check routing layers (FR-027, contracts/routing.md): a project file changes one field and keeps the rest of the row; a local file wins over the project file; `--set` wins over both for one run only and arrives typed (`timeout=900` an integer); a layer naming an unknown phase or field, setting `agent`, `profile`, `prompt`, `writes`, `schema`, `result_to` or `max_timeout`, a Claude id on a `pi` row or the reverse, or a `timeout` beyond `max_timeout`, stops `sdd-run` naming the layer, phase and field; the bundle (lock, opt-in, check command, table, profiles, config-guard) is written under `--git-common-dir` at start, exported as `SDD_RUN_DIR`, mounted read-only into every pass and reused by `resume`; `sdd-run routing` prints the effective table with each value's layer; `--init-local` creates the local file and excludes it through `--git-common-dir`
- [ ] T033 [US1] Run T021–T032 once against stubs of `bin/sdd-run.sh`, the story's `bin/sdd-step.sh` subcommands and `claude/speckit/sdd-routed.yml`; confirm each fails for the reason its case predicts; record the red run in the commit message

### Implementation for User Story 1

- [ ] T034 [P] [US1] Write `claude/speckit/routing.yml` with the rows of contracts/routing.md (model, effort, profile, prompt, writes, schema, result_to, timeout, max_timeout), and the profiles `claude/speckit/profiles/author.json`, `reader.json` and `implementer.json` (contracts/routing.md "Profiles": they differ in permission rules only, never in the tools offered)
- [ ] T035 [P] [US1] Write `containers/worker/brief.md`, the brief both implementing agents get (FR-017): the tasks not marked done, spec, plan and every other file `/speckit-plan` wrote, the constitution, the test-first rules, no change to a check's configuration, nothing outside the tasks; the agent writes no outcome file
- [ ] T036 [US1] Write `claude/speckit/sdd-routed.yml` per contracts/workflow.md: inputs with `enum` verdicts and `resume_from`, every agent step a `shell` step running `sdd-step agent <phase>` with `timeout:` its row's `max_timeout` plus 300, `prepare-worker` at 1800, `verify` at 3600, a `version` field; no model, effort or permission in the workflow
- [ ] T037 [US1] Implement the story's `bin/sdd-step.sh` subcommands on top of the contained pass: `agent` (contracts/routing.md), `route`, `verify`, `mark`, `phase-done`, and `implement` for the Sonnet path (contracts/sdd-step.md)
- [ ] T038 [US1] Implement `bin/sdd-run.sh`: `start` (with `--set`), `start --from`, `resume`, `routing` (with `--init-local`), `usage`; the prerequisites; the layered merge and its validation; the run bundle under `--git-common-dir` exported as `SDD_RUN_DIR`, with `tools.json` (absolute host tool paths resolved once); starting and stopping the egress proxy; the run id through `SPECKIT_WORKFLOW_RUN_ID` (contracts/sdd-run.md, contracts/routing.md)
- [ ] T039 [US1] Link `sdd-run` and `sdd-step` into `~/.local/bin` from `install.sh`, extending `checks/50-install.sh`'s link expectations; keep "install.sh is idempotent" green
- [ ] T040 [US1] Write `docs/sdd-routing.md`: creating the `claude-oauth` and `deepseek-api` Keychain items, opting a repository in, declaring `sdd.check`, starting, answering a checkpoint, resuming, reading usage, the routing layers and `sdd-run routing`; each claim with the date it was observed
- [ ] T041 [US1] Close US1: `./check.sh` green; each new check seen red with its behaviour broken by hand (SC-006); a fresh-context review of the story's diff, its findings fixed or recorded with the reason

**Checkpoint**: a routed run works end to end on Claude alone, every agent step contained.

---

## Phase 4: User Story 2 — implementation on DeepSeek (Priority: P2)

**Goal**: an opted-in repository's implementation runs on `deepseek-flash` through pi in the same contained pass.

**Independent test**: quickstart.md 9 against the stand-ins, then quickstart.md 11 on this machine.

### Tests for User Story 2 (first)

- [ ] T042 [P] [US2] Check the DeepSeek prerequisites (quickstart 9, SC-004, FR-010): for a route of `deepseek`, no `deepseek-api` item or a blank one stops `implement` with exit 1 naming it and the stand-in runtime records no call; a repository opted out after start gets a Sonnet pass that says so, records `agent: sonnet` and sends nothing to DeepSeek
- [ ] T043 [P] [US2] Check the pi pass (contracts/pass.md, contracts/routing.md): pi runs as `node` with `-p --mode json --no-session --model deepseek/<row.model> --thinking <row.effort>`; the pass's allow list holds the registries and `api.deepseek.com` only; a canned response naming another model, or lacking usage, fails the pass with nothing applied; `implement.json` records the model served, pi's version and its tokens
- [ ] T044 [P] [US2] Check the credentials never leak (FR-009): with sentinel values for `deepseek-api` and `claude-oauth` in the stand-in `security`, a stand-in agent that writes a sentinel into a file, its result or its `structured_output` is refused with nothing applied; after full passes the sentinels appear in no recorded argument, no host process environment, no file under the scratch repository, `$TMPDIR`, the bundle, the run state or logs — only on the stand-in container's stdin
- [ ] T045 [US2] Run T042–T044 red against the Sonnet-only `implement`; confirm each fails for its case's reason

### Implementation for User Story 2

- [ ] T046 [US2] Implement the DeepSeek path of `sdd-step implement` (contracts/sdd-step.md steps 1–4); T042–T044 green
- [ ] T047 [US2] On this machine, with the real container runtime: the containment probe of quickstart.md 11 (SC-003), each attempt recorded with its result in `docs/sdd-routing.md`; then a leak probe with sentinel credentials: the image's layers, the container's stored configuration and the runtime's logs searched for them, none holding them (FR-009)
- [ ] T048 [US2] Close US2: `./check.sh` green; each new check seen red; a fresh-context review of the story's diff

---

## Phase 5: User Story 3 — sdd-init installs the routing (Priority: P3)

**Goal**: new repositories get the routing; existing ones are told how.

**Independent test**: quickstart.md 10.

- [ ] T049 [US3] Test first: extend `checks/90-spec-kit.sh`'s `sdd_init` check against a stand-in `specify` — a fresh repository gets `specify workflow add <dotfiles>/claude/speckit/sdd-routed.yml` in the same commit; one with `.specify/` gets the add or update command printed and nothing changed; the printed opt-in line names DeepSeek's terms; run it red against today's `bin/sdd-init.sh`
- [ ] T050 [US3] Change `bin/sdd-init.sh` to install the workflow and print the commands for an existing repository; T049 green
- [ ] T051 [US3] Close US3: `./check.sh` green; T049 seen red with the change reverted by hand; a fresh-context review

---

## Phase 6: Measurement and polish

- [ ] T052 In `~/Development/spec-kit-preset-story-workers`, a feature of its own (short path, its constitution): extend `tests/eval/run.sh` from single-step arms to the two multi-step arms spec SC-001 defines — steps 11–16, the baseline's routing layer and implement replacement, checkpoint answers, not-counted rules — on `checkout` and `wordstats`, each with a state that removes `tasks.md` and carries `.sdd/phases.json` (specify and plan done); one usage tool for both arms; `versions.txt` gains the container runtime, pi, the Claude Code CLI and the dotfiles commit
- [ ] T053 Run three counted runs per arm per fixture with that harness; link its recorded result — median and range of usage per arm; per fixture, the routed arm's lowest held-out pass count against the baseline's median, the routed check command's result in each counted run, and each arm's counted and not-counted runs — from `docs/sdd-routing.md`, stating SC-001 and SC-002 met or not as it came out
- [ ] T054 Move the decisions later work builds on out of research.md before the PR opens: `docs/decisions/0001-sdd-routing.md` in MADR's shape — a workflow on Spec Kit's engine with a routing table and dispatcher (R2), layered routing (R18), the contained pass and its threat model (R20, R21), outcome files and verify without a model (R10) — linking research.md; point `CLAUDE.md` at `docs/decisions/`
- [ ] T055 `/speckit-converge` until a pass finds nothing above LOW; its tasks implemented last

---

## Dependencies & Execution Order

- Phase 1 → Phase 2 → US1 → US2 → US3 → Phase 6. T053 is blocked on T052, a feature of its own in the story-workers repository, with its own spec and review.
- The owner's `claude-oauth` token before T003; T001 before T002; T003 after T002; T004–T005 in parallel after T001; T006 after T002.
- T007 (CI) before any check in `checks/91-sdd-routing.sh` is relied on; T016 after T006; T017 after T012; T018 after T014.
- Within each phase: its test tasks, then the red run, then implementation, then the close.

## Parallel Example: User Story 1

```text
T021 T022 T023 T024 T025 T026 T027 T028 T029 T030 T031 T032   # independent checks, one file section each
T034 T035   # routing, profiles and brief, independent files
```

## Implementation Strategy

US1 alone is the MVP: routing per phase, checkpoints and Sonnet implementation, every agent step contained, with no new provider; if a week of real use on it fits the smaller plan, US2 becomes optional (spec, US1 "Why this priority"). US2 adds DeepSeek; US3 makes it the default; Phase 6 measures it.
