# Tasks: Checks for the scripts with logic and no check

**Input**: Design documents from `specs/001-script-checks/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [quickstart.md](quickstart.md)

**Tests**: The checks are the deliverable. Three of the four scripts already
behave as specified, so each check is written first and must pass against the
script as it is; it is then trusted only after the script, broken by hand once
per acceptance scenario, turns it red naming that scenario (FR-004), and the
script is restored. The one script change (US4's socket default) is the
exception: its check is written and seen red before the change.

**Organization**: one phase per user story; each closes with the whole suite
(`./check.sh`) and a fresh-context review. The project has no mutation check.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependencies)
- **[Story]**: which user story the task belongs to

## Phase 1: Setup

- [x] T001 Confirm `./check.sh` passes on the branch before any change, and record its wall time as the baseline for SC-003

## Phase 2: Foundational

None: each story's fixtures are its own (research R2-R5); nothing is shared.

## Phase 3: User Story 1 - A broken push guard fails the gate (P1) 🎯 MVP

**Goal**: the gate fails, naming the case, when `githooks/pre-push` stops refusing a deletion or rewrite of the protected branch or starts refusing ordinary pushes.

**Independent Test**: passes against the guard as it is; fails naming the deletion case against a guard edited to allow deletion.

- [x] T002 [US1] Create `checks/15-githooks.sh` with the header every `checks/*.sh` carries and a "Git hooks" section, and a `pre_push_guard` check: scratch bare remote and clone under `mktemp -d`, removed on return; scratch commits with `-c user.name=t -c user.email=t@t`; every push as `git -c core.hooksPath="$PWD/githooks" push`; covering spec US1 scenarios 1-8 (R2): deletion refused, non-fast-forward refused naming both commits, fast-forward allowed, first push allowed, other branches rewritten and deleted freely, remote default `trunk` protected and `main` then not, `origin/HEAD` removed protects `main`, hint printed on refusal only, two-ref push refused whole when one ref is refused
- [x] T003 [US1] Run `./check.sh`; the new check passes against the unmodified `githooks/pre-push`
- [x] T004 [US1] Break `githooks/pre-push` by hand once per scenario 1-8 and confirm the check fails naming it each time; restore with `git checkout -- githooks/pre-push`; record each break and its failure line for the PR body
- [x] T005 [US1] Story close: `./check.sh` passes; fresh-context review of `checks/15-githooks.sh`

## Phase 4: User Story 2 - A broken commit gate fails the gate (P2)

**Goal**: the gate fails when `githooks/pre-commit` lets a failing commit through or drops strict mode.

**Independent Test**: passes against the hook as it is; fails naming strict mode against a hook without `--strict`.

- [x] T006 [US2] Add a `pre_commit_gate` check to `checks/15-githooks.sh` (R3): scratch repo whose committed `check.sh` stub appends its arguments and `$PWD` to a log and exits with the code in a file; `git -c core.hooksPath="$PWD/githooks" commit`; covering US2 scenarios 1-3: failing checks refuse the commit and print the bypass, passing checks let it land, the stub ran from the scratch repo's top level with exactly `--strict`
- [x] T007 [US2] Run `./check.sh`; the check passes against the unmodified `githooks/pre-commit`
- [x] T008 [US2] Break `githooks/pre-commit` once per scenario (ignore the exit status; drop the message; drop `--strict`) and confirm each fails naming it; restore; record for the PR body
- [x] T009 [US2] Story close: `./check.sh` passes; fresh-context review

## Phase 5: User Story 3 - A broken pin updater fails the gate (P3)

**Goal**: the gate fails when `bump-tools.sh` moves a pin without its checksum, backwards, to an undownloadable artifact, without a checksum line to replace, partly, or with the wrong spelling.

**Independent Test**: passes against the updater as it is; fails against an updater that skips the checksum rewrite.

- [x] T010 [US3] Add a `bump_tools` check at the end of `checks/20-tool-versions.sh` (R4): scratch dir with a symlink to `$PWD/bump-tools.sh`, synthetic `.github/workflows/ci.yml` (the seven `*_VERSION:` lines, shellcheck and shfmt spelled with `v`) and `.github/tool-checksums.txt` (one line per pinned artifact name, as `name_of` spells it); stub `gh` answering from a latest-versions table (ghostty through the tags listing) and stub `curl` writing `artifact:<url>` to `-o` or failing for listed URLs, first on `PATH`; covering US3 scenarios 1-7: one tool moved with its pin and checksum (the real `shasum` of the stub artifact) and nothing else changed, all current leaves both files byte-identical and says so, downgrade refused untouched, undownloadable refused untouched, missing checksum line refused untouched, a run that moves shellcheck then fails on shfmt leaves shellcheck consistent and shfmt untouched, `v` spelling kept for shellcheck and absent for taplo
- [x] T011 [US3] Run `./check.sh`; the check passes against the unmodified `bump-tools.sh`
- [x] T012 [US3] Break `bump-tools.sh` once per scenario 1-7 and confirm each fails naming it; restore; record for the PR body
- [x] T013 [US3] Story close: `./check.sh` passes; fresh-context review

## Phase 6: User Story 4 - A broken machine reset fails the gate (P4)

**Goal**: the gate fails when `bin/dev-nuke.sh` runs without root, acts on another user's processes, kills before asking, deletes beyond the socket, or runs user-side commands as root.

**Independent Test**: passes against the reset as it is; fails naming the escalation case against a reset that sends KILL first.

- [x] T014 [US4] Create `checks/55-dev-nuke.sh` with the standard header, a "dev-nuke" section and a `dev_nuke` check (R5): a hermetic `PATH` of stubs (`id`, `dscl`, `stat`, `sudo`, `pgrep`, `kill`, `sleep`, `osascript`, `brew`, `dscacheutil`, `killall`, `purge`, guarded `rm`) logging to a calls file, and symlinks to `awk cat date dirname mkdir tee tr xargs`; `SUDO_USER` set, `dscl` answering a scratch home; a process table file read by `pgrep` (`-x` for apps, `-f -u USER` for patterns) and updated by `kill -TERM` for processes marked obeying; `DEV_NUKE_PG_SOCKET` pointing at a scratch socket file beside a sibling file; covering US4 scenarios 1-6, plus DNS flush and purge invoked
- [x] T015 [US4] Run `./check.sh`; every scenario but the socket one passes against the unmodified `bin/dev-nuke.sh`, and the socket one fails because the script ignores `DEV_NUKE_PG_SOCKET` (the guarded `rm` refuses the real path); confirm that is the failure's reason
- [x] T016 [US4] In `bin/dev-nuke.sh`, read the socket path as `${DEV_NUKE_PG_SOCKET:-/tmp/.s.PGSQL.5432}` with a comment giving R6's reason; run `./check.sh`; the check passes
- [x] T017 [US4] Break `bin/dev-nuke.sh` once per scenario 1-6 and confirm each fails naming it; restore; record for the PR body
- [x] T018 [US4] Story close: `./check.sh` passes; fresh-context review

## Phase 7: Polish

- [x] T019 Extend the summary paragraph of `docs/checks.md` to name the four new checks and their stubs, in the style of its existing list
- [x] T020 Measure the full `./check.sh` wall time against T001's baseline; the difference is under 10 s (SC-003)
- [x] T021 Run `./check.sh --strict` (the gate's own mode) and confirm the new files pass shellcheck and shfmt

## Dependencies

- US1-US4 are independent: different scripts and fixtures. US1 and US2 share `checks/15-githooks.sh`, so US2's edits follow US1's.
- Polish follows all four stories.

## Parallel Execution

- T010 (US3) and T014 (US4) touch different files and can be written alongside US1.
- Red runs (T004, T008, T012, T017) each edit one script and must not overlap with each other's restore.

## Implementation Strategy

US1 first (MVP: the guard on the branch everything lands on), then US2-US4 in priority order, one PR for the feature as the spec defines it.

## Phase 8: Convergence

- [x] T022 Make the curl stub in `checks/20-tool-versions.sh` honour `-f` (exit 22 on a listed URL only with `-f`, else write a 404 body and exit 0) and `-L` (write a redirect body unless `-L`), and see `curl -sSL` and `curl -fsS` breaks of `bump-tools.sh` go red per US3/AC4 (partial)
- [x] T023 Require `as=me tee -a` and `as=me mkdir -p` on the scratch home's log path in `checks/55-dev-nuke.sh`, and see a `>> "$LOG_FILE"` redirection break go red per US4/AC6 (partial)
- [x] T024 Reword the dev-nuke clause of `docs/checks.md` to say what the hermetic PATH contains and what escapes it per FR-002 (contradicts)
- [x] T025 Name redirections and builtins among the escapes in the header comment of `checks/55-dev-nuke.sh` per Constitution VI (partial)
- [x] T026 Update research.md R2's Decision to the scratch copy of the hook per research R2 (contradicts)
- [x] T027 Give `bump_tools` a hermetic PATH as R5 reasons for dev-nuke, and record it in research.md R4, per FR-002 (partial)
- [x] T028 Name the strict-mode case in `pre_commit_gate`'s call failure, matching quickstart.md, per FR-003 (partial)

## Phase 9: Convergence

- [x] T029 Add lines that use each `*_VERSION` variable without being its pin to the fixture `ci.yml` in `checks/20-tool-versions.sh` and to every expected file, and see a break that rewrites every line mentioning the variable go red per US3/AC1 (partial)
- [x] T030 Run `bump-tools.sh` in the check with `TMPDIR` inside the scratch directory and assert it is left empty, and see a break that drops the script's EXIT trap go red per FR-002 (partial)
- [x] T031 Reflow the comment paragraphs at `checks/55-dev-nuke.sh:16` and `checks/20-tool-versions.sh:75` per Constitution VI (partial)
- [ ] T032 Write each scenario's break and its failure line into the PR #144 body before it is marked ready per FR-004 (partial)
