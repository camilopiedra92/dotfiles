---

description: "Task list for extracting the SDD routing harness"
---

# Tasks: Extract the SDD routing harness

**Input**: `specs/008-extract-sdd-routing/` (spec, plan, research, inventory, contracts/install.md)

**Tests**: requested where a task has logic of its own: the vendor hash check,
the launchers and the wheel, the changed messages, the kernel step, the two
drift reports. Test tasks come first in their story, run once before the code
exists, and each must fail for the reason its case predicts (a missing name
proves only collection: stub it and rerun); each is kept only once the code
broken by hand turns it red. A pure move (the import, the docs, CI wiring) has
no test of its own: its proof is a named command in the task.

**Load rule**: one full suite run per story close, never repeated (the commit
hook is the run); between, run only the new section with `--staged` or by
calling it alone in a scratch clone.

**Repositories**: `[N]` = new repository (`~/Development/sdd-routing`), `[D]` = dotfiles
(this worktree), `[O]` = the owner's own action (GitHub, tags, a real run).

## Phase 1: Setup

- [ ] T001 [D] Freeze: the 003 agent has stopped; record the 003 tip sha in research.md R2; re-run the R2 dry run from that tip into a scratch repository and replace the 2026-10-23 numbers (commits, files, `--follow` counts, blob-id equality, re-run equality)
- [ ] T002 [O] Decide the open questions that block building (research "Open questions" 1, 2, 4, 5, 6, 8): record each answer or "default accepted" beside it; defaults are the plan's text

## Phase 2: Foundational (new repository, no logic)

- [ ] T003 [N] Create `~/Development/sdd-routing` with the import only: `git init`, `git fast-export <003 tip> -- <paths.txt> | git fast-import`, branch `main`; check: blob ids at the tip equal the source's (`ls-tree -r` diff empty), `git log --follow` counts equal for `claude/speckit/brief.md`, `bin/sdd-pass.py` and one `containers/worker/` file; `gitleaks detect` over the history is clean (or findings are listed for the owner); no remote added, no GitHub repository created
- [ ] T004 [N] On branch `001-standalone`: `sdd-init` for its own `.specify/` and skills; `/speckit-constitution` from research R12 (each principle names its check); `CLAUDE.md` (under 200 lines, `@.specify/memory/constitution.md`); `.gitattributes` marking vendored files `linguist-vendored`; `LICENSE` (owner picks, OQ); README stub linking `docs/sdd-routing.md`

## Phase 3: User Story 1 - The harness lives and is checked on its own (P1) MVP

**Goal**: a clone with no dotfiles runs `./check.sh --strict` green; CI runs the same.

### Tests first

- [ ] T005 [N] [US1] Test first, `checks/00-vendor.sh` (`# covers: vendor/* check.sh checks/lib/* githooks/* claude/config-guard.sh checks/07-declarations.sh`): in scratch copies, (a) every file listed in `vendor/SOURCES` hashes to its recorded sha256, (b) a one-byte edit of `check.sh` fails naming the file and the recorded commit, (c) a vendored file with no line fails, (d) a line without its file fails, (e) `vendor/sync.sh` against a scratch "dotfiles" repository writes the file and its line and (a) then passes. Run before `sync.sh` and `SOURCES` exist: red because they are missing (stub `sync.sh`, rerun: red for the case's reason)
- [ ] T006 [N] [US1] Test first, `checks/10-wheel.sh` (`# covers: pyproject.toml sdd_routing/* bin/* claude/* containers/*`): from a scratch clone with a scratch tag, `uv build --wheel` and `uv tool install --from git+file://...@tag` into scratch `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR`; assert (a) `diff -r` of installed `bin/ claude/ containers/` against the tracked files is empty and exec bits equal, (b) `sdd-run` with no arguments from `/` exits 2 with a first line starting `usage: sdd-run `, (c) `sdd-step` outside a run exits 1 with `SDD_RUN_DIR names no run bundle`, (d) no `checks/`, `specs/`, `docs/` in the wheel. Red now: no `pyproject.toml`
- [ ] T007 [N] [US1] Test first, in `checks/95-sdd-run.sh`: the missing-tool and workflow-version messages name `sdd-routing` and its install (`uv tool install` line from `uv-tools.txt`), never `~/dotfiles`; red against the moved text, which says "dotfiles"

### Implementation

- [ ] T008 [N] [US1] `vendor/sync.sh`, `vendor/SOURCES`; run it once against dotfiles `main` for `check.sh`, `checks/lib/{runner,declarations,fixtures}.sh`, `githooks/pre-commit`, `checks/07-declarations.sh`, `claude/config-guard.sh`; T005 green; break by hand (one byte in `check.sh`; delete a SOURCES line) and see red
- [ ] T009 [N] [US1] `pyproject.toml` (`hatchling==1.27.0` pinned, `force-include` of `bin`, `claude`, `containers`, two console scripts) and `sdd_routing/__init__.py` (the two launchers of plan.md, nothing else); T006 green; break by hand (a launcher joining a wrong directory; one `force-include` line removed) and see red; also confirm the wheel check fails when `sdd-pass.py` loses a byte in the tracked tree after build (staleness is a non-case: the check builds from the tree it runs in)
- [ ] T010 [N] [US1] Edit `bin/sdd-run.py` messages (`TOOL_HINTS` x3, "lacks", "has") and `docs/sdd-routing.md`'s install section; T007 green; hand-break by restoring one old string
- [ ] T011 [N] [US1] `drift.sh`: move `worker_pins_latest` and `worker_pin_report` verbatim from 003's `drift.sh` (92 extracts the function with `sed`; it must pass unchanged), add "vendored files are at dotfiles `main`'s" (report only, network) with a case in `checks/00-vendor.sh` driving it against a scratch "dotfiles" (stale copy reported, current copy silent); hand-break the comparison and see red
- [ ] T012 [N] [US1] `checks/05-lint.sh` (shellcheck, shfmt, actionlint, zizmor, gitleaks over the new repository's files; a wrapper around tools, no logic of its own: no test), `mise.toml` + `mise.lock` (first step: `mise lock` records darwin-arm64 checksums for all five tools — if not, fall back to dotfiles' pinned-download pattern and update research R7), `.github/workflows/ci.yml` (macOS runner, pinned action SHAs, `contents: read`, job `check`, installs the tools and `specify-cli`/`check-jsonschema` at the pins `uv-tools.txt` carries in dotfiles, runs `./check.sh`), `.github/dependabot.yml` (actions; npm in `containers/worker`, from 003)
- [ ] T013 [N] [US1] Close US1: ONE full `./check.sh --strict` (the commit hook is the run), under the machine lock; record the wall time in research.md "Measurements"; then a fresh-context review of the branch `001-standalone` against spec FR-001 to FR-006 and the new constitution, by an agent that did not write it, given the diff and the specs and not these notes; fix findings above LOW; no second full run
- [ ] T014 [O] [US1] Create the public repository `camilopiedra92/sdd-routing`; push `main` (the import) as the one allowed first push; push `001-standalone`; open PR 1 as a draft; apply the ruleset (`check` required) once the first CI run has registered the check name
- [ ] T015 [N] [US1] First CI run: record its duration, whether macOS minutes were billed (OQ7), and fix what only the runner shows (a tool at a different path, `lockf` absent); mark PR 1 ready only after the review of T013 and a green CI
- [ ] T016 [O] [US1] Merge PR 1 on green; tag `v0.1.0`, publish a GitHub Release (immutable if OQ5 says so); add `"camilopiedra92/sdd-routing": {"checks": ["check"]}` to dotfiles' `github/repos.json` (done in T020)

## Phase 4: User Story 2 - dotfiles installs the harness at a pin (P2)

**Goal**: scratch-HOME `install.sh` puts a working `sdd-run` on `PATH` from the tag; `drift.sh` sees it.

### Tests first

- [ ] T017 [D] [US2] Test first, `checks/76-sdd-routing-wiring.sh` (`# covers: install.sh drift.sh uv-tools.txt Brewfile`): against stubs (`container`, `uv`, `sdd-run`, `git`), (a) install.sh's kernel step starts the runtime once when the kernel file is absent and not at all when present (second run changes nothing, constitution IV), (b) drift's "sdd-run answers" report is silent for exit 2 + `usage: sdd-run ` and names the command for a missing command, for exit 0, and for no `usage:` line, (c) "installed commit equals the tag's" is silent when the receipt's commit equals `git ls-remote`'s and names both otherwise, and says it could not ask when `ls-remote` fails, (d) `uv-tools.txt` has a pinned `sdd-routing` line (the existing section 20 check "declares a pinned reference per tool" already requires a reference; this asserts presence). Red now: no step, no reports
- [ ] T018 [D] [US2] Observation, not a test: the kernel step has no check in 003 (its diff added links and asserts only); record in research.md that T017(a) is the first one

### Implementation

- [ ] T019 [D] [US2] `install.sh` step 6b (kernel; comment cites R8 and 003's R5), `Brewfile` `brew "container"` (comment from 003), `drift.sh` kernel report and the two new reports; T017 green; hand-break each (kernel test inverted; usage match removed; ls-remote comparison inverted) and see red
- [ ] T020 [D] [US2] `uv-tools.txt`: `check-jsonschema` (with 003's comment) and `sdd-routing  git+https://github.com/camilopiedra92/sdd-routing.git@v0.1.0` (comment: why a uv tool and not a clone, R3); `github/repos.json`; `README.md` link to the new repository; `docs/maintenance.md` (how to move the pin); `docs/decisions/0001-sdd-routing-lives-in-its-own-repository.md` in MADR shape (context: spec's numbers; options: R3 a/b/c, R5, R6; outcome and consequences), linked from CLAUDE.md "Commands/Invariants" area as decisions later work builds on
- [ ] T021 [D] [US2] Proof on a scratch `HOME` (not the suite): run install.sh's uv step against the real tag (`UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` scratch), then `sdd-run` (exit 2, usage) and `drift.sh`'s two reports; paste outputs in research.md "Measurements"; run the new repo's 96 end-to-end case against the installed tree if the section can take a root parameter, else note that SC-004 waits for T024
- [ ] T022 [D] [US2] Close US2: ONE full `./check.sh --strict` (the commit hook); record its time (SC-001 input); fresh-context review of the dotfiles diff against FR-007, FR-008 and constitution I-VI; open the PR as draft, mark ready after the review; merge with `gh pr merge --auto --squash` only on green for that commit

## Phase 5: User Story 3 - The old home is closed and its work follows (P3)

- [ ] T023 [O] [US3] Run `./install.sh` on the machine; check `./drift.sh` for the new reports
- [ ] T024 [O] [US3] A real routed run from the installed `sdd-run` in a throwaway repository (real `container`, real tokens): the evidence for SC-004 and the closing of the move; if it fails, the failure is a bug in the new repository (fix there) or in the wheel (R3's exit criteria), not a reason to restore the old layout
- [ ] T025 [O] [US3] Close PR #155 with a comment linking the new repository, the tag and `specs/008-extract-sdd-routing/`; tag the branch tip `archive/003-sdd-model-routing`; keep the branch 30 days (do not delete); do not close before T024
- [ ] T026 [N] [US3] In the new repository: its `tasks.md` of 003 gets a header note that it moved on 2026-10-23, T049-T051 continue (T050's `sdd-init.sh` part per OQ4), T054 (decisions out of research.md) is written against the new repository's `docs/decisions/`, T052-T053 point at the released tag; story-workers repository's T052 text is updated by its owner when he starts it
- [ ] T027 [D] [US3] After the merge: measure SC-001 (three `./check.sh` runs and the CI duration of the merge commit), record in research.md "Measurements"; correct any statement in README/CLAUDE.md/docs that is no longer true (this file's rule: in the commit that made it false)

## Phase 6: Closing

- [ ] T028 One fresh-context pass over the whole feature (not repeated): `/speckit-converge` on 008 against the merged state of both repositories until a pass finds nothing above LOW, and one independent review of both repositories' final diffs by an agent given the diffs and the specs; its tasks implemented last; record the red runs (T005, T006, T007, T017 and their hand-breaks) in the PR descriptions as the constitution asks

## Dependencies

T001 -> T002 -> T003 -> T004 -> (T005, T006, T007 in parallel) -> (T008, T009, T010, T011) -> T012 -> T013 -> T014 -> T015 -> T016 -> T017 -> T019 -> T020 -> T021 -> T022 -> T023 -> T024 -> T025 -> T026, T027 -> T028.
T017 can be written before T016 (it stubs the network); T020 needs the tag.
Nothing in dotfiles `main` changes before T022; nothing on branch 003 changes at all.
