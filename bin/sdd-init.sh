#!/usr/bin/env bash
# Puts Spec Kit into the current repository with the constitution-authoring
# and story-workers presets, as one commit of its own.
#
# Usage:  sdd-init        from the root of the repository, at its first feature
#
# A script rather than a paragraph in CLAUDE.md: the paragraph was advice the
# model could skip, and this sequence has a wrong order and two traps. Without
# --integration, init scaffolds for Copilot; without a TTY it refuses any
# non-empty directory unless --force (both seen on 1.1.0, 2026-10-05).
#
# Each preset lives in its own repository, released by tag, and is installed
# from the tag's archive: each repo then holds a copy of a known version under
# .specify/presets/, and moving one on is `specify preset update <id> --from
# <newer tag's zip>`. The URLs below are the versions new repos get.
# story-workers appends to core speckit-implement: each phase to
# a Sonnet worker, the main session verifying; released on the owner's
# acceptance, not on a measured saving (its README, "The owner's decision").
set -euo pipefail

PRESET_CONSTITUTION_AUTHORING_URL=https://github.com/camilopiedra92/spec-kit-preset-constitution-authoring/archive/refs/tags/v1.2.1.zip
PRESET_STORY_WORKERS_URL=https://github.com/camilopiedra92/spec-kit-preset-story-workers/archive/refs/tags/v0.1.0.zip
presets=("$PRESET_CONSTITUTION_AUTHORING_URL" "$PRESET_STORY_WORKERS_URL")

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
  # update for a preset the repo has, add for one it does not have yet: each
  # line is a command to paste. The id is the repository name's tail.
  echo "sdd-init: .specify/ already exists; to bring its presets to these versions run" >&2
  for url in "${presets[@]}"; do
    id=${url%/archive/*}
    id=${id##*/spec-kit-preset-}
    if [ -d ".specify/presets/$id" ]; then
      echo "          specify preset update $id --from $url" >&2
    else
      echo "          specify preset add --from $url" >&2
    fi
  done
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
for url in "${presets[@]}"; do
  specify preset add --from "$url"
done

# Only what init and the presets wrote. .claude/skills/ is committed whatever
# init's closing advice says about .claude/: that advice is about credentials,
# and the skills are what makes the workflow the same on every checkout.
git add .specify .claude/skills
git commit -q -m "Initialize Spec Kit with the constitution-authoring and story-workers presets"
echo "sdd-init: committed. Next: /speckit-constitution"
