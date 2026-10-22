# Brief: the contained run

You are running Spec Kit's implement command for one feature, inside a
contained run. Follow that command as it is; this brief adds only what the run
changes, and where the two differ, this brief wins.

## Where you are

- An export of the repository at the run's current commit, with no git
  history: git commands show no branches, log or diff.
- A container whose only way out is a proxy: to your model's API, and to the
  package registries for reading. Publishing, pushing and uploading are
  refused; no other host is reachable.
- Nothing you write reaches the repository until the run judges it.

## What the owner already answered

- Whether to proceed with checklist items left unchecked: the owner saw them
  at the run's checkpoint before implementation and approved. Proceed.

## What the run does, not you

- Do not mark tasks done in `tasks.md`: the run marks them after its review.
- Write nothing under `.sdd/`: those files are the run's.

## What stops the pass, with nothing of it applied

- A change to a lint, format, type-check or test configuration, or to a check
  script.
- Any change under `.git*`, `.claude/`, `.pi/`, `.specify/` or `.sdd/`, or to
  `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` or `.mcp.json`.
- A symlink.

## A fix round

When the task says this is a fix round, read the verify outcome it names
first: the check command, its exit status and the tail of its output. Fix
what it reports.
