#!/usr/bin/env bash
# Puts Spec Kit into the current repository with the test-first preset from
# this repo, as one commit of its own.
#
# Usage:  sdd-init        from the root of the repository, at its first feature
#
# A script rather than a paragraph in CLAUDE.md: the paragraph was advice the
# model could skip, and this sequence has a wrong order and two traps. Without
# --integration, init scaffolds for Copilot; without a TTY it refuses any
# non-empty directory unless --force (both seen on 1.1.0, 2026-10-05).
#
# The preset is copied into the repo, not linked: `--dev` writes it under
# .specify/presets/ (seen on 1.1.0). A repo keeps the version it was given until
# `specify preset add --dev` is run there again.
set -euo pipefail

DOTFILES="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PRESET="$DOTFILES/spec-kit/preset"

top=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "sdd-init: not inside a git repository" >&2
  exit 1
}
if [ "$top" != "$(pwd -P)" ]; then
  echo "sdd-init: run it from the repository root, $top" >&2
  exit 1
fi
if [ -e .specify ]; then
  # Re-running init would put the template back over a constitution that has
  # been written. A preset update is its own command.
  echo "sdd-init: .specify/ already exists; to refresh the preset run" >&2
  echo "          specify preset add --dev $PRESET" >&2
  exit 1
fi
if ! git diff --cached --quiet; then
  echo "sdd-init: something is already staged, and it would land in this commit" >&2
  exit 1
fi
# With a preset installed, every script behind specify, plan and tasks resolves
# templates through this python and PyYAML; without it each phase fails with
# "PyYAML is required" (1.1.0). zsh/.zshenv sets it.
if ! "${SPECKIT_PYTHON_EXECUTABLE:-false}" -c 'import yaml' > /dev/null 2>&1; then
  echo "sdd-init: SPECKIT_PYTHON_EXECUTABLE is not a python with PyYAML;" >&2
  echo "          open a new shell, or see zsh/.zshenv" >&2
  exit 1
fi

specify init --here --force --integration claude
specify preset add --dev "$PRESET"

# Only what init and the preset wrote. .claude/skills/ is committed whatever
# init's closing advice says about .claude/: that advice is about credentials,
# and the skills are what makes the workflow the same on every checkout.
git add .specify .claude/skills
git commit -q -m "Initialize Spec Kit with the test-first preset"
echo "sdd-init: committed. Next: /speckit-constitution"
