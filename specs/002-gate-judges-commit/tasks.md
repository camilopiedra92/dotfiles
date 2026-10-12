# Tasks: The commit gate judges the commit

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md)

**Tests**: test tasks first; each story's checks are run once before the
code and must fail for the reason their case predicts. Each story closes with
the whole suite and a fresh-context review.

## Phase 1: Setup

- [x] T001 Confirm `./check.sh --strict` passes on the branch and time a gated commit in a scratch clone as the SC-003 baseline

## Phase 2: User Story 1 - The verdict is about the commit (P1) 🎯 MVP

- [x] T002 [US1] In `checks/15-githooks.sh`, rework `pre_commit_gate` per research R5: committed stub `check.sh` judging a tracked `verdict` file and logging its canonical directory; cases US1/AC1-AC5 (staged bad under a clean working copy refused; staged good under a bad working copy lands; an untracked bad file ignored; `commit -a` and `commit <paths>` judged on their index; a linked worktree's commit judged), keeping the strict, exit-code, output, bypass, silence and missing-`check.sh` cases, and asserting the stub ran outside the repository
- [x] T003 [US1] Run `./check.sh`; confirm the US1 cases fail against today's hook for the predicted reason (it judges the working tree)
- [x] T004 [US1] Rewrite `githooks/pre-commit` per research R1-R3: resolve the index, object store and parent; unset every `GIT_` variable; build the judging tree; run `check.sh --strict` in it; remove it on every exit path; keep the abort message
- [x] T005 [US1] Run `./check.sh`; break the hook by hand once per case and record each red run

## Phase 3: User Story 2 - The working tree is left as it was (P1)

- [x] T006 [US2] Add to `pre_commit_gate`: a snapshot of contents, modification times, untracked files, the stash list and the index checksum before and after a passing and a refused commit; the judging tree gone after each; an interrupted run (stub sends `TERM` to the hook) refused and cleaned up
- [x] T007 [US2] Run `./check.sh`; break the hook by hand (no trap, `GIT_INDEX_FILE` kept for the tree's calls, checking out into the working tree) and record each red run

## Phase 4: Orphans (FR-004)

- [x] T008 Remove `THIS_INDEX` and `this_repo_git` from `check.sh`; call `git` in `checks/10-lint.sh` and `checks/30-config.sh`; remove the commit-index parts of `english_only_contract` and of `hook_git_env_dropped` in `checks/80-git-guard.sh`; keep `drop_hook_git_env` and its check
- [x] T009 Run `./check.sh --strict`; confirm `drop_hook_git_env`'s check still goes red with the drop removed

## Phase 5: Polish

- [x] T010 Say in `docs/checks.md` that the hook judges the commit in a throwaway tree, and why
- [ ] T011 Time a gated commit against T001's baseline (SC-003)
- [ ] T012 Fresh-context review of the whole diff; then `/speckit-converge` until a pass finds nothing above LOW
