#!/usr/bin/env bash
# The steps of the sdd-routed Spec Kit workflow (contracts/sdd-step.md in
# specs/003-sdd-model-routing): each `shell` step of the workflow calls one
# subcommand, from the repository root.
#
# Usage:  sdd-step outcome <clarify|verify|review|converge>
#
# The workflow branches only on the fixed tokens printed here, never on an
# agent's text (FR-016): each outcome file is validated against its schema
# before a field of it is read, so a missing or malformed file fails the run
# at that step instead of steering it.
set -euo pipefail

# Linked as ~/.local/bin/sdd-step; the schemas live beside the real file.
self=$(realpath "${BASH_SOURCE[0]}")
DOTFILES=$(dirname "$(dirname "$self")")
SCHEMAS=$DOTFILES/claude/speckit/schemas

die() {
  echo "sdd-step: $*" >&2
  exit 1
}

# The feature directory Spec Kit's own scripts use, from .specify/feature.json,
# accepted only in the shape create-new-feature.sh writes, so a planted path
# cannot point a step outside specs/.
feature_dir() {
  local dir
  [ -f .specify/feature.json ] || die "no .specify/feature.json; run from the repository root of a feature"
  dir=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["feature_directory"])' \
    .specify/feature.json 2> /dev/null) || die ".specify/feature.json does not name a feature_directory"
  [[ "$dir" =~ ^specs/[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "feature directory '$dir' is not specs/<nnn>-<slug>"
  [ -d "$dir" ] || die "feature directory $dir does not exist"
  printf '%s\n' "$dir"
}

# Validates .sdd/<step>.json and prints the token its branch compares
# (data-model.md, "Outcome files").
outcome() {
  local step=${1:-} file
  case "$step" in
    clarify | verify | review | converge) ;;
    *) die "outcome: no token for '$step'; one of clarify, verify, review, converge" ;;
  esac
  file=$(feature_dir)/.sdd/$step.json
  [ -f "$file" ] || die "outcome $step: $file is missing"
  check-jsonschema --schemafile "$SCHEMAS/$step.schema.json" "$file" > /dev/null 2>&1 ||
    die "outcome $step: $file does not match $step.schema.json"
  python3 -I - "$step" "$file" << 'PY'
import json, sys

step, doc = sys.argv[1], json.load(open(sys.argv[2]))
# Above LOW is what blocks: the converge rule of the global instructions.
blocking = lambda findings: any(f["severity"] != "LOW" for f in findings)
if step == "clarify":
    print("yes" if doc["questions"] > 0 else "no")
elif step == "verify":
    print("pass" if doc["exit"] == 0 else "fail")
elif step == "review":
    print("blocking" if blocking(doc["findings"]) else "clear")
else:
    converged = doc["outcome"] == "converged" and not blocking(doc["findings"])
    print("converged" if converged else "open")
PY
}

case "${1:-}" in
  outcome)
    shift
    outcome "$@"
    ;;
  *) die "usage: sdd-step outcome <step>" ;;
esac
