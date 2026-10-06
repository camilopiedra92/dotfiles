#!/usr/bin/env bash
# Puts an edit to a lint, format or test config to the user before it lands.
#
# Changing the config is the cheapest way to turn a red check green without
# fixing anything: drop a rule from `select`, add a path to an ignore file, set
# `strict` to false. The global CLAUDE.md already says not to, but that is an
# instruction the agent is trusted to follow; this makes the moment visible.
# It asks rather than blocks, because the edit the user asked for has to go
# through with one keypress, and a block would leave the agent to route
# around it.
#
# Two kinds of file. One whose whole content is config (eslint.config.mjs,
# ruff.toml, tsconfig.json) asks on any edit. pyproject.toml holds
# dependencies too, so it asks only when a change lands inside a [tool.<name>]
# table for one of the checkers below -- the line between them is the reason
# this is not a list of filenames: in the projects under ~/Development ruff,
# pytest and mypy live in pyproject.toml far more often than in files of their
# own. Creating a config that does not exist yet is setup, not loosening, and
# goes through.
#
# Ceiling: this sees Claude's file tools only. A config rewritten through Bash
# (`sed -i`, a heredoc, a script) never reaches it. Matching file names inside
# shell commands would read as coverage while granting little, the trap
# git-guard.sh documents for permission rules; if a session is seen doing
# that, it is a reason to rethink, not to add patterns.
#
# Contract: the tool call arrives as JSON on stdin. The ask decision goes to
# stdout as JSON; no output and exit 0 means no opinion. Anything it cannot
# read -- bad JSON, an unreadable file, no python3 -- gets no decision, so a
# crashed guard fails open to the permission rules, like git-guard.sh.

# Python for the TOML tables and the edit simulation; -I so nothing in the
# project directory (a stray json.py) is imported. Standard library only, and
# nothing newer than the 3.9 macOS ships, since PATH decides which python3
# runs.
exec python3 -I -c '
import difflib
import json
import os
import re
import sys

WHOLE_FILE = re.compile(
    r"^("
    r"eslint\.config\.[cm]?[jt]s|\.eslintrc(\..+)?|\.eslintignore"
    r"|prettier\.config\.[cm]?[jt]s|\.prettierrc(\..+)?|\.prettierignore"
    r"|\.?ruff\.toml|\.flake8|\.?mypy\.ini|pytest\.ini"
    r"|tsconfig(\..+)?\.json|vitest\.config\.[cm]?[jt]s"
    r"|\.pre-commit-config\.yaml|\.editorconfig"
    r")$"
)

# The pyproject tables seen in those projects that configure a checker.
CHECKER_TABLES = ("ruff", "mypy", "pytest", "mutmut", "importlinter")
HEADER = re.compile(r"^\s*\[\[?\s*([^\]]+?)\s*\]\]?")
CHECKER = re.compile(r"^\s*tool\.(%s)(\.|\s*=|$)" % "|".join(CHECKER_TABLES))


def ask(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def after_edit(text, tool_input):
    """The file as the edit would leave it, or None if it would not apply."""
    old = tool_input.get("old_string", "")
    if not old or old not in text:
        return None
    new = tool_input.get("new_string", "")
    if tool_input.get("replace_all"):
        return text.replace(old, new)
    return text.replace(old, new, 1)


def tables(lines):
    """The table each line belongs to; a header line belongs to its own."""
    current, out = "", []
    for line in lines:
        m = HEADER.match(line)
        if m:
            current = re.sub(r"[\"\x27\s]", "", m.group(1))
        out.append(current)
    return out


def touched_checker_table(before, after):
    old, new = before.splitlines(), after.splitlines()
    old_t, new_t = tables(old), tables(new)
    hits = set()
    matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
    for op, i1, i2, j1, j2 in matcher.get_opcodes():
        if op == "equal":
            continue
        changed = [(old_t[i], old[i]) for i in range(i1, i2)] + [(new_t[j], new[j]) for j in range(j1, j2)]
        # A line outside any table names its own: tool.ruff.line-length = 100.
        names = [table or line for table, line in changed]
        for name in names:
            m = CHECKER.match(name)
            if m:
                hits.add(m.group(1))
    return sorted(hits)


try:
    payload = json.load(sys.stdin)
    tool, tool_input = payload["tool_name"], payload["tool_input"]
    path = tool_input["file_path"]
except (ValueError, KeyError, TypeError):
    sys.exit(0)

if tool not in ("Edit", "Write") or not os.path.isfile(path):
    sys.exit(0)

name = os.path.basename(path).lower()
if WHOLE_FILE.match(name):
    ask("%s configures a linter, formatter or test runner. Changing it can make "
        "a check pass without fixing the code. Approve only if this change was "
        "asked for." % os.path.basename(path))

if name != "pyproject.toml":
    sys.exit(0)

try:
    with open(path, encoding="utf-8") as handle:
        before = handle.read()
except (OSError, ValueError):
    sys.exit(0)

after = tool_input.get("content", "") if tool == "Write" else after_edit(before, tool_input)
if after is None:
    sys.exit(0)

hits = touched_checker_table(before, after)
if hits:
    ask("This changes the [tool.%s] configuration in pyproject.toml. Changing it "
        "can make a check pass without fixing the code. Approve only if this "
        "change was asked for." % ", tool.".join(hits))
' "$@"
