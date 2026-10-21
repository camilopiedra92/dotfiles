#!/usr/bin/env bash
# The steps of the sdd-routed Spec Kit workflow (contracts/sdd-step.md in
# specs/003-sdd-model-routing): each `shell` step of the workflow calls one
# subcommand, from the repository root.
#
# Usage:  sdd-step outcome <clarify|verify|review|converge>
#         sdd-step agent <phase>
#         sdd-step implement
#         sdd-step verify
#         sdd-step prepare-worker | egress-proxy | cleanup [<run_id>]
#
# Every subcommand runs inside a run: SDD_RUN_DIR names its bundle, and every
# host tool is found there or at a fixed system path, never through the PATH
# or the working directory the workflow gave it (contracts/pass.md).
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

[ -n "${SDD_RUN_DIR:-}" ] && [ -f "$SDD_RUN_DIR/tools.json" ] || die "SDD_RUN_DIR names no run bundle; run through sdd-run"
REPO=$(pwd -P)
# From here on, nothing the repository or the caller's PATH holds is found by
# name: a mise.toml or .envrc in the worktree configures nothing (T005).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
PY=/usr/bin/python3

tool() {
  "$PY" -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$SDD_RUN_DIR/tools.json" "$1" 2> /dev/null ||
    die "tools.json names no $1"
}

# The feature directory Spec Kit's own scripts use, from .specify/feature.json,
# accepted only in the shape create-new-feature.sh writes, so a planted path
# cannot point a step outside specs/.
feature_dir() {
  local dir
  [ -f .specify/feature.json ] || die "no .specify/feature.json; run from the repository root of a feature"
  dir=$("$PY" -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["feature_directory"])' \
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
  # As every host step: from the bundle, with no environment of the caller's.
  (cd "$SDD_RUN_DIR" && /usr/bin/env -i HOME="$HOME" PATH="$PATH" "$(tool check-jsonschema)" \
    --schemafile "$SCHEMAS/$step.schema.json" "$REPO/$file" > /dev/null 2>&1) ||
    die "outcome $step: $file does not match $step.schema.json"
  "$PY" -I - "$step" "$file" << 'PY'
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
  agent | implement | verify | prepare-worker | egress-proxy | cleanup)
    # The pass starts in the bundle's directory, with no environment but what
    # it sets itself.
    cd "$SDD_RUN_DIR" || die "cannot enter $SDD_RUN_DIR"
    exec /usr/bin/env -i HOME="$HOME" "$PY" -I "$DOTFILES/bin/sdd-pass.py" "$@" "$REPO"
    ;;
  *) die "usage: sdd-step <outcome|agent|implement|verify|prepare-worker|egress-proxy|cleanup> ..." ;;
esac
