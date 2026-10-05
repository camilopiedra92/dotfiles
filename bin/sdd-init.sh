#!/usr/bin/env bash
# Puts Spec Kit into the current repository with the test-first preset, as one
# commit of its own.
#
# Usage:  sdd-init        from the root of the repository, at its first feature
#
# A script rather than a paragraph in CLAUDE.md: the paragraph was advice the
# model could skip, and this sequence has a wrong order and two traps. Without
# --integration, init scaffolds for Copilot; without a TTY it refuses any
# non-empty directory unless --force (both seen on 1.1.0, 2026-10-05).
#
# The preset lives in its own repository, released by tag, and is installed
# from the tag's archive: each repo then holds a copy of a known version under
# .specify/presets/, and moving it on is `specify preset update test-first
# --from <newer tag's zip>`. The URL below is the version new repos get.
set -euo pipefail

PRESET_URL=https://github.com/camilopiedra92/spec-kit-preset-test-first/archive/refs/tags/v1.1.0.zip

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
  echo "sdd-init: .specify/ already exists; to move its preset to this version run" >&2
  echo "          specify preset update test-first --from $PRESET_URL" >&2
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
specify preset add --from "$PRESET_URL"

# Only what init and the preset wrote. .claude/skills/ is committed whatever
# init's closing advice says about .claude/: that advice is about credentials,
# and the skills are what makes the workflow the same on every checkout.
git add .specify .claude/skills
git commit -q -m "Initialize Spec Kit with the test-first preset"
echo "sdd-init: committed. Next: /speckit-constitution"
