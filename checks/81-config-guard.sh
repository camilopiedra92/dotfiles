# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: claude/config-guard.sh claude/settings.json install.sh

# ── Config guard ─────────────────────────────────────────────────────────────
# Changing a lint, format or test config is the cheapest way to turn a red
# check green without fixing anything, so an edit to one is put to the user
# instead of being taken on the agent's word. Asked, never blocked: the edit
# the user asked for has to go through with one keypress.
#
# A pure function from a payload and the file on disk to a verdict, like the
# git guard: `ask` when it prints the ask decision, `none` when it prints
# nothing and exits 0. Anything else -- a crash, a block -- is reported as
# such, so a guard that dies on every input cannot read as one that allowed.
printf '\n%sConfig guard%s\n' "$DIM" "$OFF"

CONFIG_GUARD=$PWD/claude/config-guard.sh

config_verdict() { # config_verdict <payload json>
  local out rc
  out=$(printf '%s' "$1" | "$CONFIG_GUARD" 2> /dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'exit %s' "$rc"
  elif [ -z "$out" ]; then
    printf 'none'
  elif [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2> /dev/null)" = ask ]; then
    printf 'ask'
  else
    printf 'unexpected output: %s' "$out"
  fi
}

# Every row is a tool call against the fixture tree below: the verdict, the
# tool, the file relative to the tree, then the tool's own arguments as JSON.
# Simplest first. The pyproject rows are the reason this is not a list of
# filenames: in the projects under ~/Development, ruff, pytest and mypy are
# configured inside pyproject.toml far more often than in files of their own
# (counted 2026-10-06: [tool.ruff] 14, [tool.pytest] 14, [tool.mypy] 7, one
# ruff.toml), so only the table a change lands in can tell a loosened rule
# from a new dependency.
config_guard_decisions() {
  local tmp want tool file args payload got fails=0
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/src" "$tmp/web"
  echo 'print(1)' > "$tmp/src/app.py"
  for f in eslint.config.mjs .prettierrc.json .prettierignore ruff.toml .flake8 mypy.ini \
    pytest.ini tsconfig.json .pre-commit-config.yaml .editorconfig; do
    echo 'x = 1' > "$tmp/$f"
  done
  echo 'x = 1' > "$tmp/web/tsconfig.app.json"
  echo 'x = 1' > "$tmp/web/vitest.config.mts"
  echo 'x = 1' > "$tmp/web/ESLINT.CONFIG.JS"
  cat > "$tmp/pyproject.toml" << 'TOML'
[project]
name = "demo"
dependencies = ["httpx"]

[tool.ruff.lint]
select = ["E", "F"]

[tool.pytest.ini_options]
addopts = "-q"

[tool.uv]
dev-dependencies = ["pytest"]
TOML
  # Ends on a checker table, so a table appended after it starts with a blank
  # line that diffs inside that table.
  mkdir -p "$tmp/tail" "$tmp/odd"
  printf '[project]\nname = "tail"\n\n[tool.pytest.ini_options]\naddopts = "-q"\n' > "$tmp/tail/pyproject.toml"
  # Valid TOML spelled the less common ways: a top-level dotted key, spaces
  # inside the brackets, an indented header, a quoted key, an array whose
  # elements are arrays, and one value in two tables for replace_all.
  cat > "$tmp/odd/pyproject.toml" << 'TOML'
tool.mypy = { strict = true }

[project]
name = "odd"
flag = 1

  [ tool.ruff ]
flag = 1
extend-select = [
["E"],
]
ignore = []

[tool."pytest".ini_options]
addopts = "-q"
TOML
  while IFS='|' read -r want tool file args; do
    [ -z "$want" ] && continue
    payload=$(jq -cn --arg tool "$tool" --arg path "$tmp/$file" --argjson args "$args" \
      '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: ({file_path: $path} + $args)}')
    got=$(cd "$tmp" && config_verdict "$payload")
    if [ "$got" != "$want" ]; then
      printf 'want %s, got %s: %s %s %s\n' "$want" "$got" "$tool" "$file" "$args"
      fails=1
    fi
  done << 'CASES'
none|Write|src/app.py|{"content": "print(2)"}
ask|Edit|eslint.config.mjs|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Write|eslint.config.js|{"content": "export default []"}
ask|Write|tests/ruff.toml|{"content": "lint.select = []"}
ask|Write|.prettierrc.json|{"content": "{}"}
ask|Edit|.prettierignore|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|ruff.toml|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|.flake8|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|mypy.ini|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|pytest.ini|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|tsconfig.json|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|web/tsconfig.app.json|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|web/vitest.config.mts|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|.pre-commit-config.yaml|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|.editorconfig|{"old_string": "x = 1", "new_string": "x = 2"}
ask|Edit|web/ESLINT.CONFIG.JS|{"old_string": "x = 1", "new_string": "x = 2"}
none|Edit|pyproject.toml|{"old_string": "[\"httpx\"]", "new_string": "[\"httpx\", \"rich\"]"}
ask|Edit|pyproject.toml|{"old_string": "select = [\"E\", \"F\"]", "new_string": "select = [\"E\"]"}
ask|Edit|pyproject.toml|{"old_string": "addopts = \"-q\"", "new_string": "addopts = \"-q --deselect tests/test_a.py\""}
none|Edit|pyproject.toml|{"old_string": "dev-dependencies = [\"pytest\"]", "new_string": "dev-dependencies = [\"pytest\", \"ruff\"]"}
ask|Edit|pyproject.toml|{"old_string": "dev-dependencies = [\"pytest\"]", "new_string": "dev-dependencies = [\"pytest\"]\n\n[tool.mypy]\nignore_errors = true"}
ask|Edit|pyproject.toml|{"old_string": "[tool.ruff.lint]\nselect = [\"E\", \"F\"]\n\n", "new_string": ""}
none|Write|pyproject.toml|{"content": "[project]\nname = \"demo\"\ndependencies = [\"httpx\", \"rich\"]\n\n[tool.ruff.lint]\nselect = [\"E\", \"F\"]\n\n[tool.pytest.ini_options]\naddopts = \"-q\"\n\n[tool.uv]\ndev-dependencies = [\"pytest\"]\n"}
ask|Write|pyproject.toml|{"content": "[project]\nname = \"demo\"\ndependencies = [\"httpx\"]\n\n[tool.uv]\ndev-dependencies = [\"pytest\"]\n"}
ask|Edit|pyproject.toml|{"old_string": "[project]", "new_string": "tool.ruff.lint.ignore = [\"E501\"]\n\n[project]"}
none|Edit|pyproject.toml|{"old_string": "not in the file", "new_string": "x"}
ask|Write|src/pyproject.toml|{"content": "[tool.ruff]\nlint.select = []\n"}
ask|Write|fmt/pyproject.toml|{"content": "[tool.black]\nline-length = 200\n"}
ask|Write|fmt/pyproject.toml|{"content": "[tool.isort]\nskip_glob = [\"*\"]\n"}
none|Write|pkg/pyproject.toml|{"content": "[project]\nname = \"pkg\"\n"}
none|Edit|tail/pyproject.toml|{"old_string": "addopts = \"-q\"\n", "new_string": "addopts = \"-q\"\n\n[tool.hatch.build]\nx = 1\n"}
none|Edit|pyproject.toml|{"old_string": "select = [\"E\", \"F\"]", "new_string": "# keep in sync with CI\nselect = [\"E\", \"F\"]"}
ask|Edit|odd/pyproject.toml|{"old_string": "strict = true", "new_string": "strict = false"}
ask|Edit|odd/pyproject.toml|{"old_string": "ignore = []", "new_string": "ignore = [\"F\"]"}
ask|Edit|odd/pyproject.toml|{"old_string": "addopts = \"-q\"", "new_string": "addopts = \"-q -x\""}
none|Edit|odd/pyproject.toml|{"old_string": "flag = 1", "new_string": "flag = 2"}
ask|Edit|odd/pyproject.toml|{"old_string": "flag = 1", "new_string": "flag = 2", "replace_all": true}
none|Read|eslint.config.mjs|{}
CASES
  return "$fails"
}
check "config guard verdicts match the table" config_guard_decisions

# Fails open, like the git guard: a payload it cannot read gets no decision,
# and the permission rules decide as if the guard were not there.
config_guard_unreadable_payload() {
  local got
  got=$(config_verdict 'not json')
  [ "$got" = none ] || {
    echo "invalid json should get no decision, got $got"
    return 1
  }
}
check "config guard gives no decision on a payload it cannot read" config_guard_unreadable_payload

# Unwired, it fails open in the quietest way there is: never running. And the
# matcher is half the wiring -- an entry on Bash would run it on calls that
# carry no file_path, and decide nothing, forever. Edit and Write are the file
# tools that change a file in place; MultiEdit is legacy (code.claude.com
# tools reference, read 2026-10-06).
config_guard_is_declared() {
  local found
  found=$(jq -r '.hooks.PreToolUse[]? | select(any(.hooks[]?; .command == "~/.claude/config-guard.sh")) | .matcher' claude/settings.json)
  [ "$found" = 'Edit|Write' ] || {
    echo "claude/settings.json should run ~/.claude/config-guard.sh on Edit|Write, found matcher: ${found:-none}"
    return 1
  }
  # shellcheck disable=SC2016  # the literal line install.sh carries
  grep -qF 'link "$DOTFILES/claude/config-guard.sh" "$HOME/.claude/config-guard.sh"' install.sh || {
    echo "install.sh does not link config-guard.sh into ~/.claude"
    return 1
  }
}
check "the config guard is wired into settings and installed" config_guard_is_declared
