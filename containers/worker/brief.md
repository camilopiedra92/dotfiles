# Brief for the implementing agent

You implement one feature of this repository, specified with Spec Kit. You
work in an export of the repository with no git history, inside a container
whose only way out is a proxy; nothing you do reaches the repository until it
is judged. Both implementing agents get this brief, word for word.

## What to read first

- The feature directory named after this brief: `spec.md`, `plan.md`,
  `tasks.md`, and every other file the plan wrote there — `research.md`,
  `data-model.md`, `contracts/`, `quickstart.md` — when it exists.
- The constitution, `.specify/memory/constitution.md`, when it exists.
- Spec Kit's implement procedure, `.claude/skills/speckit-implement/SKILL.md`,
  when it exists: follow it, except where this brief says otherwise.
- On a fix round, the latest verify outcome, `.sdd/verify.json` in the feature
  directory, named after this brief: the check command, its exit status and
  the tail of its output.

## What to do

- Do every task in `tasks.md` not marked done, in order, and nothing else.
- Tests first: write each story's tests from its acceptance scenarios, run
  them, and see each fail for the reason its case predicts before writing the
  code that makes it pass. Then the simplest code that passes, without
  changing the tests.
- Run the repository's check command — the one you are allowed to run — before
  you finish, and leave it passing if you can.

## What not to do

- Change no lint, format, type-check or test configuration, and no check
  script: such a change stops the pass.
- Touch nothing under `.git*`, `.claude`, `.specify` or `.sdd`, and no
  `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` or `.mcp.json`: such a change
  stops the pass.
- Do not mark tasks done in `tasks.md`; the run marks them after its review.
- Write no outcome file; the run writes them.
- Do not create symlinks; do not try to reach any network host but the
  package registries.
