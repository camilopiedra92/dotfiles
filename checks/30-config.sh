# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Config files ─────────────────────────────────────────────────────────────
# These are parsed by something on a fresh machine; a typo here is only found
# while setting that machine up.
printf '\n%sConfig%s\n' "$DIM" "$OFF"

# Parsing was never the interesting half. A TOML file can be flawless syntax and
# still be wrong in the way that actually bites: `add_newlines` for
# `add_newline` parses fine, and starship answers with a warning on stderr and
# exit 0, so the option is dropped and the prompt just quietly lacks it. That is
# the same silent-drop failure the ghostty check below exists to prevent, and
# until this used a schema it was the one config here without that cover.
#
# taplo validates against the vendored schemas wired up in .taplo.toml, so a key
# that does not exist is an error with a line and a column. It reads no network
# doing it — verified with the proxy pointed at a dead port — because online
# schema catalogs are opt-in and the schemas are referenced by path.
#
# No file list here on purpose: taplo discovers every .toml in the repo, so a
# config added later is covered by having been added, not by somebody
# remembering to extend an argument list.
#
# This replaces a python3 -c tomllib one-liner, which had a dependency it never
# declared: tomllib is stdlib only from 3.11 and macOS ships 3.9, so on the
# system interpreter that check did not skip, it FAILED with ModuleNotFoundError
# under a heading reading "toml" — pointing at the config for something that was
# the interpreter's fault. Which python answered was decided by PATH, making it
# the .zshenv failure in another coat.
#
# Formatting is checked separately, the same split as shellcheck and shfmt: one
# says the file is wrong, the other says it is untidy, and collapsing them makes
# a diff of whitespace look like a broken config. taplo's defaults are taken as
# they come rather than restated in .taplo.toml -- pinning a value that is
# already the default buys nothing today and refuses the better default
# tomorrow. The single exception is reorder_keys, declared there because it is
# not a preference that could improve; see that file.
if command -v taplo > /dev/null 2>&1; then
  check "toml" taplo lint
  check "toml format" taplo fmt --check --diff
else
  skip "toml" "brew install taplo"
  skip "toml format" "brew install taplo"
fi

check "gitconfig" git config --file git/config --list

check "claude settings" python3 -c "import json; json.load(open('claude/settings.json'))"

# Claude Code's memory docs target under 200 lines per CLAUDE.md: a longer file
# costs context in every session and lowers adherence. The global file passed
# that mark unnoticed (214 lines on 2026-10-06) while the template asked
# projects to stay under it.
claude_md_size() {
  local lines
  lines=$(wc -l < claude/CLAUDE.md)
  [ "$lines" -lt 200 ] || {
    echo "claude/CLAUDE.md has $((lines)) lines; the target is under 200."
    echo "Cut what a tool, a skill or a preset already carries before adding."
    return 1
  }
}
check "claude/CLAUDE.md stays under 200 lines" claude_md_size

# The same shape as a project's .mcp.json, checked for the two things install.sh
# relies on: a `mcpServers` object, and a `type` on every entry, because
# `claude mcp add-json` infers nothing and stores what it is given.
# The profiles' manifests are held to the same shape, and may not name a server
# the shared one already does: install.sh merges them with the profile winning,
# so a duplicate would silently replace the shared definition on one Mac.
check "claude mcp manifest" python3 -c "
import glob
import json
shared = json.load(open('claude/mcp.json'))['mcpServers']
assert isinstance(shared, dict) and shared, 'mcpServers must be a non-empty object'
manifests = {'claude/mcp.json': shared}
for path in sorted(glob.glob('macos/machines/*/mcp.json')):
    servers = json.load(open(path))['mcpServers']
    assert isinstance(servers, dict) and servers, f'{path}: mcpServers must be a non-empty object'
    clash = sorted(set(servers) & set(shared))
    assert not clash, f'{path}: also declared in claude/mcp.json: {clash}'
    manifests[path] = servers
for path, servers in manifests.items():
    for name, server in servers.items():
        assert server.get('type') in ('http', 'sse', 'stdio', 'ws'), f'{path} {name}: type missing or unknown'
        assert ('url' in server) == (server['type'] != 'stdio'), f'{path} {name}: url and type disagree'
        assert ('command' in server) == (server['type'] == 'stdio'), f'{path} {name}: command and type disagree'
"

# VS Code settings are JSONC: comments and trailing commas are legal there and
# rejected by json.loads, so strip both before parsing.
check "vscode settings (jsonc)" python3 -c "
import json, re
s = open('vscode/settings.json').read()
s = re.sub(r'^\s*//.*$', '', s, flags=re.M)
s = re.sub(r',(\s*[}\]])', r'\1', s)
json.loads(s)
"

# uv-tools.txt is read by install.sh on a machine that has nothing on it yet,
# which is the worst possible moment to find a typo in it. Nothing else would
# reject one earlier: the file is plain text, so it parses no matter what it says,
# and `uv tool install` only reports the mistake once it is being run for real.
#
# The pin rule is the point rather than a formality. A git reference without an
# `@tag` resolves to the default branch, which installs whatever was merged that
# morning and reinstalls something different tomorrow -- an unpinned line looks
# exactly like a pinned one and is the opposite of what this file is for.
uv_tools_manifest() {
  python3 - << 'PY'
import re
import sys

problems = []
seen = {}

with open('uv-tools.txt', encoding='utf-8') as handle:
    for number, line in enumerate(handle, 1):
        fields = line.split('#')[0].split()
        if not fields:
            continue
        if len(fields) != 2:
            problems.append('line %d: expected "name reference", got %d field(s)'
                            % (number, len(fields)))
            continue
        name, ref = fields
        if name in seen:
            problems.append('line %d: %s is already declared on line %d'
                            % (number, name, seen[name]))
        seen[name] = number
        if ref.startswith('git+') and not re.search(r'\.git@[^@/]+$', ref):
            problems.append('line %d: %s is not pinned -- a git reference needs '
                            'a trailing @tag' % (number, name))

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
}
check "uv-tools.txt declares a pinned reference per tool" uv_tools_manifest

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

# launchd reads the agent plist at login and reports nothing to anyone: a
# file it cannot parse is skipped, and one whose Label does not match its
# filename loads under one name and is looked up under the other, so
# install.sh's `launchctl print` never finds it and re-bootstraps on every
# run. Both are silent on the machine and loud here.
launchd_plist() {
  local plist=launchd/com.piedrac.ssh-add-keychain.plist label want
  [ -f "$plist" ] || {
    echo "$plist is missing"
    return 1
  }
  plutil -lint -s "$plist" || return 1
  label=$(plutil -extract Label raw "$plist") || return 1
  want=$(basename "$plist" .plist)
  [ "$label" = "$want" ] || {
    echo "$plist: Label is $label, the filename says $want"
    return 1
  }
}
check "launchd agent plist parses and its label matches its filename" launchd_plist

# Nerd Font glyphs need three files to agree: the Brewfile installs the font,
# ghostty/config asks for it, and vscode/settings.json asks for the same one in
# two separate keys. Every one of them is valid in isolation -- VS Code
# declaring no font at all is perfectly legal -- so no per-file check can see
# the disagreement. That is exactly how `eza --icons` came to render as empty
# boxes in the integrated terminal while looking correct in Ghostty.
#
# Two fonts installed is not better than one. When something falls back, or a
# family name is misspelled, a second Nerd Font lets it resolve to the wrong one
# and still work -- with glyphs that look subtly different and no way to tell
# why. One font makes that failure immediate.
one_nerd_font() {
  python3 - << 'PY'
import json, re, sys

problems = []


def jsonc(path):
    s = open(path).read()
    s = re.sub(r'^\s*//.*$', '', s, flags=re.M)
    s = re.sub(r',(\s*[}\]])', r'\1', s)
    return json.loads(s)


ghostty = None
for line in open('ghostty/config'):
    m = re.match(r'\s*font-family\s*=\s*"?([^"\n]+)"?', line)
    if m:
        ghostty = m.group(1).strip()

if ghostty is None:
    problems.append('ghostty/config declares no font-family')
elif 'Nerd Font' not in ghostty:
    problems.append('ghostty font-family is not a Nerd Font: %r' % ghostty)

v = jsonc('vscode/settings.json')
# The editor may list fallbacks; only the first entry is the one that renders.
editor = (v.get('editor.fontFamily') or '').split(',')[0].strip()
term = (v.get('terminal.integrated.fontFamily') or '').strip()

for key, got in (('editor.fontFamily', editor),
                 ('terminal.integrated.fontFamily', term)):
    if not got:
        problems.append('vscode/settings.json declares no %s' % key)
    elif ghostty and got != ghostty:
        problems.append('%s is %r, ghostty uses %r' % (key, got, ghostty))

# Exactly one, not at least one: see the note above this function.
casks = re.findall(r'^cask "(font-.*nerd-font)"', open('Brewfile').read(), re.M)
if len(casks) != 1:
    problems.append('Brewfile declares %d Nerd Font casks, expected 1: %s'
                    % (len(casks), ', '.join(casks) or 'none'))

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}
check "one nerd font, declared everywhere it renders" one_nerd_font

# The repo is English-only by policy (claude/CLAUDE.md). The pattern is written
# as escapes rather than literal accented characters for a practical reason:
# spelled out, this line would match itself and the check could never pass.
# The range covers Latin-1 Supplement and Latin Extended A/B, so no English
# word trips it while Spanish prose of any length always does.
#
# schemas/ is excluded because the policy is about prose written here, and none
# of it is: those files are upstream's, vendored byte-for-byte so drift.sh can
# compare them against what starship and mise publish. starship's uses a slashed
# capital O as a module symbol -- named rather than spelled for the same reason
# the pattern above is, since writing it here would trip this check. Editing the
# schema to satisfy the rule would break that comparison and the validation
# both, to police text nobody here wrote.
#
# The locale is set here because the pattern needs it: PCRE accepts code points
# above U+00FF only in UTF mode, which git turns on only under a UTF-8 locale.
# Under C the pattern is an error (measured, git 2.55: "character code point
# value in \x{} or \o{} is too large", exit 128), and a run without LANG --
# `env -i` -- is under C. C.UTF-8 rather than a language's locale, because the
# check is about bytes, not a language's rules. git grep's exit codes are kept
# apart: 0 found, 1 none, anything else an error. A leading `!` read the error
# as "none", so a Spanish file passed whenever the locale was not UTF-8.
english_only() {
  local rc=0
  LC_ALL=C.UTF-8 this_repo_git grep -nP '[\x{00A1}\x{00BF}\x{00C0}-\x{024F}]' -- . ':(exclude)schemas/' || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *)
      echo "the search exited $rc"
      return 1
      ;;
  esac
}
check "english only" english_only

# english_only against scratch repositories, under a locale without UTF-8 and
# one with it: a clean tree passes, a tree with Spanish in it fails naming the
# line, and a git grep that errors fails instead of reading as a clean tree.
# THIS_INDEX is emptied so this_repo_git reads each scratch repository's own
# index, not the one of a commit in progress.
english_only_contract() {
  local tmp out loc
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  git init -q "$tmp/repo"
  echo plain > "$tmp/repo/clean.txt"
  git -C "$tmp/repo" add clean.txt
  for loc in C C.UTF-8; do
    out=$(cd "$tmp/repo" && THIS_INDEX='' LC_ALL=$loc english_only 2>&1) || {
      echo "a clean tree failed under LC_ALL=$loc: $out"
      return 1
    }
  done
  # The bytes of a Spanish word, written as escapes so this file stays English.
  printf 'a\xc3\xb1o\n' > "$tmp/repo/spanish.txt"
  git -C "$tmp/repo" add spanish.txt
  for loc in C C.UTF-8; do
    if out=$(cd "$tmp/repo" && THIS_INDEX='' LC_ALL=$loc english_only 2>&1); then
      echo "missed spanish.txt under LC_ALL=$loc"
      return 1
    fi
    echo "$out" | grep -q '^spanish.txt:1:' || {
      echo "under LC_ALL=$loc it failed without naming the line: $out"
      return 1
    }
  done
  # The commit's index, not the default one: a Spanish file staged only in an
  # index of its own, as `git commit -a` or `git commit <paths>` hands one
  # to the hook, is found through THIS_INDEX and not without it.
  printf 'a\xc3\xb1o\n' > "$tmp/repo/staged-only.txt"
  git -C "$tmp/repo" rm -q --cached spanish.txt
  rm "$tmp/repo/spanish.txt"
  cp "$tmp/repo/.git/index" "$tmp/commit-index"
  GIT_INDEX_FILE=$tmp/commit-index git -C "$tmp/repo" add staged-only.txt
  out=$(cd "$tmp/repo" && THIS_INDEX='' english_only 2>&1) || {
    echo "found a file only the commit's index holds without being given that index: $out"
    return 1
  }
  if out=$(cd "$tmp/repo" && THIS_INDEX=$tmp/commit-index english_only 2>&1); then
    echo "missed a Spanish file staged in the commit's index"
    return 1
  fi
  mkdir "$tmp/bin"
  printf '#!/bin/sh\necho "fatal: grep broke" >&2\nexit 128\n' > "$tmp/bin/git"
  chmod +x "$tmp/bin/git"
  if out=$(cd "$tmp/repo" && THIS_INDEX='' PATH="$tmp/bin:$PATH" english_only 2>&1); then
    echo "a search that exited 128 read as a clean tree"
    return 1
  fi
}
check "english only finds Spanish whatever the locale, reads the commit's index, and fails when its grep fails" english_only_contract
