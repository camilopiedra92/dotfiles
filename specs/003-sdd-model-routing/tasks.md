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

- [ ] T001 Declare Apple `container` in `Brewfile` and `check-jsonschema` with a pinned reference in `uv-tools.txt` (owner-approved 2026-10-21); install both with the commands `install.sh` runs for them; confirm `./drift.sh` is clean for both
- [ ] T002 Probe `container` (research R5): the macOS version it requires, `container system start`, a throwaway `container run --rm` that mounts one scratch directory, and whether its networking can restrict egress to named hosts; record in research.md R5. If egress cannot be restricted by the runtime, stop and take it to the owner
- [ ] T003 [P] Probe Claude Code headless (research R4, R14): a `-p --permission-mode dontAsk --output-format json` call refused a tool not allowed — record the result's shape and exit status; a `--settings` `modelSettings` level against the user file's for a `-p` run, and where the result reports the level; record in research.md R4 and R14. If `--settings` does not win, stop and take it to the owner (FR-021)
- [ ] T004 [P] Probe Spec Kit 1.2.2's engine (research R3, R11, R12): a gate's `retry` and `abort` options inside a `do-while`; that a failed then resumed step's earlier attempt is still in `state.json` or `log.jsonl`; what `state.json` holds after the run's process is killed mid-step; record in research.md R3, R11, R12
- [ ] T005 [P] Probe `claude/config-guard.sh` (research R7): its verdict on a `Write` with empty content to `ruff.toml`, and on a `pyproject.toml` that loses `[tool.ruff]`; record in research.md R7
- [ ] T006 Probe pi 1.3.0 in a throwaway Node 26 container (research R6, R14): the flags for print mode, JSON output, model and reasoning level; that `deepseek-flash` answers a one-line prompt through the `models.json` entry, with the key on stdin; that `/models` still lists the ids R6 records; the `model` field a chat response reports (if it is the bare alias, record it as unpinned; if it is any other id, stop for the owner); record in research.md R6 and R14

**Checkpoint**: every "Pending" in research.md is observed. Commit research.md.

---

## Phase 2: Foundational — test harness and outcome contracts

**Purpose**: what every story's checks stand on.

- [ ] T007 Create `checks/91-sdd-routing.sh` with its section header and the stand-ins its checks share: a scratch repository set up with `specify init --here --force --integration claude` on a temporary `HOME`, and stand-ins for `claude` (records every argument, writes canned outcome files from a fixture directory, prints a JSON result), `container` and `security`, on a temporary `PATH`; the real Spec Kit 1.2.2 engine runs the workflow, since FR-025's assertions are about it (a stand-in `specify` is used only by T036); nothing reaches the network or the real Keychain
- [ ] T008 [P] Write the schemas in `claude/speckit/schemas/`: `route`, `routing`, `phases`, `clarify`, `implement`, `verify`, `review`, `converge` (`*.schema.json`, draft 2020-12), with the common fields `schema`, `step`, `at` and the fields of data-model.md "Outcome files", quoted there: `severity: CRITICAL/HIGH/MEDIUM/LOW`, `questions: integer 0–5`, `outcome: converged/tasks_appended`, `agent: deepseek/sonnet`, `additionalProperties: false`
- [ ] T009 Test first, in `checks/91-sdd-routing.sh`: each schema accepts its valid sample and refuses a missing field, an extra field and a wrong enum value (`check-jsonschema`), and `sdd-step outcome <step>` prints each step's token from a valid file and exits non-zero on a missing or invalid one (FR-016); run it red against a stub `bin/sdd-step.sh` that exits 0
- [ ] T010 Implement `sdd-step outcome` in `bin/sdd-step.sh` (contracts/sdd-step.md): validate with `check-jsonschema`, print `yes/no`, `pass/fail`, `blocking/clear`, `converged/open` as data-model.md defines them — `converged` only when `outcome` is `converged` and no finding is above LOW; T009 green

**Checkpoint**: outcome files are a contract a check enforces.

---

## Phase 3: User Story 1 — each phase on its own model (Priority: P1) 🎯 MVP

**Goal**: a feature runs from one command through every phase on its routed model, with checkpoints, outcome files and, while not opted in, implementation by Sonnet in a disposable checkout.

**Independent test**: quickstart.md 1–10 against the stand-ins, with the repository not opted in.

### Tests for User Story 1 (first, each run red before its code exists)

- [ ] T011 [P] [US1] Check routing and dispatch (quickstart 1, FR-001, FR-025): specify, clarify, plan, checklist, analyze, review and converge called with `--model claude-opus-5-5`, tasks with `claude-sonnet-5-5`, verify with no `claude` call, in that order; every call carries `--permission-mode dontAsk`, `--settings` and `--output-format json`; the engine's run id equals `SPECKIT_WORKFLOW_RUN_ID`; each Claude step's stdout is in `state.json`
- [ ] T012 [P] [US1] Check checkpoints (quickstart 2, FR-004): without a TTY the run pauses at each gate and prints the `sdd-run resume` command; `approve` continues, `reject` aborts, for every gate in contracts/workflow.md
- [ ] T013 [P] [US1] Check clarify through a file (quickstart 3, FR-005): two canned questions pause the run at `answer-clarify` and `clarify-apply` runs after approval; zero questions skip the gate
- [ ] T014 [P] [US1] Check loops and retries (quickstart 5, FR-014, FR-015): a check command that always fails gives three implement passes then `fix-stuck`; `retry` gives exactly one more; a converge that never converges gives three passes then `converge-stuck`
- [ ] T015 [P] [US1] Check marking (quickstart 6, FR-006): `sdd-step mark` refuses on `verify` = fail or `review` = blocking, and marks only the task ids `review.json` lists
- [ ] T016 [P] [US1] Check `sdd-run` prerequisites (contracts/sdd-run.md, FR-011, FR-024, US1 AS7, FR-021): each missing prerequisite stops with exit 1 naming it — Spec Kit older than 1.2.1, no `.specify/`, the workflow missing or at an older version, a missing CLI, `sdd.check` unset; `CLAUDE_CODE_EFFORT_LEVEL` exported is unset before dispatch; `.sdd/routing.json` records each model's id and effort
- [ ] T017 [P] [US1] Check the Sonnet implementation pass (quickstart 7–8, FR-008, FR-018, FR-023, US2 AS6–7): the feature directory is committed first; the stand-in agent works in a detached checkout; a created, changed or deleted `ruff.toml`, or a `pyproject.toml` without `[tool.ruff]`, exits 1 naming it with nothing applied; a judged patch is applied and committed as `worker: <feature> (claude-sonnet-5-5)`; an agent that outlives the limit is stopped and nothing applied; a crash leaves the feature's worktree unchanged and no checkout behind; `implement.json` records the usage from the JSON result
- [ ] T018 [P] [US1] Check interrupted runs (FR-022): a run lock naming a dead process (process id and start time) makes `cleanup` remove that run's leftovers and `resume` report the phases that will run again; `sdd-run start --from <feature dir>` passes `spec.md` and skips every phase in `.sdd/phases.json`, and is refused when no phase is finished; a run paused outside a gate resumes with no verdict and reruns the interrupted step; a lock whose process id was reused by another process is not taken for dead
- [ ] T019 [US1] Run T011–T018 once against stubs of `bin/sdd-run.sh`, `bin/sdd-step.sh` and `claude/speckit/sdd-routed.yml`; confirm each fails for the reason its case predicts; commit the red run's output summary in the commit message

### Implementation for User Story 1

- [ ] T020 [P] [US1] Write `claude/speckit/routing-settings.json`: the `allow` list of research R4 and `modelSettings` `{"claude-opus-5-5": {"effortLevel": "medium"}, "claude-sonnet-5-5": {"effortLevel": "medium"}}` (research R14)
- [ ] T021 [P] [US1] Write `containers/pi-worker/brief.md`, the brief both implementing agents get (FR-017): the tasks not marked done, spec, plan and every other file `/speckit-plan` wrote, the constitution, the test-first rules, no change to a check's configuration, nothing outside the tasks, write `implement.json`
- [ ] T022 [US1] Write `claude/speckit/sdd-routed.yml` per contracts/workflow.md: inputs with `enum` verdicts and `resume_from`, every step, `capture: true` and the timeouts of research R11 (3600 judgment, 1800 tasks, 2100 implement, 3600 verify), `version` field
- [ ] T023 [US1] Implement the rest of `bin/sdd-step.sh` for this story: `route`, `verify`, `mark`, `phase-done`, `cleanup`, and `implement` for the Sonnet path (contracts/sdd-step.md steps 2, 4–8)
- [ ] T024 [US1] Implement `bin/sdd-run.sh`: `start`, `start --from`, `resume`, `usage` and the prerequisites of contracts/sdd-run.md; run id through `SPECKIT_WORKFLOW_RUN_ID`; run lock in `$(git rev-parse --git-dir)/sdd/`; the extra arguments of research R4 and R11
- [ ] T025 [US1] Link `sdd-run` and `sdd-step` into `~/.local/bin` from `install.sh`, extending `checks/50-install.sh`'s link expectations; keep "install.sh is idempotent" green
- [ ] T026 [US1] Write `docs/sdd-routing.md`: how to opt a repository in, declare `sdd.check`, start, answer a checkpoint, resume, read usage, widen the allow list; each claim with the date it was observed

### Close User Story 1

- [ ] T027 [US1] `./check.sh` green; break each new check's behaviour by hand once and see it red (SC-006); a fresh-context review of the story's diff, its findings fixed or recorded with the reason

**Checkpoint**: a routed run works end to end without DeepSeek.

---

## Phase 4: User Story 2 — implementation on DeepSeek, contained (Priority: P2)

**Goal**: an opted-in repository's implementation runs on `deepseek-flash` through pi in a `container` VM that sees only its checkout.

**Independent test**: quickstart.md 9 against the stand-ins, then quickstart.md 11 on this machine.

### Tests for User Story 2 (first)

- [ ] T028 [P] [US2] Check the DeepSeek prerequisites (quickstart 9, SC-004): not opted in, no `container`, its service down, no Keychain item, a blank item — each stops `implement` with exit 1 naming it, and the stand-in `container` records no call
- [ ] T029 [P] [US2] Check the container invocation (contracts/sdd-step.md step 4, FR-007): the stand-in `container` sees exactly one bind mount, the checkout at `/work`, plus the volume `sdd-cache-<run_id>`; the run-id label; the image tag from the hash of `containers/pi-worker/`; the egress list from `egress.txt`; the time limit enforced before the step's `timeout`; a canned response naming another model, or lacking usage, fails the pass
- [ ] T030 [P] [US2] Check the credential never leaks (FR-009): with a sentinel key in the stand-in `security`, after a full pass the sentinel appears in no argument the stand-ins recorded, no environment of a host process they saw, no file under the scratch repository, `$TMPDIR`, the run state or logs — only on the stand-in container's stdin
- [ ] T031 [US2] Run T028–T030 red against the Sonnet-only `sdd-step implement`; confirm each fails for its case's reason

### Implementation for User Story 2

- [ ] T032 [P] [US2] Write `containers/pi-worker/Containerfile` (Node 26 base pinned by digest, `@earendil-works/pi-coding-agent@1.3.0`, mise, uv), `entrypoint.sh` (reads the key from stdin once, starts pi with the brief), `models.json` (the ids `/models` returned in T006) and `egress.txt` (DeepSeek's API host and the registries research R5 names)
- [ ] T033 [US2] Implement the DeepSeek path of `sdd-step implement` (contracts/sdd-step.md steps 1, 3, 4) and its record in `implement.json` (`model`, `pi_version`, tokens); a served model other than `models.json`'s, or a missing usage field, fails the pass naming it (checked in T029)
- [ ] T034 [US2] On this machine, with the real `container`: the containment probe of quickstart.md 11 (SC-003), each attempt recorded with its result in `docs/sdd-routing.md`

### Close User Story 2

- [ ] T035 [US2] `./check.sh` green; each new check seen red; a fresh-context review of the story's diff

---

## Phase 5: User Story 3 — sdd-init installs the routing (Priority: P3)

**Goal**: new repositories get the routing; existing ones are told how.

**Independent test**: quickstart.md 10.

- [ ] T036 [US3] Test first: extend `checks/90-spec-kit.sh`'s `sdd_init` check — a fresh repository gets `specify workflow add <dotfiles>/claude/speckit/sdd-routed.yml` in the same commit; one with `.specify/` gets the add or update command printed and nothing changed; the printed opt-in line names DeepSeek's terms; run it red against today's `bin/sdd-init.sh`
- [ ] T037 [US3] Change `bin/sdd-init.sh` to install the workflow and print the commands for an existing repository; T036 green
- [ ] T038 [US3] `./check.sh` green; T036 seen red with the change reverted by hand; a fresh-context review

---

## Phase 6: Measurement and polish

- [ ] T039 In `~/Development/spec-kit-preset-story-workers`, a feature of its own (short path, its constitution): extend `tests/eval/run.sh` from single-step arms to the two multi-step arms spec SC-001 defines — steps 11–16, the baseline's implement replacement, checkpoint answers, not-counted rules — on `checkout` and `wordstats`, each with a state that removes `tasks.md` and carries `.sdd/phases.json` (specify and plan done); one usage tool for both arms; `versions.txt` gains `container`, pi and the dotfiles commit
- [ ] T040 Run three counted runs per arm per fixture with that harness; link its recorded result — median and range of usage per arm; per fixture, the routed arm's lowest held-out pass count against the baseline's median, the routed check command's result in each counted run, and each arm's counted and not-counted runs — from `docs/sdd-routing.md`, stating SC-001 and SC-002 met or not as it came out
- [ ] T041 Move the decisions later work builds on out of research.md before the PR opens: `docs/decisions/0001-sdd-routing-workflow.md` (a workflow of our own on Spec Kit's engine; outcome files in JSON validated against schemas; verify without a model) in MADR's shape, linking research.md R1, R10; point `CLAUDE.md` at `docs/decisions/`
- [ ] T042 `/speckit-converge` until a pass finds nothing above LOW; its tasks implemented last

---

## Dependencies & Execution Order

- Phase 1 → Phase 2 → US1 → US2 → US3 → Phase 6. US2 builds on US1's `sdd-step implement` (checkout, judgment, time limit); US3 needs the workflow file from US1.
- T001 before T002; T003–T005 in parallel after T001; T006 after T002.
- Within each story: its test tasks, then the red run, then implementation, then the close.

## Parallel Example: User Story 1

```text
T011 T012 T013 T014 T015 T016 T017 T018   # independent checks, one file section each
T020 T021                                 # settings and brief, independent files
```

## Implementation Strategy

US1 alone is the MVP: routing per phase, checkpoints and Sonnet implementation, with no new provider; if a week of real use on it fits the smaller plan, US2 becomes optional (spec, US1 "Why this priority"). US2 adds DeepSeek; US3 makes it the default; Phase 6 measures it.
