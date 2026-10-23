#!/usr/bin/env bash
# Puts Spec Kit into the current repository with the constitution-authoring
# and story-workers presets, Spec Kit's pi integration and the routed workflow
# (specs/003-sdd-model-routing), as one commit of its own.
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
# <newer tag's zip>`, then a commit. The URLs below are the versions new repos get.
# story-workers appends to core speckit-implement: each phase to
# a Sonnet worker, the main session verifying; released on the owner's
# acceptance, not on a measured saving (its README, "The owner's decision").
set -euo pipefail

# The routed workflow is this repository's copy, resolved from the script's own
# place so a link in ~/.local/bin finds it. Spec Kit's pi integration is what
# the DeepSeek pass runs as /speckit.implement (research R27); it is installed
# for every repository, opted in or not, so the opt-in is one git config.
self=$(realpath "${BASH_SOURCE[0]}")
workflow=$(dirname "$(dirname "$self")")/claude/speckit/sdd-routed.yml

PRESET_CONSTITUTION_AUTHORING_URL=https://github.com/camilopiedra92/spec-kit-preset-constitution-authoring/archive/refs/tags/v1.2.1.zip
PRESET_STORY_WORKERS_URL=https://github.com/camilopiedra92/spec-kit-preset-story-workers/archive/refs/tags/v0.2.0.zip
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
  # The workflow is added the same way to install and to bring up to date
  # (a second add over an installed one installs it again: specify 1.2.2,
  # 2026-10-22). pi's integration has its own upgrade once installed.
  echo "          specify workflow add $workflow" >&2
  if [ -d .pi ]; then
    echo "          specify integration upgrade pi" >&2
  else
    echo "          specify integration install pi" >&2
  fi
  # Committed, as init's own files are: from story-workers v0.2.0, a change left
  # uncommitted outside the feature directory sends the next run to core.
  echo '          git add .specify .claude/skills .pi && git commit -m "Update Spec Kit presets"' >&2
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
specify integration install pi
specify workflow add "$workflow"

# Only what init and the presets wrote. .claude/skills/ is committed whatever
# init's closing advice says about .claude/: that advice is about credentials,
# and the skills are what makes the workflow the same on every checkout.
git add .specify .claude/skills .pi
git commit -q -m "Initialize Spec Kit with the constitution-authoring and story-workers presets, pi and the routed workflow"
echo "sdd-init: committed. Next: /speckit-constitution"
# Off until the owner says so, per repository: the code the DeepSeek pass reads
# is sent to DeepSeek (spec US3 AS3).
echo "sdd-init: implementation runs on Sonnet. To implement on DeepSeek instead, whose terms"
echo "          of service and privacy policy then apply to the code it reads (DeepSeek's terms):"
echo "          git config --local sdd.implement deepseek"
