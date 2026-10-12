# Research: The commit gate judges the commit

## R1. What the checks run against

- **Decision**: a judging tree built per commit in a `mktemp -d` directory: a
  fresh repository whose `objects/info/alternates` points at this
  repository's object store, whose `HEAD` is the commit's parent (left unborn
  for a first commit), whose index is a copy of the index git hands the hook,
  and whose files come from `git checkout-index -a -u` of that index.
- **Rationale**: the checks see exactly what is being committed, with the
  history and the staged diff gitleaks reads (`gitleaks git` walks `git log`;
  `--staged` diffs the index against `HEAD`). Nothing is written to this
  repository: the alternates link only reads its objects. The spike
  (2026-10-12, git 2.56) observed the commit judged in both directions —
  staged-bad/working-clean refused, staged-good/working-bad passed — at the
  same 31-35 s as today's gate.
- **Alternatives**:
  - `git worktree add --detach` from `HEAD`: the spike's first form, and it
    works, but it registers an admin directory under this repository's
    `.git/worktrees`, and a first commit has no `HEAD` to start from
    (`--orphan` needs git 2.42). Lost: it writes into the repository and needs
    two paths.
  - Stash the unstaged changes, judge the working tree, restore (the
    pre-commit framework's way): lost because it rewrites the working tree —
    an interruption or a conflicting restore can lose work, and every touched
    file's modification time changes.
  - `checkout-index` into a plain directory: lost because the checks that ask
    git (`ls-files`, `grep`, gitleaks) need a repository.

## R2. Git's environment in the hook

- **Decision**: the hook resolves the index path (`GIT_INDEX_FILE`, relative
  to the top level for a plain commit, absolute otherwise; `git rev-parse
  --git-path index` when unset), the object store (`--git-common-dir`) and
  the parent (`rev-parse -q --verify HEAD`), then unsets every `GIT_`
  variable before any git call on the judging tree.
- **Rationale**: with `GIT_INDEX_FILE` still set, `git -C <tree>
  checkout-index -u` would write stat data into the user's index, and a
  linked worktree's `GIT_DIR` would send the tree's calls to this repository
  (the hazard `check.sh`'s `drop_hook_git_env` already documents).

## R3. Cleanup

- **Decision**: one `trap` on `EXIT` removes the tree. No trap on `INT`,
  `TERM` or `HUP`: bash runs the EXIT trap when killed by a TERM it does not
  trap (seen with /bin/bash 3.2.57, the only bash on this machine,
  2026-10-12), and a hook with an extra `trap 'exit 130' INT TERM HUP` and
  one without left the same result in the interrupted case — so the extra
  trap changed nothing. The tree's own config sets `core.fsmonitor false`.
- **Rationale**: FR-003. The fsmonitor setting keeps the global
  `core.fsmonitor = true` from starting a daemon for a directory that lives
  for one commit (git/config's own warning about scratch repositories).

## R4. What the change orphans

- **Decision**: remove `THIS_INDEX` and `this_repo_git` from `check.sh`, the
  two callers go back to plain `git`, and the parts of the english-only and
  git-guard checks that tested reading the commit's index from the working
  tree go too. `drop_hook_git_env` stays: `check.sh` can still be started
  with git's variables set (by hand inside another hook, by `git rebase
  -x`), and the throwaway repositories the checks build must not inherit
  them.
- **Rationale**: inside the judging tree the default index is the commit's,
  so the indirection always resolves to plain `git` — code that can no
  longer change an outcome (FR-004, and the global rule that what a change
  orphans, it removes).

## R5. How the gate is checked

- **Decision**: rework `pre_commit_gate` in `checks/15-githooks.sh`: the stub
  `check.sh` is committed in the scratch repository (the judging tree holds
  only indexed files), fails when a tracked file `verdict` says `bad`, logs
  its canonical directory and arguments, and prints a marker. Cases: each
  acceptance scenario of US1 (including `commit -a`, `commit <paths>` and a
  linked worktree), US2's snapshot of contents, modification times,
  untracked files, the stash list and the index before and after a passing
  and a refused run, the judging tree gone after each run, and an
  interrupted run (the stub sends `TERM` to the hook) cleaned up too. The
  existing cases (strict, exit codes 1 and 2, output shown, bypass hint,
  nothing added on a pass, missing `check.sh`) stay.
