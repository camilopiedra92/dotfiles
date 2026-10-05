#!/usr/bin/env bash
# Puts the current repository's test suite behind a Claude Code Stop hook, as
# one commit of its own: a turn that ends on a red suite is blocked once, with
# the failure, so Claude has been shown it before the turn can end.
#
# Usage:  sdd-gate <test command> [args...]     from the repository root,
#         e.g. sdd-gate uv run pytest -q        once the project has a suite
#
# Why a hook: test-first otherwise rests on instructions and on the per-story
# review, and the Claude Code docs say an unattended run needs a deterministic
# gate (code.claude.com/docs/en/best-practices, "Give Claude a way to verify
# its work"). Observed on Claude Code 2.1.290: a Stop hook fires and blocks
# under `claude -p` too, and the next stop of that turn arrives with
# stop_hook_active true.
#
# The hook blocks once per turn and lets the next stop through. A gate with no
# way out is the pressure under which agents edit tests to pass (ImpossibleBench,
# arXiv 2510.20270); with one, a test that cannot pass honestly gets reported.
# The hook is written into the repository rather than pointing here, so every
# clone, on any machine, runs the same gate.
set -euo pipefail

[ "$#" -gt 0 ] || {
  echo "usage: sdd-gate <test command> [args...]" >&2
  exit 1
}
top=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "sdd-gate: not inside a git repository" >&2
  exit 1
}
if [ "$top" != "$(pwd -P)" ]; then
  echo "sdd-gate: run it from the repository root, $top" >&2
  exit 1
fi
hook=.claude/hooks/stop-gate.sh
settings=.claude/settings.json
if [ -e "$hook" ]; then
  echo "sdd-gate: $hook already exists; edit its TEST_COMMAND to change the command" >&2
  exit 1
fi
if ! git diff --cached --quiet; then
  echo "sdd-gate: something is already staged, and it would land in this commit" >&2
  exit 1
fi
# The commit takes settings.json whole, so anything uncommitted in it would
# ride along under this commit's message.
if [ -e "$settings" ] && ! git ls-files --error-unmatch "$settings" > /dev/null 2>&1; then
  echo "sdd-gate: $settings is not committed; commit or remove it first" >&2
  exit 1
fi
if ! git diff --quiet -- "$settings"; then
  echo "sdd-gate: $settings has uncommitted changes; commit or discard them first" >&2
  exit 1
fi
# One path per call: check-ignore takes --quiet with a single pathname only.
if git check-ignore -q "$hook" || git check-ignore -q "$settings"; then
  echo "sdd-gate: .gitignore ignores $hook or $settings, so the gate could not be committed" >&2
  exit 1
fi
# Read and merged before anything is written: an unreadable settings.json
# stops here, with nothing to undo. jq rewrites the file in its own layout.
# shellcheck disable=SC2016  # $CLAUDE_PROJECT_DIR is expanded by Claude Code, not here
entry='{"hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop-gate.sh", "timeout": 600}]}'
if [ -e "$settings" ]; then
  merged=$(jq --argjson entry "$entry" '.hooks.Stop += [$entry]' "$settings") || {
    echo "sdd-gate: $settings is not valid JSON" >&2
    exit 1
  }
else
  merged=$(jq -n --argjson entry "$entry" \
    '{"$schema": "https://json.schemastore.org/claude-code-settings.json", hooks: {Stop: [$entry]}}')
fi
# The hook blocks every turn whose suite is red, so a suite that is red today
# would block every turn from the first one.
if ! out=$("$@" 2>&1); then
  printf '%s\n' "$out" | tail -n 20 >&2
  echo "sdd-gate: the suite is red; make it green before gating on it" >&2
  exit 1
fi

# From here on a failure (a held index lock, a commit hook that refuses) puts
# the repository back as it was, so the next run is not refused by a hook file
# this one left behind.
committed=0
undo() {
  [ "$committed" -eq 1 ] && return
  git reset -q -- "$hook" "$settings" 2> /dev/null || true
  rm -f "$hook"
  rmdir .claude/hooks 2> /dev/null || true
  if git ls-files --error-unmatch "$settings" > /dev/null 2>&1; then
    git checkout -q -- "$settings"
  else
    rm -f "$settings"
  fi
}
trap undo EXIT

mkdir -p .claude/hooks
{
  cat << 'EOF'
#!/usr/bin/env bash
# Claude Code Stop hook written by sdd-gate (github.com/camilopiedra92/dotfiles,
# bin/sdd-gate.sh), which explains the design. When the suite is red, the first
# stop of a turn is blocked with the failure and the next stop goes through, so
# Claude is shown the failure and a test that cannot pass honestly gets
# reported instead of forced green.
set -uo pipefail

EOF
  printf 'TEST_COMMAND=(%s)\n' "$(printf '%q ' "$@" | sed 's/ $//')"
  cat << 'EOF'

cd "${CLAUDE_PROJECT_DIR:?}" || exit 0
grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0

# The tree as `git add -A` would see it, untracked files included, written
# through a scratch index. When it matches the last green run there is nothing
# new to test. It cannot see an ignored file, inside a submodule (only the
# submodule's commit), or past a skip-worktree or assume-unchanged entry: a
# change only to an ignored file does not re-run the suite, and a repository
# with either of the others is never skipped.
gitdir=$(git rev-parse --absolute-git-dir 2> /dev/null) || gitdir=
tree=
if [ -n "$gitdir" ] && [ -z "$(git ls-files -s | awk '$1 == 160000')" ] &&
  ! git ls-files -v | grep -qE '^([a-z]|S) '; then
  index=$(mktemp)
  trap 'rm -f "$index"' EXIT
  cp "$gitdir/index" "$index" 2> /dev/null || rm -f "$index"
  tree=$(GIT_INDEX_FILE=$index git add -A 2> /dev/null &&
    GIT_INDEX_FILE=$index git write-tree 2> /dev/null) || tree=
fi
stamp=$gitdir/stop-gate-green
if [ -n "$tree" ] && [ "$(cat "$stamp" 2> /dev/null)" = "$tree" ]; then
  exit 0
fi

if out=$("${TEST_COMMAND[@]}" 2>&1); then
  [ -z "$tree" ] || printf '%s\n' "$tree" > "$stamp"
  exit 0
fi
{
  echo "Stop gate: the test suite is red (${TEST_COMMAND[*]})."
  printf '%s\n' "$out" | tail -n 40
  echo "Make it green by fixing the code. If a test is what is wrong, or cannot"
  echo "pass without contradicting the spec, say which test and why in your final"
  echo "message instead of changing it to pass."
} >&2
exit 2
EOF
} > "$hook"
chmod +x "$hook"
printf '%s\n' "$merged" > "$settings"

git add "$hook" "$settings"
git commit -q -m "Gate the end of every Claude turn on the test suite" \
  -m "Written by sdd-gate: a Stop hook runs \`$*\` and blocks a red turn once."
committed=1
echo "sdd-gate: committed $hook and $settings"
