# dotfiles

This Mac's development environment as code: manifests, `install.sh` to apply
them, and the checks that keep both honest. `claude/CLAUDE.md` here is the
global instructions file linked into `~/.claude/`, not this project's.

## Commands

- `./check.sh` — the checks, all sections; CI runs it. The pre-commit hook runs
  `./check.sh --strict --staged`: the sections the staged files select
  (`docs/checks.md`, "Tiers").
- `./drift.sh` — what this machine has that the manifests do not say, and the
  reverse. Local only: a CI runner has packages of its own.

## Invariants

@.specify/memory/constitution.md

---

When something here stops being true, correct it in the same commit that made
it false. Nothing here repeats the global instructions or the constitution.
Keep this file under 200 lines.
