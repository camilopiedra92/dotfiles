#!/usr/bin/env bash
# Every check this repo runs, in one place.
#
# You run it by hand, the pre-commit hook runs it, and CI runs it. That is the
# point: checks written twice drift, and the moment local and CI disagree you
# stop trusting either one. CI installs what is missing and then calls this
# file, so a green tick means exactly what a clean run here means.
#
# Usage:  ./check.sh [--strict]
#
# This repo targets macOS only, so every check here applies everywhere it runs
# and none of them are conditional on the platform.
#
# A skipped check is a hole in coverage, not a neutral outcome: the tool was
# missing, nothing ran, and the run still ends green. That is not theoretical —
# it is how this repo reported success while never once validating the Ghostty
# config. Strict mode turns a skip into a failure, so coverage cannot shrink
# without the run going red. It is on automatically under CI, which is what
# makes CI's promise ("green here means a clean run there") true by
# construction rather than by a list somebody remembers to update.
#
# Every check here is a function invoked indirectly, by name, through check().
# The linter cannot see that, and would report all of them as unused code, or
# their bodies as unreachable. Both codes are listed because which one you get
# depends on the shellcheck version: 0.11 reports SC2329, older ones SC2317.
# shellcheck disable=SC2329,SC2317
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Every CI system sets CI, so the strict path needs no wiring in the workflow
# and cannot be forgotten there. --strict reproduces it locally, which is the
# only way to test this behaviour without pushing.
STRICT=0
[ -n "${CI:-}" ] && STRICT=1
case "${1:-}" in
  "") ;;
  --strict) STRICT=1 ;;
  *)
    echo "usage: ./check.sh [--strict]" >&2
    exit 2
    ;;
esac

# Report every failure in one run rather than dying on the first. When you are
# about to commit, knowing there are three problems beats finding them one
# restart at a time.
FAILED=0
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
DIM=$'\033[90m'
OFF=$'\033[0m'

check() {
  local name=$1
  shift
  local out
  if out=$("$@" 2>&1); then
    printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$name"
  else
    printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$name"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/       /'
    FAILED=1
  fi
}

# A tool that belongs on this machine is missing, so the check never ran. On
# your laptop that is a nudge to install it; under strict it is a failure,
# because a check that did not run must never read the same as one that passed.
skip() {
  if [ "$STRICT" -eq 1 ]; then
    printf '  %sFAIL%s %s %s(not installed: %s)%s\n' "$RED" "$OFF" "$1" "$DIM" "$2" "$OFF"
    FAILED=1
  else
    printf '  %sskip%s %s %s(%s)%s\n' "$YELLOW" "$OFF" "$1" "$DIM" "$2" "$OFF"
  fi
}

# ── Lint ─────────────────────────────────────────────────────────────────────
printf '\n%sLint%s\n' "$DIM" "$OFF"

if command -v shellcheck > /dev/null 2>&1; then
  # -x follows sourced files, catching breakage across file boundaries.
  check "shellcheck" shellcheck -x install.sh check.sh claude/*.sh githooks/*
else
  skip "shellcheck" "brew install shellcheck"
fi

# shfmt reads .editorconfig, so the style lives there and not in flags here:
# the editor, this check and the hook cannot drift apart if there is only one
# definition to read.
if command -v shfmt > /dev/null 2>&1; then
  check "shfmt" shfmt -d install.sh check.sh claude/*.sh githooks/*
else
  skip "shfmt" "brew install shfmt"
fi

# The workflow was the one file here nothing checked, and a malformed one does
# not fail loudly: GitHub just declines to run it, so the symptom is checks
# that quietly stop happening. actionlint parses it, resolves runner labels and
# action inputs against what actually exists, flags untrusted `${{ }}` values
# interpolated into scripts, and runs shellcheck over every embedded `run`
# block — shell that would otherwise be linted nowhere.
if command -v actionlint > /dev/null 2>&1; then
  check "actionlint" actionlint
else
  skip "actionlint" "brew install actionlint"
fi

syntax_bash() { for f in install.sh check.sh claude/*.sh githooks/*; do bash -n "$f" || return 1; done; }
check "bash syntax" syntax_bash

if command -v zsh > /dev/null 2>&1; then
  check "zsh syntax" zsh -n zsh/.zshrc
else
  skip "zsh syntax" "zsh not installed"
fi

# ── Config files ─────────────────────────────────────────────────────────────
# These are parsed by something on a fresh machine; a typo here is only found
# while setting that machine up.
printf '\n%sConfig%s\n' "$DIM" "$OFF"

check "toml" python3 -c "
import tomllib
for f in ('starship.toml', 'mise/config.toml'):
    tomllib.load(open(f, 'rb'))
"

check "gitconfig" git config --file git/.gitconfig --list

check "claude settings" python3 -c "import json; json.load(open('claude/settings.json'))"

# VS Code settings are JSONC: comments and trailing commas are legal there and
# rejected by json.loads, so strip both before parsing.
check "vscode settings (jsonc)" python3 -c "
import json, re
s = open('vscode/settings.json').read()
s = re.sub(r'^\s*//.*$', '', s, flags=re.M)
s = re.sub(r',(\s*[}\]])', r'\1', s)
json.loads(s)
"

# Ghostty validates its own config, so this catches an option renamed between
# releases and not only a syntax error. It is the one config here with no
# startup error to read: a bad key is dropped silently and you are left
# wondering why the setting does nothing. It also resolves `theme`, so a
# mistyped theme name fails here instead of at the next launch.
if command -v ghostty > /dev/null 2>&1; then
  check "ghostty" ghostty +validate-config --config-file=ghostty/config
else
  skip "ghostty" "brew install --cask ghostty"
fi

# The repo is English-only by policy (claude/CLAUDE.md). The pattern is written
# as escapes rather than literal accented characters for a practical reason:
# spelled out, this line would match itself and the check could never pass.
# The range covers Latin-1 Supplement and Latin Extended A/B, so no English
# word trips it while Spanish prose of any length always does.
english_only() {
  ! git grep -nP '[\x{00A1}\x{00BF}\x{00C0}-\x{024F}]' -- . 2> /dev/null
}
check "english only" english_only

# ── Statusline behaviour ─────────────────────────────────────────────────────
# These are pure functions from a JSON payload to a line of text, which makes
# them the one thing here that can be tested properly.
printf '\n%sStatusline%s\n' "$DIM" "$OFF"

check "demo renders" bash -c './claude/statusline-demo.sh > /dev/null'

# A freshly opened session has no context and no limits yet. Printing a broken
# line there is worse than printing a short one.
minimal_payload() {
  local out
  out=$(echo '{"model":{"display_name":"Opus 5"},"cwd":"/tmp"}' | ./claude/statusline.sh)
  case "$out" in
    *"Opus 5"*) return 0 ;;
    *)
      echo "model missing from a minimal payload: $out"
      return 1
      ;;
  esac
}
check "minimal payload still renders the model" minimal_payload

# Garbage in must mean nothing out, never a half-rendered line: Claude prints
# whatever we emit, junk included.
invalid_json_is_silent() {
  local out
  out=$(echo 'not json' | ./claude/statusline.sh)
  [ -z "$out" ] || {
    echo "emitted output for invalid JSON: $out"
    return 1
  }
}
check "invalid json produces no output" invalid_json_is_silent

subagent_rows() {
  local payload out
  payload='{"columns":80,"tasks":[
    {"id":"a","name":"brisk-otter","type":"local_agent","status":"running",
     "startTime":1,"model":"claude-opus-5","contextWindowSize":200000,
     "tokenCount":48000,"tokenSamples":[1,2,3]},
    {"id":"b","type":"local_bash","status":"running","startTime":1,"tokenCount":0}]}'
  out=$(echo "$payload" | ./claude/subagent-statusline.sh)

  [ "$(echo "$out" | wc -l | tr -d ' ')" = 2 ] || {
    echo "expected 2 rows, got: $out"
    return 1
  }
  echo "$out" | jq -e . > /dev/null || {
    echo "not valid JSONL: $out"
    return 1
  }
  echo "$out" | jq -e 'has("id") and has("content")' > /dev/null || return 1

  # The name is the only part of the row you can address an agent by, so its
  # absence is a regression worth failing on.
  echo "$out" | head -1 | jq -e '.content | contains("brisk-otter")' > /dev/null ||
    {
      echo "agent name missing from the row"
      return 1
    }

  # A task without a name must still render, not vanish.
  echo "$out" | tail -1 | jq -e '.content | length > 0' > /dev/null ||
    {
      echo "unnamed task rendered empty"
      return 1
    }
}
check "subagent rows are valid jsonl with the agent name" subagent_rows

# ── install.sh ───────────────────────────────────────────────────────────────
# The whole promise of this repo is that install.sh rebuilds a machine. Running
# it twice against a throwaway HOME is the only way to know it still does, and
# that a second run is a no-op rather than a duplicator.
printf '\n%sInstall%s\n' "$DIM" "$OFF"

install_is_idempotent() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  # Clean up on every exit path. Previously this ran only at the end, so each
  # failed check left a directory behind.
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"

  # Only the symlink and jq-merge steps are exercised: installing Homebrew
  # packages and runtimes would take tens of minutes and is Homebrew's job to
  # get right, not this repo's.
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 3\. Symlinks/,/^# --- 4\./p' install.sh
  } > "$steps"

  # Guard against the extraction silently going empty if those markers are ever
  # renamed, which would turn this check into one that always passes. -F because
  # BSD grep reads the $ mid-pattern as an anchor and never matches.
  # shellcheck disable=SC2016  # matching that literal text, not expanding it
  grep -qF 'link "$DOTFILES/zsh/.zshrc"' "$steps" ||
    {
      echo "could not extract the symlink steps from install.sh"
      return 1
    }

  HOME="$tmp/home" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1
  HOME="$tmp/home" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1

  [ -L "$tmp/home/.zshrc" ] || {
    echo ".zshrc was not symlinked"
    return 1
  }
  [ "$(readlink "$tmp/home/.zshrc")" = "$PWD/zsh/.zshrc" ] || {
    echo ".zshrc points elsewhere"
    return 1
  }
  [ -L "$tmp/home/.claude/statusline.sh" ] || {
    echo "statusline was not symlinked"
    return 1
  }

  # The merge must leave valid JSON that kept the repo's values, not an empty
  # scaffold.
  python3 -c "
import json
s = json.load(open('$tmp/home/.claude/settings.json'))
assert s['statusLine']['command'], s
assert s['subagentStatusLine']['command'], s
" || return 1

  # A second run must not leave a backup behind: symlinks are replaced in
  # place, only real files are ever backed up.
  if ls "$tmp/home"/.zshrc.backup.* > /dev/null 2>&1; then
    echo "second run backed up a symlink it should have replaced"
    return 1
  fi

}
check "install.sh is idempotent" install_is_idempotent

# ── Result ───────────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  printf '\n%sAll checks passed%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sSome checks failed%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
