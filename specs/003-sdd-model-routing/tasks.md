# Tasks: Model routing per Spec Kit phase

**Input**: Design documents from `specs/003-sdd-model-routing/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: requested. Every story here has logic of its own (constitution III,
global instructions), so each story's test tasks come first, run once before
the code exists, and each must fail for the reason its case predicts (a missing
script is stubbed so the failure is the behaviour's, not collection's). Every
check in `checks/91-sdd-routing.sh` is seen red with its behaviour broken by
hand before it is trusted (SC-006).

**Organization**: one phase per user story. Phase 1 settles every "Pending" in
research.md on this machine; one that comes out against the design stops the
work and goes to the owner (plan.md, "Phase order").

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1, US2, US3 from spec.md

---

## Phase 1: Setup — settle the pending observations

**Purpose**: observe on this machine what the design rests on, before building on it. Each records its result, with date and command, in research.md under the entry it settles.

- [ ] T001 Declare `check-jsonschema` with a pinned reference in `uv-tools.txt` and the container runtime T002 settles on in the `Brewfile` (owner-approved 2026-10-21); install each with the command `install.sh` runs for it; confirm `./drift.sh` is clean for both
- [ ] T002 Probe the container runtime (research R5): under Apple `container` — the macOS version it requires, `container system start` and what it leaves on the machine, a throwaway run that mounts one scratch directory, and whether it grants `NET_ADMIN`/`NET_RAW` so Anthropic's reference `init-firewall.sh` (ipset allow list, `iptables -P OUTPUT DROP`) runs and blocks a host outside the list while reaching one inside; if it cannot, the same probe under colima with the Docker CLI. Record in research.md R5 which runtime passed and why; if the chosen runtime's first start leaves state, add its apply step to `install.sh` and its report to `drift.sh` here (constitution IV). If neither passes, stop and take it to the owner
- [ ] T003 [P] Probe Claude Code headless (research R4, R10, R14, R16): a `-p --permission-mode dontAsk --output-format json` call refused a tool its `--settings` does not allow — the result's `permission_denials` and the exit status; `--effort` given against the level the result reports; `--json-schema` returning `structured_output`; `--strict-mcp-config` with no server and the context it saves; that `--setting-sources user` keeps the user's hooks (config-guard fires) while a project `.claude/settings.json` allow rule does not widen the profile; that two consecutive Opus calls with the `judgment` then the `readonly` profile read the shared prefix from the cache; record in research.md R4, R10, R14, R16; if a profile change breaks the cache, record by how much and keep same-profile steps adjacent
- [ ] T004 [P] Probe Spec Kit 1.2.2's engine (research R3, R11, R12): a gate's `retry` and `abort` options inside a `do-while`; that a failed then resumed step's earlier attempt is still in `state.json` or `log.jsonl`; what `state.json` holds after the run's process is killed mid-step; record in research.md R3, R11, R12
- [ ] T005 [P] Probe `claude/config-guard.sh` (research R7): its verdict on a `Write` with empty content to `ruff.toml`, and on a `pyproject.toml` that loses `[tool.ruff]`; record in research.md R7
- [ ] T006 Probe pi 1.3.0 in the runtime T002 chose, behind the firewall (research R5, R6, R17): the flags R17's spike used (`-p --mode json --no-session --model deepseek/<id> --thinking <level>`); that `deepseek-flash` answers through the `models.json` entry with the key on stdin while the firewall blocks every host outside `egress.txt`; that `/models` still lists the ids R6 records; the `model` field a chat response reports (if it is the bare alias, record it as unpinned; if it is any other id, stop for the owner); record in research.md R6

**Checkpoint**: every "Pending" in research.md is observed. Commit research.md.

---

## Phase 2: Foundational — test harness and outcome contracts

**Purpose**: what every story's checks stand on.

- [ ] T007 Install `uv` in `.github/workflows/ci.yml` the way the other CI tools are installed — a pinned version, its checksum in `.github/tool-checksums.txt`, moved by `bump-tools.sh` — then `uv tool install` the `uv-tools.txt` entries `specify-cli` and `check-jsonschema` at their pins, so the routing checks run the same on the runner as here (constitution III); extend "installed tools match the ci.yml pins" to `uv`, extend `checks/20-tool-versions.sh`'s `bump_tools` check with a `uv` entry and see it red, and add `uv` to ci.yml's step that asserts the tools are the pinned versions; see a CI run green with the new checks before relying on them
- [ ] T008 Create `checks/91-sdd-routing.sh` with its section header and the stand-ins its checks share: a scratch repository set up with `specify init --here --force --integration claude` on a temporary `HOME`, and stand-ins for `claude` (records every argument, writes canned outcome files from a fixture directory, prints a JSON result), the container runtime and `security`, on a temporary `PATH`; the real Spec Kit 1.2.2 engine runs the workflow, since FR-025's assertions are about it (a stand-in `specify` is used only by T042); nothing reaches the network or the real Keychain
- [ ] T009 Test first, in `checks/91-sdd-routing.sh`: each schema accepts its valid sample and refuses a missing field, an extra field and a wrong enum value (`check-jsonschema`), and `sdd-step outcome <step>` prints each step's token from a valid file and exits non-zero on a missing or invalid one (FR-016); run it red against empty schemas (`{}`) and a stub `bin/sdd-step.sh` that exits 0
- [ ] T010 [P] Write the schemas in `claude/speckit/schemas/`: `route`, `routing`, `phases`, `clarify`, `implement`, `verify`, `review`, `converge` (`*.schema.json`, draft 2020-12), with the common fields `schema`, `step`, `at` and the fields of data-model.md "Outcome files", quoted there: `severity: CRITICAL/HIGH/MEDIUM/LOW`, `questions: integer 0–5`, `outcome: converged/tasks_appended`, `agent: deepseek/sonnet`, `additionalProperties: false`
- [ ] T011 Implement `sdd-step outcome` in `bin/sdd-step.sh` (contracts/sdd-step.md): validate with `check-jsonschema`, print `yes/no`, `pass/fail`, `blocking/clear`, `converged/open` as data-model.md defines them — `converged` only when `outcome` is `converged` and no finding is above LOW; T009 green

**Checkpoint**: outcome files are a contract a check enforces.

---

## Phase 3: User Story 1 — each phase on its own model (Priority: P1) 🎯 MVP

**Goal**: a feature runs from one command through every phase on its routed model, with checkpoints, outcome files and, while not opted in, implementation by Sonnet in a disposable checkout.

**Independent test**: quickstart.md 1–10 against the stand-ins, with the repository not opted in.

### Tests for User Story 1 (first, each run red before its code exists)

- [ ] T012 [P] [US1] Check routing and dispatch (quickstart 1, FR-001, FR-021, FR-025, FR-026): every agent step runs `sdd-step agent <phase>`, which calls the stand-in `claude` with its effective routing row's `--model` (Opus for specify, clarify, plan, checklist, analyze, review and converge; Sonnet for tasks) and `--effort`, `--settings` with its profile, `--setting-sources user`, `--permission-mode dontAsk`, `--strict-mcp-config` with no server, `--output-format json`, and `--json-schema` where the row has one; verify makes no `claude` call; same-model steps run adjacent; a row's `structured_output` lands in its outcome file and analyze's text in `analysis.md` (plain report, not JSON); each attempt is logged to `.sdd/usage.jsonl` with a start and an end line; a result with a `permission_denials` entry fails the step naming the refused tool and where its profile is widened; no call carries `--resume` or `--continue` (FR-002); the review step's prompt makes a deleted or weakened test a blocking finding (FR-019); every agent step's workflow `timeout` equals its default row's `timeout` plus 300, and an effective row raising `timeout` above that is refused; the engine's run id equals `SPECKIT_WORKFLOW_RUN_ID`
- [ ] T013 [P] [US1] Check checkpoints (quickstart 2, FR-004): without a TTY the run pauses at each gate and prints the `sdd-run resume` command; `approve` continues, `reject` aborts, for every gate in contracts/workflow.md
- [ ] T014 [P] [US1] Check clarify through a file (quickstart 3, FR-005): two canned questions pause the run at `answer-clarify` and `clarify-apply` runs after approval; zero questions skip the gate
- [ ] T015 [P] [US1] Check loops and retries (quickstart 5, FR-014, FR-015): a check command that always fails gives three implement passes then `fix-stuck`; `retry` gives exactly one more; a converge that never converges gives three passes then `converge-stuck`; on a fix round the agent's brief names `.sdd/verify.json` with the latest failures (FR-017)
- [ ] T016 [P] [US1] Check marking (quickstart 6, FR-006): `sdd-step mark` refuses on `verify` = fail or `review` = blocking, and marks only the task ids `review.json` lists
- [ ] T017 [P] [US1] Check `sdd-run` prerequisites (contracts/sdd-run.md, FR-011, FR-024, US1 AS7, FR-021): each missing prerequisite stops with exit 1 naming it — Spec Kit older than 1.2.1, no `.specify/`, the workflow missing or at an older version, a missing CLI, `sdd.check` unset; `CLAUDE_CODE_EFFORT_LEVEL` exported is unset before dispatch; `.sdd/routing.json` records every phase's effective row with each value's layer, and `sdd-run usage` reports the effort each step was given and the level its result reports, where it reports one (FR-021)
- [ ] T018 [P] [US1] Check the Sonnet implementation pass (quickstart 7–8, FR-008, FR-018, FR-023, US2 AS6–7): the feature directory is committed first; the stand-in agent works in a detached checkout; a created, changed or deleted `ruff.toml`, or a `pyproject.toml` without `[tool.ruff]`, exits 1 naming it with nothing applied; a judged patch is applied and committed as `worker: <feature> (claude-sonnet-5-5)`; an agent that outlives the limit is stopped and nothing applied; an implement row's `timeout` lowered through a routing layer is honoured, and one above 1800 refused (FR-018); an Edit or Write outside the checkout is refused by the per-pass settings and fails the pass naming it (FR-023); a crash leaves the feature's worktree unchanged and no checkout behind; `implement.json` records the usage from the JSON result
- [ ] T019 [P] [US1] Check interrupted runs (FR-022): a run lock naming a dead process (process id and start time) makes `cleanup` remove that run's leftovers and `resume` report the phases that will run again; `sdd-run start --from <feature dir>` passes `spec.md` and skips every phase in `.sdd/phases.json`, and is refused when no phase is finished; a run paused outside a gate resumes with no verdict and reruns the interrupted step; a lock whose process id was reused by another process is not taken for dead
- [ ] T020 [P] [US1] Check `sdd-step route` (contracts/sdd-step.md, FR-010, US3 AS3): opted in writes `route.json` with `deepseek`; not opted in writes `sonnet` and prints the opt-in line naming DeepSeek's terms of service and privacy policy; `route.json` validates
- [ ] T021 [P] [US1] Check `sdd-run usage` (contracts/sdd-run.md, SC-001's counting): from a canned `.sdd/usage.jsonl` it sums every attempt per Claude model at list price, failed and resumed ones included, lists attempts with a start line and no end line, or no usage, as unreported, prices pi's tokens from `models.json`, and prints the totals
- [ ] T022 [P] [US1] Check routing layers (FR-027, contracts/routing.md): a project file changes one field and keeps the rest of the row; a local file wins over the project file; `--set` wins over both for one run only; a layer naming an unknown phase or field, or an invalid value, stops `sdd-run` naming the layer, phase and field; `.sdd/routing.json` records each value's layer; `sdd-run routing` prints the same table; a layer with `agent: pi` in a repository not opted in still runs `implement-sonnet`; the local file is added to `.git/info/exclude`
- [ ] T023 [US1] Run every check of this story once against stubs of `bin/sdd-run.sh`, `bin/sdd-step.sh` and `claude/speckit/sdd-routed.yml`; confirm each fails for the reason its case predicts; commit the red run's output summary in the commit message

### Implementation for User Story 1

- [ ] T024 [P] [US1] Write `claude/speckit/routing.yml` with the rows of contracts/routing.md, `claude/speckit/schemas/routing-table.schema.json` and `routing-layer.schema.json`, and the profiles `claude/speckit/profiles/judgment.json` and `readonly.json` (research R4: they differ in permission rules only, never in the tool set, so the prompt cache's prefix stays the same across a same-model group, research R16); each default row with its `timeout`; `implement-sonnet` is composed per pass
- [ ] T025 [P] [US1] Write `containers/pi-worker/brief.md`, the brief both implementing agents get (FR-017): the tasks not marked done, spec, plan and every other file `/speckit-plan` wrote, the constitution, the test-first rules, no change to a check's configuration, nothing outside the tasks; the agent writes no outcome file (`sdd-step implement` is `implement.json`'s only writer)
- [ ] T026 [US1] Write `claude/speckit/sdd-routed.yml` per contracts/workflow.md: inputs with `enum` verdicts and `resume_from`, every agent step as a `shell` step running `sdd-step agent <phase>` with `timeout:` its row's limit plus 300, `verify` at 3600, `version` field; no model, effort or permission in the workflow
- [ ] T027 [US1] Implement the rest of `bin/sdd-step.sh` for this story: `agent` (contracts/routing.md: flags, result handling, denials, `usage.jsonl`), `route`, `verify`, `mark`, `phase-done`, `cleanup`, and `implement` for the Sonnet path (contracts/sdd-step.md steps 1 for sonnet and the time limit's range, 2, and 4–9)
- [ ] T028 [US1] Implement `bin/sdd-run.sh`: `start` (with `--set`), `start --from`, `resume`, `routing`, `usage`, the layered routing merge and its validation and the prerequisites of contracts/sdd-run.md; run id through `SPECKIT_WORKFLOW_RUN_ID`; run lock in `$(git rev-parse --git-dir)/sdd/`; the extra arguments of research R4 and R11
- [ ] T029 [US1] Link `sdd-run` and `sdd-step` into `~/.local/bin` from `install.sh`, extending `checks/50-install.sh`'s link expectations; keep "install.sh is idempotent" green
- [ ] T030 [US1] Write `docs/sdd-routing.md`: how to opt a repository in, declare `sdd.check`, start, answer a checkpoint, resume, read usage, widen the allow list; each claim with the date it was observed

### Close User Story 1

- [ ] T031 [US1] `./check.sh` green; break each new check's behaviour by hand once and see it red (SC-006); a fresh-context review of the story's diff, its findings fixed or recorded with the reason

**Checkpoint**: a routed run works end to end without DeepSeek.

---

## Phase 4: User Story 2 — implementation on DeepSeek, contained (Priority: P2)

**Goal**: an opted-in repository's implementation runs on `deepseek-flash` through pi in a container behind a deny-by-default firewall that sees only its checkout.

**Independent test**: quickstart.md 9 against the stand-ins, then quickstart.md 11 on this machine.

### Tests for User Story 2 (first)

- [ ] T032 [P] [US2] Check the DeepSeek prerequisites (quickstart 9, SC-004): for a route of `deepseek`, no container runtime, the runtime down, no Keychain item, a blank item — each stops `implement` with exit 1 naming it, and the stand-in container runtime records no call; a repository opted out after `route` ran gets a Sonnet pass that says so, checks Sonnet's prerequisites, records `agent: sonnet` in `implement.json`, and makes no container-runtime call (FR-010)
- [ ] T033 [P] [US2] Check the container invocation (contracts/sdd-step.md step 4, FR-007): the stand-in runtime sees exactly one bind mount, the checkout at `/work`, plus the volume `sdd-cache-<run_id>`; `NET_ADMIN`/`NET_RAW` and the firewall script run before pi; pi runs as `node` with the row's `--model` and `--thinking`; the run-id label; the image tag from the hash of `containers/pi-worker/`; the time limit enforced before the step's `timeout`; a canned response naming another model, or lacking usage, fails the pass
- [ ] T034 [P] [US2] Check the credential never leaks (FR-009): with a sentinel key in the stand-in `security`, after a full pass the sentinel appears in no argument the stand-ins recorded, no environment of a host process they saw, no file under the scratch repository, `$TMPDIR`, the run state or logs — only on the stand-in container's stdin
- [ ] T035 [P] [US2] Check `containers/pi-worker/init-firewall.sh` and `entrypoint.sh` against stand-ins for `iptables`, `ipset`, `dig`/`getent` and `su`/`gosu` that record their calls (constitution III): the rules set the OUTPUT policy to DROP before any allow rule, allow exactly the resolved addresses of `egress.txt`'s hosts plus DNS and loopback, and end with a REJECT; a host that does not resolve stops the script non-zero; the entrypoint runs the firewall before it reads the key, reads the key once from stdin, writes it to no file, and starts pi as `node`; each case seen red with the script broken by hand
- [ ] T036 [US2] Run T032–T035 red against the Sonnet-only `sdd-step implement`; confirm each fails for its case's reason

### Implementation for User Story 2

- [ ] T037 [P] [US2] Write `containers/pi-worker/Containerfile` (Node base pinned by digest, `iptables`, `ipset`, `@earendil-works/pi-coding-agent@1.3.0`, mise, uv, a non-root `node` user), `init-firewall.sh` (Anthropic's reference pattern, its source and date in a comment, the allow list read from `egress.txt`), `entrypoint.sh` (firewall first, then the key from stdin once, then pi as `node` with the brief), `egress.txt` (DeepSeek's API host and the registries research R5 names) and `models.json` (the ids `/models` returned in T006, and their per-token prices from DeepSeek's pricing page with the date read)
- [ ] T038 [US2] Implement the DeepSeek path of `sdd-step implement` (contracts/sdd-step.md steps 1, 3, 4) and its record in `implement.json` (`model`, `pi_version`, tokens); a served model other than `models.json`'s, or a missing usage field, fails the pass naming it (checked in T033)
- [ ] T039 [US2] Add to `drift.sh` a report of the worker image's pins against upstream — `@earendil-works/pi-coding-agent`'s latest version and the Node 26 base's current digest — as it reports `uv-tools.txt` pins behind upstream (constitution V); with its check in `checks/` seen red
- [ ] T040 [US2] On this machine, with the real container runtime research R5 settled on: the containment probe of quickstart.md 11 (SC-003), each attempt recorded with its result in `docs/sdd-routing.md`; then a leak probe with a sentinel key: the image's layers, the container's stored configuration and the runtime's logs searched for it, none holding it (FR-009)

### Close User Story 2

- [ ] T041 [US2] `./check.sh` green; each new check seen red; a fresh-context review of the story's diff

---

## Phase 5: User Story 3 — sdd-init installs the routing (Priority: P3)

**Goal**: new repositories get the routing; existing ones are told how.

**Independent test**: quickstart.md 10.

- [ ] T042 [US3] Test first: extend `checks/90-spec-kit.sh`'s `sdd_init` check — a fresh repository gets `specify workflow add <dotfiles>/claude/speckit/sdd-routed.yml` in the same commit; one with `.specify/` gets the add or update command printed and nothing changed; the printed opt-in line names DeepSeek's terms; run it red against today's `bin/sdd-init.sh`
- [ ] T043 [US3] Change `bin/sdd-init.sh` to install the workflow and print the commands for an existing repository; T042 green
- [ ] T044 [US3] `./check.sh` green; T042 seen red with the change reverted by hand; a fresh-context review

---

## Phase 6: Measurement and polish

- [ ] T045 In `~/Development/spec-kit-preset-story-workers`, a feature of its own (short path, its constitution): extend `tests/eval/run.sh` from single-step arms to the two multi-step arms spec SC-001 defines — steps 11–16, the baseline's implement replacement, checkpoint answers, not-counted rules — on `checkout` and `wordstats`, each with a state that removes `tasks.md` and carries `.sdd/phases.json` (specify and plan done); one usage tool for both arms; `versions.txt` gains the container runtime, pi and the dotfiles commit
- [ ] T046 Run three counted runs per arm per fixture with that harness; link its recorded result — median and range of usage per arm; per fixture, the routed arm's lowest held-out pass count against the baseline's median, the routed check command's result in each counted run, and each arm's counted and not-counted runs — from `docs/sdd-routing.md`, stating SC-001 and SC-002 met or not as it came out
- [ ] T047 Move the decisions later work builds on out of research.md before the PR opens: `docs/decisions/0001-sdd-routing-workflow.md` (a workflow of our own on Spec Kit's engine; outcome files in JSON validated against schemas; verify without a model) in MADR's shape, linking research.md R1, R10; point `CLAUDE.md` at `docs/decisions/`
- [ ] T048 `/speckit-converge` until a pass finds nothing above LOW; its tasks implemented last

---

## Dependencies & Execution Order

- Phase 1 → Phase 2 → US1 → US2 → US3 → Phase 6. T046 is blocked on T045, a feature of its own in the story-workers repository, with its own spec and review. US2 builds on US1's `sdd-step implement` (checkout, judgment, time limit); US3 needs the workflow file from US1.
- T001 before T002; T003–T005 in parallel after T001; T006 after T002; T007 (CI) before any check in `checks/91-sdd-routing.sh` is relied on.
- Within each story: its test tasks, then the red run, then implementation, then the close.

## Parallel Example: User Story 1

```text
T012 T013 T014 T015 T016 T017 T018 T019 T020 T021 T022   # independent checks, one file section each
T024 T025                                           # settings and brief, independent files
```

## Implementation Strategy

US1 alone is the MVP: routing per phase, checkpoints and Sonnet implementation, with no new provider; if a week of real use on it fits the smaller plan, US2 becomes optional (spec, US1 "Why this priority"). US2 adds DeepSeek; US3 makes it the default; Phase 6 measures it.
