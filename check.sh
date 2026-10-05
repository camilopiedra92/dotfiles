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
# without the run going red. It is on automatically under CI and in the
# pre-commit hook, which is what makes CI's promise ("green here means a clean
# run there") true by construction rather than by a list somebody remembers to
# update. Both are gates: they decide whether something lands, so a run that
# checked nothing must not read as one that passed. Invoked by hand it is a
# report and not a gate, and there an amber skip is the useful answer.
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
  check "shellcheck" shellcheck -x ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/* ./macos/*.sh
else
  skip "shellcheck" "brew install shellcheck"
fi

# shfmt reads .editorconfig, so the style lives there and not in flags here:
# the editor, this check and the hook cannot drift apart if there is only one
# definition to read.
if command -v shfmt > /dev/null 2>&1; then
  check "shfmt" shfmt -d ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/* ./macos/*.sh
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

syntax_bash() { for f in ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/* ./macos/*.sh; do bash -n "$f" || return 1; done; }
check "bash syntax" syntax_bash

if command -v zsh > /dev/null 2>&1; then
  syntax_zsh() { for f in zsh/.zshenv zsh/.zprofile zsh/.zshrc; do zsh -n "$f" || return 1; done; }
  check "zsh syntax" syntax_zsh
else
  skip "zsh syntax" "zsh not installed"
fi

# The mode that matters lives in git, not on this machine: a fresh clone gets
# whatever the tree says, and `~/dotfiles/install.sh` -- the invocation the
# README documents -- then dies with permission denied. The bit is lost silently
# and by accident, by anything that replaces the file rather than editing it in
# place: an editor writing through a temp file, or a `mv` from /tmp, which is
# how it was lost here. Nothing else in this run would have noticed, because
# every check invokes these through `bash <file>` and that works at 644.
#
# The rule is the shebang, not the .sh suffix, and it is checked both ways.
# githooks/pre-commit has no suffix and must be executable; zsh/.zshenv has no
# shebang and must stay 644, since it is sourced and never run. A file that
# names an interpreter exists to be executed, and one that does not, does not.
exec_bits() {
  local bad=0 meta path mode first
  while IFS=$'\t' read -r meta path; do
    mode=${meta%% *}
    first=$(head -n1 "$path" 2> /dev/null)
    case "$first" in
      '#!'*)
        if [ "$mode" != 100755 ]; then
          echo "$path declares an interpreter but is $mode in git, so a clone cannot run it"
          bad=1
        fi
        ;;
      *)
        if [ "$mode" = 100755 ]; then
          echo "$path is executable in git but has no shebang"
          bad=1
        fi
        ;;
    esac
  done < <(git ls-files -s)
  return "$bad"
}
check "tracked scripts are executable in git" exec_bits

# ── Tool versions ────────────────────────────────────────────────────────────
# CI pins these five and verifies them by checksum; the Brewfile installs
# whatever is current. "CI and your machine run the same binaries" is therefore
# a claim nothing was enforcing, true only as long as nobody upgraded. Ghostty
# does not even need that: it is a cask that updates itself, and its own config
# here sets auto-update.
#
# Nothing renews the pins either — Dependabot covers the pinned action SHA and
# has no ecosystem for a version in an env var — so the least this can do is
# make the gap loud on the machine where it first appears, instead of leaving
# it to be discovered as a CI failure nobody can explain months later.
printf '\n%sTool versions%s\n' "$DIM" "$OFF"

# Version as written in ci.yml, with any leading v removed; the file spells it
# both ways.
pinned() { awk -v k="$1:" '$1 == k { sub(/^v/, "", $2); print $2; exit }' .github/workflows/ci.yml; }

# Each tool reports its version its own way, and shfmt reports it differently
# depending on where it came from: brew builds say 3.13.1, the release binary
# CI downloads says v3.13.1.
installed() {
  case "$1" in
    shellcheck) shellcheck --version | awk '/^version:/ { print $2 }' ;;
    shfmt) shfmt --version | sed 's/^v//' ;;
    actionlint) actionlint --version | head -1 ;;
    ghostty) ghostty +version | awk 'NR == 1 { print $2 }' ;;
    taplo) taplo --version | awk '{ print $2 }' ;;
  esac
}

versions_match() {
  local status=0 tool var want have
  for pair in shellcheck:SHELLCHECK_VERSION shfmt:SHFMT_VERSION \
    actionlint:ACTIONLINT_VERSION ghostty:GHOSTTY_VERSION taplo:TAPLO_VERSION; do
    tool=${pair%%:*}
    var=${pair##*:}
    # A missing tool is already reported by its own check above; repeating it
    # here would just be noise.
    command -v "$tool" > /dev/null 2>&1 || continue
    want=$(pinned "$var")
    have=$(installed "$tool")
    if [ -z "$want" ]; then
      echo "$tool: no $var pinned in ci.yml"
      status=1
    elif [ "$want" != "$have" ]; then
      echo "$tool: installed $have, ci.yml pins $want"
      status=1
    fi
  done
  return "$status"
}
check "installed tools match the ci.yml pins" versions_match

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
english_only() {
  ! git grep -nP '[\x{00A1}\x{00BF}\x{00C0}-\x{024F}]' -- . ':(exclude)schemas/' 2> /dev/null
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
  #
  # The range stops at 3c and not at 4, which is not an off-by-one. Everything
  # here is sandboxed by pointing HOME at a temporary directory, and 3c is the
  # one step that reaches its target by path instead: `git -C "$DOTFILES"`
  # escapes that sandbox and writes core.hooksPath into the real repository. A
  # check that mutates the tree it is checking is not a check.
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 3\. Symlinks/,/^# --- 3c\./p' install.sh
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

  # The other half of that guard: catch the day someone renames 3c and the range
  # silently swallows it again. Without this the side effect returns unnoticed,
  # because enabling a hook that was going to be enabled anyway looks like
  # nothing went wrong.
  # shellcheck disable=SC2016  # matching that literal text, not expanding it
  grep -qF 'git -C "$DOTFILES" config' "$steps" &&
    {
      echo "extraction reached step 3c, which writes to the real repository"
      return 1
    }

  # A ~/.ssh that already exists, at the mode a plain mkdir gives it, is the
  # case the chmod in step 3 is there for; without this the fixture would
  # only ever prove the mode of a directory the step created itself.
  mkdir -p "$tmp/home"
  mkdir -m 755 "$tmp/home/.ssh"
  HOME="$tmp/home" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1
  HOME="$tmp/home" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1

  [ -L "$tmp/home/.config/zsh/.zshrc" ] || {
    echo ".zshrc was not symlinked"
    return 1
  }
  [ "$(readlink "$tmp/home/.config/zsh/.zshrc")" = "$PWD/zsh/.zshrc" ] || {
    echo ".zshrc points elsewhere"
    return 1
  }
  # The one file that must NOT move: zsh reads it before ZDOTDIR exists, so
  # linking it anywhere else means the rest is never found.
  [ -L "$tmp/home/.zshenv" ] || {
    echo ".zshenv was not linked into \$HOME"
    return 1
  }
  # And the copy under ZDOTDIR, which is the one a nested shell reads instead.
  [ -L "$tmp/home/.config/zsh/.zshenv" ] || {
    echo ".zshenv was not linked into \$ZDOTDIR"
    return 1
  }

  # Both symlinks existing is structure; this is the behaviour they exist for.
  # zsh reads exactly one .zshenv, chosen by whether ZDOTDIR was already in the
  # environment, so the PATH has to come out built either way. The second case
  # is a shell spawned from an already-configured one -- a git hook, `zsh -c`
  # from an editor -- and when only the $HOME copy was linked it read neither
  # file and got the bare system PATH, which is `node: command not found` from
  # a hook on a machine where node is installed and on PATH in the terminal.
  #
  # env -i, because inheriting this run's PATH would make it pass with the
  # symlink deleted. Asserting on PATH and not on `command -v node` keeps it
  # true in CI, where mise is not installed: zsh keeps a non-existent directory
  # in the path array, so the string is there to check for regardless.
  if command -v zsh > /dev/null 2>&1; then
    local zdotdir="$tmp/home/.config/zsh" start p
    # shellcheck disable=SC2016  # $PATH is expanded by the zsh being tested, not here
    for start in cold nested; do
      if [ "$start" = cold ]; then
        p=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin zsh -c 'echo $PATH')
      else
        p=$(env -i HOME="$tmp/home" ZDOTDIR="$zdotdir" PATH=/usr/bin:/bin zsh -c 'echo $PATH')
      fi
      case "$p" in
        *"$tmp/home/.local/share/mise/shims"*) ;;
        *)
          echo "$start zsh -c did not get the mise shims on PATH: $p"
          return 1
          ;;
      esac
    done
  fi
  [ -L "$tmp/home/.claude/statusline.sh" ] || {
    echo "statusline was not symlinked"
    return 1
  }
  # ssh checks the config file's own owner and mode, not the directory's; the
  # 700 is for the private key step 4b will put next to it, and asserting it
  # here is what proves an inherited looser mode gets converged.
  [ -L "$tmp/home/.ssh/config" ] || {
    echo "ssh config was not symlinked"
    return 1
  }
  [ "$(stat -f %Lp "$tmp/home/.ssh")" = 700 ] || {
    echo ".ssh is mode $(stat -f %Lp "$tmp/home/.ssh") after install, not 700"
    return 1
  }
  # launchd reads only this directory, so a plist linked anywhere else is a
  # plist that never runs.
  [ -L "$tmp/home/Library/LaunchAgents/com.piedrac.ssh-add-keychain.plist" ] || {
    echo "the login agent plist was not linked into ~/Library/LaunchAgents"
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

# Step 7 does two things and only one of them needs the network. It turns each
# line of uv-tools.txt into a `uv tool install`, and the turning is where the
# bugs are: a comment-only line producing a phantom install, a trailing comment
# landing inside the reference, a blank line invoking uv with nothing. None of
# that needs to reach anything to be checked.
#
# So it runs against a fixture manifest and a `uv` that records its arguments
# instead of doing the work. That is the same boundary step 2 draws in the file
# itself -- whether Homebrew installs correctly is Homebrew's problem -- and it
# keeps this check meaning the same thing on a runner as on the machine, which
# is the whole basis for CI's promise here.
#
# A fixture rather than the real manifest, because the real one has a single
# well-formed line and would exercise none of the shapes worth getting wrong.
# Every extraction below ends at the header of the next step, and this is the
# check that it took exactly one. A step extracted up to a prose comment once
# swallowed the step added after it: that step ran for real, against this
# machine's HOME and the real CLI, inside a test that had stubbed only `uv`.
one_step_only() {
  local steps=$1 n
  # The range is inclusive, so its last line is the next step's header (or the
  # closing log line): that one is the boundary, not a step that was taken.
  n=$(sed '$d' "$steps" | grep -c '^# --- [0-9]')
  [ "$n" -eq 1 ] || {
    echo "extraction took $n steps from install.sh, not one:"
    sed '$d' "$steps" | grep '^# --- [0-9]'
    return 1
  }
}

uv_tools_step() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"

  {
    echo 'log() { :; }'
    sed -n '/^# --- 7\. CLI tools from uv/,/^# --- 8\./p' install.sh
  } > "$steps"

  # The same guard the check above uses: if that heading is ever renamed the
  # extraction goes empty, and an empty script passes everything.
  grep -qF 'uv tool install' "$steps" || {
    echo "could not extract step 7 from install.sh"
    return 1
  }
  one_step_only "$steps" || return 1

  cat > "$tmp/uv-tools.txt" << 'FIXTURE'
# a comment-only line, which must produce no install at all

alpha-cli  git+https://example.invalid/alpha.git@v1.2.3
beta-cli   beta-cli==2.0  # a trailing comment, which must not reach the reference
FIXTURE

  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/uv"
  chmod +x "$tmp/bin/uv"
  : > "$tmp/calls"

  PATH="$tmp/bin:$PATH" DOTFILES="$tmp" bash -euo pipefail "$steps" > /dev/null || return 1

  # Written out rather than derived from the fixture, so a parser that is wrong
  # cannot agree with itself.
  cat > "$tmp/want" << 'WANT'
tool install --from git+https://example.invalid/alpha.git@v1.2.3 alpha-cli
tool install --from beta-cli==2.0 beta-cli
WANT

  diff -u "$tmp/want" "$tmp/calls"
}
check "install.sh turns the uv manifest into the right installs" uv_tools_step

# The fixture above proves the loop handles the shapes that are easy to get
# wrong. It says nothing about the file this repo actually ships, which has one
# well-formed line today and will not always.
#
# Writing a second expectation by hand would only restate the manifest. So the
# real file goes through the same stubbed step, and the result is compared
# against what an independent parser makes of the same bytes -- python here,
# `sed` and `read` there. Neither can agree with itself, because they are not
# the same code.
#
# That also pins the two together, which is the point worth more than the
# coverage. This format is parsed in four places: step 7, the manifest check
# above, and twice inside drift.sh. Nothing made them agree; they simply did. A
# column added to the format in one and not the others now turns this red
# instead of turning drift.sh into a liar.
uv_tools_real_manifest() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"

  {
    echo 'log() { :; }'
    sed -n '/^# --- 7\. CLI tools from uv/,/^# --- 8\./p' install.sh
  } > "$steps"
  grep -qF 'uv tool install' "$steps" || {
    echo "could not extract step 7 from install.sh"
    return 1
  }
  one_step_only "$steps" || return 1

  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/uv"
  chmod +x "$tmp/bin/uv"
  : > "$tmp/calls"

  PATH="$tmp/bin:$PATH" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null || return 1

  python3 - "$tmp/calls" << 'PY'
import sys

want = []
with open('uv-tools.txt', encoding='utf-8') as handle:
    for number, line in enumerate(handle, 1):
        fields = line.split('#')[0].split()
        if not fields:
            continue
        if len(fields) != 2:
            # The manifest check above is what reports this properly. Bailing
            # here rather than guessing keeps one failure to one message.
            print('line %d is not "name reference"; see the manifest check'
                  % number)
            raise SystemExit(1)
        want.append('tool install --from %s %s' % (fields[1], fields[0]))

got = [line.rstrip('\n') for line in open(sys.argv[1], encoding='utf-8')]
if want != got:
    print('step 7 would run:')
    for call in got:
        print('  %s' % call)
    print('the manifest asks for:')
    for call in want:
        print('  %s' % call)
    raise SystemExit(1)
PY
}
check "step 7 and the manifest agree on every declared tool" uv_tools_real_manifest

# Step 8b has the same split as step 7: whether `claude mcp` registers a server
# is Claude Code's problem, but which servers it is asked to add, remove, or
# leave alone is decided here, from a comparison against ~/.claude.json. So it
# runs with HOME pointed at a fixture state file and a `claude` that records
# its arguments, and the fixture covers each branch of that decision once: a
# server already registered as declared, one registered differently, one not
# registered at all, one registered that the manifest does not name, and one
# that only this machine's profile declares.
mcp_step() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"

  {
    echo 'log() { :; }'
    sed -n '/^# --- 8b\. Claude Code MCP servers/,/^# --- 9\./p' install.sh
  } > "$steps"
  grep -qF 'claude mcp add-json' "$steps" || {
    echo "could not extract step 8b from install.sh"
    return 1
  }
  one_step_only "$steps" || return 1

  mkdir -p "$tmp/claude" "$tmp/home" "$tmp/bin" "$tmp/machine"
  cat > "$tmp/machine/mcp.json" << 'FIXTURE'
{
  "mcpServers": {
    "local": { "type": "stdio", "command": "local-mcp", "args": [] }
  }
}
FIXTURE
  cat > "$tmp/claude/mcp.json" << 'FIXTURE'
{
  "mcpServers": {
    "same":    { "type": "http",  "url": "https://same.invalid/mcp" },
    "changed": { "type": "http",  "url": "https://changed.invalid/v2" },
    "missing": { "type": "stdio", "command": "missing-mcp", "args": [] }
  }
}
FIXTURE
  cat > "$tmp/home/.claude.json" << 'FIXTURE'
{
  "mcpServers": {
    "same":    { "type": "http", "url": "https://same.invalid/mcp" },
    "changed": { "type": "http", "url": "https://changed.invalid/v1" },
    "extra":   { "type": "http", "url": "https://extra.invalid/mcp" }
  },
  "somethingClaudeWrote": true
}
FIXTURE
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/claude"
  chmod +x "$tmp/bin/claude"
  : > "$tmp/calls"

  HOME="$tmp/home" PATH="$tmp/bin:$PATH" DOTFILES="$tmp" machine_dir="$tmp/machine" \
    bash -euo pipefail "$steps" > /dev/null || return 1

  # Order is by name, which is what `jq keys` yields, so the expectation is
  # stable. `same` and `extra` must produce no call at all.
  cat > "$tmp/want" << 'WANT'
mcp remove changed --scope user
mcp add-json changed {"type":"http","url":"https://changed.invalid/v2"} --scope user
mcp add-json local {"type":"stdio","command":"local-mcp","args":[]} --scope user
mcp add-json missing {"type":"stdio","command":"missing-mcp","args":[]} --scope user
WANT
  diff -u "$tmp/want" "$tmp/calls" || return 1

  # A state file that does not exist yet -- a machine on its first run -- must
  # be created rather than tripped over, and every server then added. Without
  # a manifest of its own the profile adds nothing: most profiles have none.
  rm "$tmp/home/.claude.json" "$tmp/machine/mcp.json"
  : > "$tmp/calls"
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" DOTFILES="$tmp" machine_dir="$tmp/machine" \
    bash -euo pipefail "$steps" > /dev/null || return 1
  [ "$(grep -c 'mcp add-json' "$tmp/calls")" -eq 3 ] || {
    echo "first run did not add exactly the shared servers:"
    cat "$tmp/calls"
    return 1
  }
  ! grep -q 'mcp remove' "$tmp/calls" || {
    echo "first run tried to remove from an empty state file"
    return 1
  }
}
check "install.sh registers the MCP servers the manifest declares" mcp_step

# The YNAB token comes from the Keychain so that no file holds it -- it used to
# sit in plain text in ~/.claude.json. Both branches: a token found reaches the
# server, and a token missing stops the wrapper before the server starts, since
# a server started without one fails later with an error about YNAB rather
# than about the Keychain.
ynab_token_from_keychain() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  # shellcheck disable=SC2016  # expanded when the stub runs
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "$YNAB_API_TOKEN" "$*" > "%s/started"\n' "$tmp" > "$tmp/bin/mise"
  printf '#!/bin/sh\necho token-from-keychain\n' > "$tmp/bin/security"
  chmod +x "$tmp/bin/mise" "$tmp/bin/security"

  PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" ./bin/ynab-mcp.sh > /dev/null 2>&1 || {
    echo "the wrapper failed with a token in the Keychain"
    return 1
  }
  [ "$(cat "$tmp/started" 2> /dev/null)" = 'token-from-keychain x -- npx -y ynab-mcp-server' ] || {
    echo "the server did not start with the Keychain token: $(cat "$tmp/started" 2> /dev/null)"
    return 1
  }

  rm "$tmp/started"
  printf '#!/bin/sh\nexit 44\n' > "$tmp/bin/security"
  if out=$(PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" ./bin/ynab-mcp.sh 2>&1); then
    echo "the wrapper succeeded with no token in the Keychain"
    return 1
  fi
  [ ! -e "$tmp/started" ] || {
    echo "the server started without a token"
    return 1
  }
  case "$out" in
    *add-generic-password*) ;;
    *)
      echo "the failure does not say how to store the token: $out"
      return 1
      ;;
  esac
}
check "the YNAB wrapper takes its token from the Keychain" ynab_token_from_keychain

# Step 4b generates a key, registers it with gh and points config.local at it.
# Each of those has an "already done" branch, and the test is that a second
# run takes every one of them: a key regenerated is a key GitHub no longer
# knows, and a signingkey appended twice is a config git refuses to read.
#
# The stub `gh` mirrors the two shapes that made the step's first drafts
# wrong. Logged out, `auth status` exits 1 and the step has to log in, not
# die with the message captured in a variable. Logged in, the token does not
# carry the scopes that manage keys, and without them `ssh-key list` prints a
# 404 to stderr and an empty list to stdout -- which a plain grep reads as
# "not registered" -- while `add` fails. So the stub is logged in
# only once `auth login` has been recorded, answers `auth status` from a
# scope fixture, lists nothing and refuses to add until login or refresh has
# added the scopes. Both starting points are run twice: logged out must log
# in exactly once and never refresh (login asks for the scopes); logged in
# without the scopes must refresh exactly once and never log in.
signing_step() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"
  mkdir -p "$tmp/bin"
  # ssh-keygen: create the two files it would, record the call. The key
  # holds a `++`, which as a regex never matches: the listing lookup has to
  # be a substring test, and a key like this is one in a hundred real ones.
  cat > "$tmp/bin/ssh-keygen" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
for ((i = 1; i <= $#; i++)); do [ "${!i}" = -f ] && { j=$((i + 1)); f=${!j}; }; done
echo private > "$f"; echo "ssh-ed25519 AAAAC3++NzaC1 t@example.com" > "$f.pub"
STUB
  # ssh-add: recorded only. The real one would load the fixture key into
  # this machine's agent and ask the Keychain for its passphrase.
  # shellcheck disable=SC2016  # written verbatim, expanded when it runs
  printf '#!/bin/sh\necho "$*" >> "$CALLS"\n' > "$tmp/bin/ssh-add"
  # gh: `ssh-key list` answers from $KNOWN in the real CLI's tab-separated
  # columns (TITLE, KEY, ADDED, ID, TYPE), `ssh-key add` appends to it, both
  # only once the scopes in $SCOPES allow it. The title carries the other
  # type's name on purpose: a match that searches the row instead of the
  # type column would find it and never register the second type.
  cat > "$tmp/bin/gh" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
# Grants exactly the -s values it was given, so a scope dropped from the
# step is a scope the stub does not have either. Each key type needs its
# own: authentication keys admin:public_key, signing keys
# admin:ssh_signing_key, and a listing shows only the half its scope allows.
asked() { for ((i = 1; i <= $#; i++)); do [ "${!i}" = -s ] && { j=$((i + 1)); printf ", '%s'" "${!j}"; }; done; true; }
scoped() { grep -qF "'$1'" "$SCOPES"; }
scope_for() { [ "$1" = signing ] && echo admin:ssh_signing_key || echo admin:public_key; }
type=authentication
for ((i = 1; i <= $#; i++)); do [ "${!i}" = --type ] && { j=$((i + 1)); type=${!j}; }; done
case "$1 $2" in
  "auth status")
    [ -f "$LOGIN" ] || { echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1; }
    printf "  - Token scopes: %s\n" "$(cat "$SCOPES")" ;;
  "auth login") touch "$LOGIN"; { printf "'repo'"; asked "$@"; } > "$SCOPES" ;;
  "auth refresh") asked "$@" >> "$SCOPES" ;;
  "ssh-key list")
    for t in authentication signing; do
      if scoped "$(scope_for "$t")"; then awk -F'\t' -v t="$t" '$5 == t' "$KNOWN"; else echo "HTTP 404" >&2; fi
    done ;;
  "ssh-key add")
    scoped "$(scope_for "$type")" || { echo "HTTP 404" >&2; exit 1; }
    [ "$type" = signing ] && title="authentication key of mac" || title="signing key of mac"
    printf '%s\t%s\t2026-09-15T00:00:00Z\t1\t%s\n' "$title" "$(cat "$3")" "$type" >> "$KNOWN" ;;
esac
STUB
  chmod +x "$tmp/bin/ssh-keygen" "$tmp/bin/gh" "$tmp/bin/ssh-add"
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    # shellcheck disable=SC2016  # same: step 4 defines this and the range starts after it
    echo 'GIT_IDENTITY="$HOME/.config/git/config.local"'
    sed -n '/^# --- 4b\. Signing key ---/,/^# --- 4c\./p' install.sh
  } > "$steps"
  grep -qF 'ssh-keygen -t ed25519' "$steps" || {
    echo "could not extract step 4b from install.sh"
    return 1
  }
  one_step_only "$steps" || return 1

  local start home run key
  for start in logged-out logged-in; do
    # A fresh HOME per starting point, holding what steps 3 and 4 leave
    # behind: ~/.ssh exists and the identity is written.
    home="$tmp/$start/home"
    mkdir -p "$home/.ssh" "$home/.config/git"
    printf '[user]\n\tname = T\n\temail = t@example.com\n' > "$home/.config/git/config.local"
    : > "$tmp/calls"
    : > "$tmp/known"
    rm -f "$tmp/login"
    if [ "$start" = logged-in ]; then
      touch "$tmp/login"
      printf "'gist', 'read:org', 'repo', 'workflow'" > "$tmp/scopes"
      # A second identity, scoped to one directory: a client's GitHub account
      # with its own key. The file is all the machine declares; the step has
      # to turn it into the includeIf and the allowed_signers line.
      mkdir -p "$home/.config/git/identities"
      echo "ssh-ed25519 AAAAC3client c@client.example" > "$home/.ssh/id_client.pub"
      printf '[identity]\n\tgitdir = ~/work/client/\n[user]\n\temail = c@client.example\n\tsigningkey = ~/.ssh/id_client.pub\n' \
        > "$home/.config/git/identities/client.gitconfig"
    else
      : > "$tmp/scopes"
    fi
    for run in 1 2; do
      HOME="$home" DOTFILES="$PWD" CALLS="$tmp/calls" KNOWN="$tmp/known" SCOPES="$tmp/scopes" \
        LOGIN="$tmp/login" PATH="$tmp/bin:$PATH" bash -euo pipefail "$steps" > "$tmp/out" 2>&1 || {
        echo "$start: run $run failed"
        cat "$tmp/out"
        return 1
      }
    done
    local logins refreshes
    logins=$(grep -c '^auth login' "$tmp/calls")
    refreshes=$(grep -c '^auth refresh' "$tmp/calls")
    if [ "$start" = logged-out ]; then
      [ "$logins" -eq 1 ] && [ "$refreshes" -eq 0 ] || {
        echo "$start: expected one login, asking for the scopes, and no refresh"
        cat "$tmp/calls"
        return 1
      }
    else
      [ "$logins" -eq 0 ] && [ "$refreshes" -eq 1 ] || {
        echo "$start: expected the scopes refreshed once, when missing, and no login"
        cat "$tmp/calls"
        return 1
      }
    fi
    [ "$(grep -c '^-t ed25519' "$tmp/calls")" -eq 1 ] || {
      echo "$start: key generated more than once"
      cat "$tmp/calls"
      return 1
    }
    # Every run, not only the one that generated the key: the Keychain is
    # what this call fills, and a key that arrived from elsewhere has the
    # same empty Keychain behind it.
    [ "$(grep -c '^--apple-use-keychain ' "$tmp/calls")" -eq 2 ] || {
      echo "$start: expected the key stored in the Keychain on each run"
      cat "$tmp/calls"
      return 1
    }
    grep -q '^ssh-key add .*--type authentication' "$tmp/calls" &&
      grep -q '^ssh-key add .*--type signing' "$tmp/calls" &&
      [ "$(grep -c '^ssh-key add' "$tmp/calls")" -eq 2 ] || {
      echo "$start: expected one add per type (authentication + signing), once"
      cat "$tmp/calls"
      return 1
    }
    [ "$(grep -c signingkey "$home/.config/git/config.local")" -eq 1 ] || {
      echo "$start: signingkey missing or duplicated"
      return 1
    }
    git config --file "$home/.config/git/config.local" user.signingkey > /dev/null || {
      echo "$start: config.local no longer parses"
      return 1
    }
    # The switch travels with the key (git/config explains why), so it has to
    # come out of the same file, once, and read true.
    [ "$(grep -c gpgsign "$home/.config/git/config.local")" -eq 2 ] || {
      echo "$start: expected exactly one gpgsign line per section in config.local"
      cat "$home/.config/git/config.local"
      return 1
    }
    for key in commit.gpgsign tag.gpgsign; do
      [ "$(git config --file "$home/.config/git/config.local" "$key")" = true ] || {
        echo "$start: $key is not true in config.local"
        return 1
      }
    done
    local signers=1
    [ "$start" = logged-in ] && signers=2
    [ "$(wc -l < "$home/.config/git/allowed_signers")" -eq "$signers" ] || {
      echo "$start: allowed_signers has $(wc -l < "$home/.config/git/allowed_signers") lines, expected $signers"
      cat "$home/.config/git/allowed_signers"
      return 1
    }
    [ "$start" = logged-in ] || continue
    grep -qxF 'c@client.example ssh-ed25519 AAAAC3client c@client.example' "$home/.config/git/allowed_signers" || {
      echo "$start: the scoped identity's key is not an allowed signer"
      cat "$home/.config/git/allowed_signers"
      return 1
    }
    [ "$(grep -c includeIf "$home/.config/git/config.local")" -eq 1 ] || {
      echo "$start: expected exactly one includeIf in config.local after two runs"
      cat "$home/.config/git/config.local"
      return 1
    }
    # The proof that matters is git's own answer: inside the scoped directory
    # the scoped identity wins, outside it the default one still holds.
    printf '[include]\n\tpath = config.local\n' > "$home/.config/git/config"
    mkdir -p "$home/work/client/repo" "$home/elsewhere"
    git -C "$home/work/client/repo" init -q
    git -C "$home/elsewhere" init -q
    local inside outside
    inside=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_NOSYSTEM=1 git -C "$home/work/client/repo" config user.email)
    outside=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_NOSYSTEM=1 git -C "$home/elsewhere" config user.email)
    [ "$inside" = c@client.example ] && [ "$outside" = t@example.com ] || {
      echo "$start: expected c@client.example inside the scoped directory and t@example.com outside, got '$inside' and '$outside'"
      return 1
    }
  done

  # A key file that exists but is empty -- a copy that went wrong -- yields an
  # empty PUBKEY, and an empty needle is found in every row (macOS awk's
  # index() returns 1 for one; gawk's would return 0): every type reads as
  # registered, nothing is added, and the identity ends up pointing at
  # nothing. The step has to stop instead. GitHub is seeded with another
  # machine's key under both types, so that the rows are there to be
  # matched: against an empty listing the same bug would surface as an add
  # of an empty key, which is a different failure from the one named here.
  home="$tmp/empty/home"
  mkdir -p "$home/.ssh" "$home/.config/git"
  printf '[user]\n\tname = T\n\temail = t@example.com\n' > "$home/.config/git/config.local"
  : > "$home/.ssh/id_ed25519"
  : > "$home/.ssh/id_ed25519.pub"
  : > "$tmp/calls"
  printf 'other mac\tssh-ed25519 AAAAC3other u@example.com\t2026-09-15T00:00:00Z\t2\t%s\n' \
    authentication signing > "$tmp/known"
  touch "$tmp/login"
  printf "'repo', 'admin:public_key', 'admin:ssh_signing_key'" > "$tmp/scopes"
  if HOME="$home" DOTFILES="$PWD" CALLS="$tmp/calls" KNOWN="$tmp/known" SCOPES="$tmp/scopes" \
    LOGIN="$tmp/login" PATH="$tmp/bin:$PATH" bash -euo pipefail "$steps" > "$tmp/out" 2>&1; then
    echo "an empty id_ed25519.pub was accepted as a key"
    cat "$tmp/calls"
    return 1
  fi
  ! grep -q '^ssh-key add' "$tmp/calls" || {
    echo "an empty id_ed25519.pub was sent to GitHub"
    cat "$tmp/calls"
    return 1
  }
}
check "install.sh sets up the signing key once and only once" signing_step

# Step 4c has to bootstrap the login agent exactly once and kick it on every
# run: `bootstrap` of a service that is already loaded is an error that would
# end install.sh under set -e, and a kickstart skipped on the second run
# would leave a session whose plist changed running the old one. launchctl
# is stubbed -- the real one would load the agent into this session -- and
# answers `print` from a marker its own `bootstrap` creates, so the second
# run sees the service loaded the way the real launchd would report it.
login_agent_step() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"
  mkdir -p "$tmp/bin" "$tmp/home"
  cat > "$tmp/bin/launchctl" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  print) [ -f "$LOADED" ] ;;
  bootstrap) touch "$LOADED" ;;
esac
STUB
  chmod +x "$tmp/bin/launchctl"
  {
    echo 'log() { :; }'
    sed -n '/^# --- 4c\. Load the signing key at login ---/,/^# --- 5\./p' install.sh
  } > "$steps"
  grep -qF 'launchctl bootstrap' "$steps" || {
    echo "could not extract step 4c from install.sh"
    return 1
  }
  one_step_only "$steps" || return 1

  local run
  : > "$tmp/calls"
  rm -f "$tmp/loaded"
  for run in 1 2; do
    HOME="$tmp/home" CALLS="$tmp/calls" LOADED="$tmp/loaded" PATH="$tmp/bin:$PATH" \
      bash -euo pipefail "$steps" > "$tmp/out" 2>&1 || {
      echo "run $run failed"
      cat "$tmp/out"
      return 1
    }
  done
  [ "$(grep -c '^bootstrap ' "$tmp/calls")" -eq 1 ] || {
    echo "expected the agent bootstrapped once across two runs"
    cat "$tmp/calls"
    return 1
  }
  [ "$(grep -c '^kickstart ' "$tmp/calls")" -eq 2 ] || {
    echo "expected the agent kickstarted on each run"
    cat "$tmp/calls"
    return 1
  }
  # The label the step asks launchd about has to be the one the plist
  # declares, or `print` fails forever and every run bootstraps again. Read
  # from the plist rather than repeated here, so this cannot agree with a
  # step that drifted from it.
  local label
  label=$(plutil -extract Label raw launchd/com.piedrac.ssh-add-keychain.plist) || return 1
  grep -qF "print gui/$(id -u)/$label" "$tmp/calls" || {
    echo "the step does not ask launchd about $label, the label the plist declares"
    cat "$tmp/calls"
    return 1
  }

  # A service launchd already reports -- a machine where an earlier run, or a
  # login since, loaded it -- must not be bootstrapped again.
  : > "$tmp/calls"
  touch "$tmp/loaded"
  HOME="$tmp/home" CALLS="$tmp/calls" LOADED="$tmp/loaded" PATH="$tmp/bin:$PATH" \
    bash -euo pipefail "$steps" > "$tmp/out" 2>&1 || {
    echo "run against a loaded service failed"
    cat "$tmp/out"
    return 1
  }
  ! grep -q '^bootstrap ' "$tmp/calls" || {
    echo "bootstrapped a service launchd already reported as loaded"
    cat "$tmp/calls"
    return 1
  }
}
check "install.sh loads the login agent once and kicks it every run" login_agent_step

# ── Machine profile ──────────────────────────────────────────────────────────
# One repo, more than one Mac. macos/machine.sh says which profile under
# macos/machines/ this Mac is, from a one-word file outside the repo, and the
# per-machine manifests hang off that answer. No profile, or one that names a
# directory that does not exist, has to be a broken checker (exit 2) for
# every script that asks: guessing would apply one Mac's Dock to the other.
printf '\n%sMachine profile%s\n' "$DIM" "$OFF"

# A profile directory named `test` with nothing in it, and a machine file
# naming it. Shared by every test below that runs a per-machine script.
machine_fixture() {
  mkdir -p "$1/machines/test"
  echo test > "$1/machine"
}

machine_run() {
  local tmp=$1
  shift
  MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/machine.sh "$@"
}

machine_requires_a_known_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/machines/personal" "$tmp/machines/work"
  rc=0
  out=$(machine_run "$tmp" dir 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "dir exited $rc with no machine file, want 2: $out"
    return 1
  }
  case "$out" in
    *"$tmp/machine"*"personal work"*) ;;
    *)
      echo "did not name the file and the profiles to choose from: $out"
      return 1
      ;;
  esac
  echo nope > "$tmp/machine"
  rc=0
  out=$(machine_run "$tmp" dir 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "dir exited $rc for an unknown profile, want 2: $out"
    return 1
  }
  case "$out" in
    *"unknown machine 'nope'"*) ;;
    *)
      echo "did not name the unknown profile: $out"
      return 1
      ;;
  esac
}
check "dir refuses a missing machine file and an unknown profile" machine_requires_a_known_profile

machine_set_validates_then_writes() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  # $tmp/etc exists, so only the name check can refuse ../etc.
  mkdir -p "$tmp/machines/personal" "$tmp/etc"
  rc=0
  out=$(machine_run "$tmp" set ../etc 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
    echo "set accepted a profile that does not exist (exit $rc): $out"
    return 1
  }
  machine_run "$tmp" set personal || return 1
  [ "$(cat "$tmp/machine")" = personal ] || {
    echo "set wrote: $(cat "$tmp/machine")"
    return 1
  }
  out=$(machine_run "$tmp" dir) || return 1
  [ "$out" = "$tmp/machines/personal" ] || {
    echo "dir printed $out"
    return 1
  }
}
check "set refuses an unknown profile, writes a known one, and dir finds it" machine_set_validates_then_writes

# A profile name is lowercase letters, digits and dashes, matched byte by
# byte. A bracket range follows the locale's collation in bash 3.2, so
# [a-z] lets uppercase through under en_US.UTF-8 -- and APFS, being
# case-insensitive, would then resolve `Personal` to personal/ on one Mac
# and not on a case-sensitive volume. Inner whitespace is not trimmed into
# a different, valid name either.
machine_names_are_exact() {
  local tmp rc name
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/machines/personal"
  for name in Personal "per sonal"; do
    rc=0
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 machine_run "$tmp" set "$name" 2> /dev/null || rc=$?
    [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
      echo "set accepted '$name' (exit $rc)"
      return 1
    }
    printf '%s\n' "$name" > "$tmp/machine"
    rc=0
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 machine_run "$tmp" dir > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "dir accepted a machine file saying '$name' (exit $rc)"
      return 1
    }
    rm "$tmp/machine"
  done
}
check "a profile name matches exactly: no uppercase, no inner space" machine_names_are_exact

# install.sh's own step for the profile: silent when one is recorded, and
# when none is and nobody is at a terminal to answer -- CI, a piped run -- it
# stops with machine.sh's reason instead of waiting on a prompt or carrying
# on into steps that would then fail one by one. Extracted the same way the
# idempotence check extracts the symlink steps, and run against a fixture.
install_machine_step() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 8\. Machine profile/,/^# --- 8b\./p' install.sh
  } > "$tmp/step.sh"
  grep -qF 'machine.sh' "$tmp/step.sh" || {
    echo "could not extract step 8 from install.sh"
    return 1
  }
  one_step_only "$tmp/step.sh" || return 1
  mkdir -p "$tmp/machines/personal"
  rc=0
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" \
    bash -euo pipefail "$tmp/step.sh" < /dev/null 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
    echo "without a terminal or a profile the step exited $rc, want 2: $out"
    return 1
  }
  case "$out" in
    *"no machine profile"*) ;;
    *)
      echo "did not say why it stopped: $out"
      return 1
      ;;
  esac
  echo personal > "$tmp/machine"
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" \
    bash -euo pipefail "$tmp/step.sh" < /dev/null 2>&1) || {
    echo "the step failed with a profile recorded: $out"
    return 1
  }
  [ "$out" = "==> Machine profile: personal" ] || {
    echo "unexpected output with a profile recorded: $out"
    return 1
  }
}
check "install.sh stops when there is no profile and nobody to ask" install_machine_step

# The prompt itself, through a real terminal: expect(1), which macOS ships,
# allocates one and answers it. A wrong name asks again rather than ending
# the install; end of input stops it with a reason rather than in silence.
install_machine_prompt() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 8\. Machine profile/,/^# --- 8b\./p' install.sh
  } > "$tmp/step.sh"
  mkdir -p "$tmp/machines/personal"
  rc=0
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" expect -c "
    set timeout 10
    spawn bash -euo pipefail $tmp/step.sh
    expect {Profile for this Mac: }
    send nope\r
    expect {Profile for this Mac: }
    send personal\r
    expect eof
    exit [lindex [wait] 3]
  " 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$tmp/machine" 2> /dev/null)" = personal ] || {
    echo "a wrong answer then a right one did not record personal (exit $rc): $out"
    return 1
  }
  rm "$tmp/machine"
  rc=0
  out=$(MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" DOTFILES="$PWD" expect -c "
    set timeout 10
    spawn bash -euo pipefail $tmp/step.sh
    expect {Profile for this Mac: }
    send \004
    expect eof
    exit [lindex [wait] 3]
  " 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$tmp/machine" ] || {
    echo "end of input at the prompt exited $rc, want 2: $out"
    return 1
  }
  case "$out" in
    *"no profile given"*) ;;
    *)
      echo "end of input did not say why it stopped: $out"
      return 1
      ;;
  esac
}
check "install.sh asks again after a wrong name, and stops with a reason on end of input" install_machine_prompt

# ── macOS defaults ───────────────────────────────────────────────────────────
# macos/defaults.txt is the fourth manifest here and the only one whose
# consumer is a script of this repo's own. So the parsing is where the bugs
# would be, and it is exercised against a stub `defaults` that records what
# it was asked and answers `read` from a fixture: the real one writes to this
# machine's preferences, which a check must never do.
printf '\n%smacOS defaults%s\n' "$DIM" "$OFF"

macos_manifest() {
  local bad f
  # sed's "No such file" goes to its own stderr, not into $bad, so a missing
  # manifest would otherwise feed awk nothing and read as zero problems.
  [ -f macos/defaults.txt ] || {
    echo "macos/defaults.txt missing"
    return 1
  }
  # A machine's overlay is applied on top of the shared file, so a key in
  # both would be written twice with two values, and which one wins would
  # depend on the order of the loop rather than on anything written down.
  for f in macos/machines/*/defaults.txt; do
    [ -f "$f" ] || continue
    bad=$(cat macos/defaults.txt "$f" | sed 's/#.*//' | awk 'NF { print $1, $2 }' | sort | uniq -d)
    [ -z "$bad" ] || {
      echo "$f declares a key the shared manifest already does: $bad"
      return 1
    }
  done
  # `host:` is the one prefix defaults.sh interprets (it strips it and adds
  # `-currentHost`), so it is the one place a typo'd or unknown prefix has to
  # be refused here -- otherwise `hots:NSGlobalDomain` reads as a plain
  # domain and `defaults` would happily create a plist literally named that.
  bad=$(for f in macos/defaults.txt macos/machines/*/defaults.txt; do
    [ -f "$f" ] && sed 's/#.*//' "$f" | awk -v f="$f" '
    NF == 0 { next }
    NF < 4 { print f":"NR": fewer than four fields"; next }
    $1 ~ /:/ && $1 !~ /^host:./ { print f":"NR": unknown domain prefix "$1; next }
    NF > 4 && $3 != "string" { print f":"NR": extra fields"; next }
    $3 !~ /^(bool|int|float|string)$/ { print f":"NR": unknown type "$3; next }
    $3 == "bool" && $4 !~ /^(true|false)$/ { print f":"NR": bool must be true or false" }
    $3 == "int" && $4 !~ /^-?[0-9]+$/ { print f":"NR": int must be an integer" }
    $3 == "float" && $4 !~ /^-?[0-9]+(\.[0-9]+)?$/ { print f":"NR": float must be a number" }
  '
  done)
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "every defaults manifest has domain key type value per line, no key twice" macos_manifest

# The stub answers `read` from $STATE (lines of "domain key value"), records
# every `write` to $WRITES, and every killall to $KILLED. `defaults read` on a
# key that is not set exits 1 and prints to stderr, which is what the stub
# reproduces so the "unset" path is the real one. A leading `-currentHost`
# (defaults.sh's own way of addressing the per-host ByHost file) switches the
# stub to a separate $STATE_HOST/$WRITES_HOST pair, so a test can prove a
# `host:` manifest line never touches the plain domain's state and vice
# versa.
macos_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/defaults" << 'STUB'
#!/usr/bin/env bash
state=$STATE
writes=$WRITES
if [ "$1" = -currentHost ]; then
  shift
  state=$STATE_HOST
  writes=$WRITES_HOST
fi
case "$1" in
  read)
    v=$(awk -v d="$2" -v k="$3" '$1 == d && $2 == k { print $3; exit }' "$state")
    [ -n "$v" ] || { echo "does not exist" >&2; exit 1; }
    echo "$v" ;;
  write)
    echo "$2 $3 $4 $5" >> "$writes" ;;
esac
STUB
  cat > "$dir/bin/killall" << 'STUB'
#!/usr/bin/env bash
echo "$1" >> "$KILLED"
STUB
  chmod +x "$dir/bin/defaults" "$dir/bin/killall"
  machine_fixture "$dir"
}

# A manifest of three keys whose read-back forms differ from their written
# forms: a bool reads back as 1/0, a float as a bare number, a string with ~
# has to compare against the expanded HOME.
macos_fixture_manifest() {
  cat > "$1" << 'EOF'
# comment line
com.apple.finder    ShowPathbar    bool    true    # trailing comment
com.apple.dock      autohide-delay float   0
com.apple.screencapture location  string  ~/Screenshots
EOF
}

macos_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  macos_fixture_manifest "$tmp/defaults.txt"
  printf 'com.apple.finder ShowPathbar 1\ncom.apple.dock autohide-delay 0\ncom.apple.screencapture location %s/Screenshots\n' "$tmp/home" > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > "$tmp/out" || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "wrote although everything matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/killed" ] || {
    echo "restarted an app although nothing changed"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply writes nothing when the machine already matches" macos_apply_is_a_noop_when_matching

macos_apply_writes_only_the_difference() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  macos_fixture_manifest "$tmp/defaults.txt"
  # Finder matches; the dock key is unset; the screenshot path is wrong.
  printf 'com.apple.finder ShowPathbar 1\ncom.apple.screencapture location /elsewhere\n' > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > "$tmp/out" || return 1
  diff <(printf 'com.apple.dock autohide-delay -float 0\ncom.apple.screencapture location -string %s/Screenshots\n' "$tmp/home") "$tmp/writes" || return 1
  # Only the Dock changed; Finder must not be restarted for it.
  diff <(echo Dock) "$tmp/killed" || return 1
  diff <(printf 'com.apple.dock autohide-delay -> 0\ncom.apple.screencapture location -> ~/Screenshots\nrestarted: Dock\nother apps read the new values when they next launch; keyboard and trackpad changes need a log out and back in\n') "$tmp/out" || return 1
}
check "apply writes exactly the differing keys and restarts only their app" macos_apply_writes_only_the_difference

macos_check_reports_and_fails() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  macos_fixture_manifest "$tmp/defaults.txt"
  printf 'com.apple.finder ShowPathbar 0\ncom.apple.dock autohide-delay 0\ncom.apple.screencapture location %s/Screenshots\n' "$tmp/home" > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  if out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  [ "$out" = "com.apple.finder ShowPathbar: want true, have 0" ] || {
    echo "unexpected report: $out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check wrote to defaults"
    return 1
  }
}
check "check reports each difference and never writes" macos_check_reports_and_fails

# A `host:` line must go through `-currentHost` on both read and write, and a
# plain line in the same manifest must not gain it by accident -- the two
# states below are disjoint, so either script touching the wrong one shows up
# as a wrong report or a write on the wrong side.
macos_host_lines_use_currenthost() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  cat > "$tmp/defaults.txt" << 'EOF'
host:NSGlobalDomain    com.apple.mouse.tapBehavior    int    1
NSGlobalDomain         KeyRepeat                       int    2
EOF
  printf 'NSGlobalDomain com.apple.mouse.tapBehavior 0\n' > "$tmp/state_host"
  printf 'NSGlobalDomain KeyRepeat 2\n' > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/writes_host"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" STATE_HOST="$tmp/state_host" \
    WRITES="$tmp/writes" WRITES_HOST="$tmp/writes_host" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > "$tmp/out" || return 1
  diff <(echo "NSGlobalDomain com.apple.mouse.tapBehavior -int 1") "$tmp/writes_host" || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "a host: line wrote to the plain domain:"
    cat "$tmp/writes"
    return 1
  }
  diff <(printf 'host:NSGlobalDomain com.apple.mouse.tapBehavior -> 1\nother apps read the new values when they next launch; keyboard and trackpad changes need a log out and back in\n') "$tmp/out" || return 1

  : > "$tmp/writes_host"
  if out=$(HOME="$tmp/home" STATE="$tmp/state" STATE_HOST="$tmp/state_host" \
    WRITES="$tmp/writes" WRITES_HOST="$tmp/writes_host" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  [ "$out" = "host:NSGlobalDomain com.apple.mouse.tapBehavior: want 1, have 0" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "a host: line reads and writes -currentHost, a plain line does not" macos_host_lines_use_currenthost

# A missing manifest must not read as "the machine matches" -- drift.sh's
# own contract for `check` is 0 (matches) or 1 (differences); anything else
# it treats as a broken checker rather than a clean run, but only if this
# script actually reports it that way instead of exiting 0 on an empty read.
macos_refuses_a_missing_manifest() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  : > "$tmp/writes"
  : > "$tmp/killed"
  rc=0
  out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/does-not-exist.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc on a missing manifest, want 2"
    echo "$out"
    return 1
  }
  case "$out" in
    *"no manifest"*) ;;
    *)
      echo "missing manifest did not mention 'no manifest': $out"
      return 1
      ;;
  esac
  [ ! -s "$tmp/writes" ] || {
    echo "wrote although the manifest could not be read"
    return 1
  }
}

# A MANIFEST override whose directory does not exist either (not just the
# file) is a second way to reach the same bug: the `cd` inside the
# resolution has to be its own command substitution, or a failing `cd` is
# swallowed by `set -e` and the readability check further down catches it
# only by accident, against a garbage path it constructs instead of the one
# asked for. Asserting the message names the path as given is what tells the
# two apart: the accident path can only ever report a mangled one.
macos_refuses_a_manifest_in_a_missing_directory() {
  local tmp rc out want
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  : > "$tmp/writes"
  : > "$tmp/killed"
  want="$tmp/no-such-dir/x.txt"
  rc=0
  out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$want" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc on a manifest in a missing directory, want 2"
    echo "$out"
    return 1
  }
  case "$out" in
    *"$want"*) ;;
    *)
      echo "did not name the requested path ($want): $out"
      return 1
      ;;
  esac
  [ ! -s "$tmp/writes" ] || {
    echo "wrote although the manifest could not be read"
    return 1
  }
}
check "check refuses a missing manifest instead of reading it as a match" macos_refuses_a_missing_manifest
check "check names the requested path when its directory is missing too" macos_refuses_a_manifest_in_a_missing_directory

# The machine's own defaults.txt is read after the shared one, and a missing
# machine profile stops the run before anything is written.
macos_applies_the_machine_overlay() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  macos_stub "$tmp"
  printf 'com.apple.finder ShowPathbar bool true\n' > "$tmp/defaults.txt"
  # No newline at the end, and a space in the value: the two ways the last
  # line of a hand-written overlay has gone missing or been cut short.
  printf 'pl.maketheweb.cleanshotx exportPath string ~/My Shots' > "$tmp/machines/test/defaults.txt"
  : > "$tmp/state"
  : > "$tmp/writes"
  : > "$tmp/killed"
  HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply > /dev/null || return 1
  diff - "$tmp/writes" << EOF || return 1
com.apple.finder ShowPathbar -bool true
pl.maketheweb.cleanshotx exportPath -string $tmp/home/My Shots
EOF
  [ -d "$tmp/home/My Shots" ] || {
    echo "the folder exportPath names was not created whole: $(ls "$tmp/home")"
    return 1
  }
  rm "$tmp/machine"
  : > "$tmp/writes"
  rc=0
  out=$(HOME="$tmp/home" STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/defaults.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/defaults.sh apply 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
    echo "apply exited $rc or wrote with no machine profile: $out"
    return 1
  }
}
check "the machine's defaults.txt is applied after the shared one, last line and folder included, and is required" macos_applies_the_machine_overlay

# ── macOS power ──────────────────────────────────────────────────────────────
# macos/power.sh is the one script here that writes through sudo, so the
# stubs prove two things the defaults tests do not have to: that `apply`
# reaches pmset only through sudo and only for a difference, and that
# `check` never reaches sudo at all. The `pmset` stub answers `-g custom`
# from $STATE, a file in the real command's output shape -- a "Battery
# Power:" section and an "AC Power:" section, one setting per line -- so a
# value under the wrong profile is a real trap the parser can fall into.
# The `sudo` stub records its arguments to $WRITES and runs nothing.
printf '\n%smacOS power%s\n' "$DIM" "$OFF"

power_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/pmset" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = -g ] && [ "$2" = custom ]; then
  cat "$STATE"
  exit 0
fi
echo "pmset stub: unexpected direct call: $*" >&2
exit 99
STUB
  cat > "$dir/bin/sudo" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WRITES"
STUB
  chmod +x "$dir/bin/pmset" "$dir/bin/sudo"
}

# What `pmset -g custom` printed on this machine on 2026-09-15, cut to the
# lines that matter, with the battery powermode as given. AC always reads
# 1 here so a parser that ignores the section header cannot pass.
power_state() {
  cat > "$1" << EOF
Battery Power:
 Sleep On Power Button 1
 powermode            $2
 displaysleep         2
AC Power:
 Sleep On Power Button 1
 powermode            1
 displaysleep         10
EOF
}

power_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 1
  : > "$tmp/writes"
  STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh apply > "$tmp/out" || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "called sudo although everything matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply calls sudo for nothing when the machine already matches" power_apply_is_a_noop_when_matching

power_apply_writes_the_difference_through_sudo() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 0
  : > "$tmp/writes"
  STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh apply > "$tmp/out" || return 1
  diff <(echo "pmset -b powermode 1") "$tmp/writes" || return 1
  diff <(echo "battery powermode -> 1") "$tmp/out" || return 1
}
check "apply writes exactly the differing setting, through sudo, to the battery profile" power_apply_writes_the_difference_through_sudo

power_check_reports_and_never_sudos() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  power_state "$tmp/state" 0
  : > "$tmp/writes"
  if out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  [ "$out" = "battery powermode: want 1, have 0" ] || {
    echo "unexpected report: $out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check called sudo:"
    cat "$tmp/writes"
    return 1
  }
  power_state "$tmp/state" 1
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check) || {
    echo "check exited non-zero with the machine matching"
    return 1
  }
  [ -z "$out" ] || {
    echo "check printed with the machine matching: $out"
    return 1
  }
}
check "check reports the difference, exits 0 on a match, and never calls sudo" power_check_reports_and_never_sudos

# A `pmset -g custom` with no Battery Power section -- a desktop, or a
# pmset that failed -- must not read as "matches", the same contract
# defaults.sh keeps for a missing manifest: 0 and 1 are check's own answers,
# anything else is a broken checker for drift.sh to surface.
power_check_refuses_a_missing_battery_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  power_stub "$tmp"
  printf 'AC Power:\n powermode            1\n' > "$tmp/state"
  : > "$tmp/writes"
  rc=0
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" \
    bash macos/power.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc without a Battery Power profile, want 2"
    echo "$out"
    return 1
  }
  case "$out" in
    *"Battery Power"*) ;;
    *)
      echo "did not name the missing profile: $out"
      return 1
      ;;
  esac
}
check "check refuses a pmset output with no battery profile instead of reading it as a match" power_check_refuses_a_missing_battery_profile

# ── macOS Dock ───────────────────────────────────────────────────────────────
# macos/dock.sh rebuilds the Dock's app section from the machine's dock.txt through
# dockutil. The stub answers `--list` from $STATE in dockutil's own shape --
# label, percent-encoded file URL, section, plist, tab-separated -- and
# records every --add and --remove to $WRITES. The state always carries a
# Downloads stack under persistentOthers, which the script must neither count
# nor remove, and an app whose name has a space, so the URL has to be decoded
# rather than compared raw.
printf '\n%smacOS Dock%s\n' "$DIM" "$OFF"

dock_manifest() {
  local bad f
  ls macos/machines/*/dock.txt > /dev/null 2>&1 || {
    echo "no macos/machines/*/dock.txt at all"
    return 1
  }
  bad=$(for f in macos/machines/*/dock.txt; do
    sed 's/#.*//; s/[[:space:]]*$//' "$f" | awk -v f="$f" '
    NF == 0 { next }
    $0 !~ /^\/.*\.app$/ { print f":"NR": not an absolute path to an .app: "$0; next }
    seen[$0]++ { print f":"NR": listed twice: "$0 }
  '
  done)
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "every machine's dock.txt is one absolute .app path per line, none twice" dock_manifest

dock_stub() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/Applications/Google Chrome.app" "$dir/Applications/Ghostty.app" "$dir/Applications/Notes.app"
  cat > "$dir/bin/dockutil" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  --list)
    [ -z "${LIST_FAILS:-}" ] || { echo "dockutil stub: list failed" >&2; exit 1; }
    cat "$STATE" ;;
  --add | --remove) echo "$*" >> "$WRITES" ;;
  *) echo "dockutil stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  cat > "$dir/bin/killall" << 'STUB'
#!/usr/bin/env bash
echo "$1" >> "$KILLED"
STUB
  chmod +x "$dir/bin/dockutil" "$dir/bin/killall"
  machine_fixture "$dir"
  printf '%s/Applications/Google Chrome.app\n%s/Applications/Ghostty.app\n' "$dir" "$dir" > "$dir/machines/test/dock.txt"
  : > "$dir/writes"
  : > "$dir/killed"
}

# One line of `dockutil --list` for each app path given, in that order,
# followed by the Downloads stack.
dock_state() {
  local out=$1 app enc
  shift
  : > "$out"
  for app in "$@"; do
    enc=${app// /%20}
    printf '%s\tfile://%s/\tpersistentApps\t/Users/x/Library/Preferences/com.apple.dock.plist\n' \
      "$(basename "$app" .app)" "$enc" >> "$out"
  done
  printf 'Downloads\tfile:///Users/x/Downloads/\tpersistentOthers\t/Users/x/Library/Preferences/com.apple.dock.plist\n' >> "$out"
}

dock_run() {
  local tmp=$1
  shift
  STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" \
    PATH="$tmp/bin:$PATH" MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh "$@"
}

dock_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  dock_run "$tmp" apply > "$tmp/out" 2>&1 || {
    cat "$tmp/out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "changed the Dock although it matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/killed" ] || {
    echo "restarted the Dock although nothing changed"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply leaves the Dock alone when it already matches" dock_apply_is_a_noop_when_matching

dock_apply_rebuilds_the_app_section() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  # Wrong order, plus an app the manifest does not declare.
  dock_state "$tmp/state" "$tmp/Applications/Ghostty.app" "$tmp/Applications/Notes.app" "$tmp/Applications/Google Chrome.app"
  dock_run "$tmp" apply > "$tmp/out" || return 1
  diff - "$tmp/writes" << EOF || return 1
--remove Ghostty --no-restart
--remove Notes --no-restart
--remove Google Chrome --no-restart
--add $tmp/Applications/Google Chrome.app --section apps --no-restart
--add $tmp/Applications/Ghostty.app --section apps --no-restart
EOF
  diff <(echo Dock) "$tmp/killed" || return 1
  diff <(echo "Dock -> Google Chrome, Ghostty") "$tmp/out" || return 1
}
check "apply rebuilds only the app section, in order, and restarts the Dock once" dock_apply_rebuilds_the_app_section

dock_check_reports_and_never_writes() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Ghostty.app" "$tmp/Applications/Google Chrome.app"
  if out=$(dock_run "$tmp" check); then
    echo "check exited 0 with a difference present"
    return 1
  fi
  diff - <(printf '%s\n' "$out") << 'EOF' || return 1
Dock: want Google Chrome, Ghostty
Dock: have Ghostty, Google Chrome
EOF
  [ ! -s "$tmp/writes" ] && [ ! -s "$tmp/killed" ] || {
    echo "check changed the Dock"
    return 1
  }
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  out=$(dock_run "$tmp" check) || {
    echo "check exited non-zero with the Dock matching: $out"
    return 1
  }
  [ -z "$out" ] || {
    echo "check printed with the Dock matching: $out"
    return 1
  }
}
check "check reports the difference, exits 0 on a match, and never writes" dock_check_reports_and_never_writes

# A declared app that is not installed -- the normal state of a fresh machine
# before the App Store has run -- must not stop install.sh, and must not
# vanish either: apply builds the Dock from what is there and says what it
# skipped, check keeps reporting it until it is installed or undeclared.
dock_handles_an_app_that_is_not_installed() {
  local tmp out rc
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  printf '%s/Applications/Missing.app\n' "$tmp" >> "$tmp/machines/test/dock.txt"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  dock_run "$tmp" apply > "$tmp/out" 2> "$tmp/err" || {
    echo "apply failed on a missing app"
    cat "$tmp/err"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "rebuilt the Dock although every installed app was already in place:"
    cat "$tmp/writes"
    return 1
  }
  diff <(echo "not installed, left out of the Dock: $tmp/Applications/Missing.app") "$tmp/err" || return 1
  rc=0
  out=$(dock_run "$tmp" check) || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "check exited $rc with a declared app missing, want 1"
    return 1
  }
  [ "$out" = "not installed: $tmp/Applications/Missing.app" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "a declared app that is not installed is skipped by apply and reported by check" dock_handles_an_app_that_is_not_installed

dock_refuses_a_missing_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state"
  rm "$tmp/machine"
  for verb in check apply; do
    rc=0
    out=$(dock_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or changed the Dock with no machine profile: $out"
      return 1
    }
  done
  case "$out" in
    *"no machine profile"*) ;;
    *)
      echo "did not say the profile is missing: $out"
      return 1
      ;;
  esac
}
check "no machine profile is a broken checker, and the Dock is left alone" dock_refuses_a_missing_profile

# `while read` drops a last line with no newline after it, and an editor that
# does not add one is common. The validator reads with awk, which keeps it,
# so the two would disagree in silence.
dock_reads_an_unterminated_last_line() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  printf '%s/Applications/Google Chrome.app\n%s/Applications/Ghostty.app' "$tmp" "$tmp" > "$tmp/machines/test/dock.txt"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app"
  if out=$(dock_run "$tmp" check); then
    echo "check ignored the last line, the one with no newline"
    return 1
  fi
}
check "the last line counts without a newline after it" dock_reads_an_unterminated_last_line

# dockutil missing, or failing to list, is a broken checker -- exit 2, which
# drift.sh reports as such -- and not an empty Dock that `apply` would then
# "fix". PATH is cut to the system directories so the real dockutil in
# Homebrew's cannot answer instead.
dock_refuses_a_missing_or_failing_dockutil() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  rm "$tmp/bin/dockutil"
  for verb in check apply; do
    rc=0
    out=$(STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:/usr/bin:/bin" \
      MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" /bin/bash macos/dock.sh "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "$verb exited $rc without dockutil, want 2: $out"
      return 1
    }
  done
  dock_stub "$tmp"
  rc=0
  out=$(LIST_FAILS=1 dock_run "$tmp" check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "check exited $rc when dockutil --list failed, want 2: $out"
    return 1
  }
  rc=0
  out=$(LIST_FAILS=1 dock_run "$tmp" apply 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] && [ ! -s "$tmp/killed" ] || {
    echo "apply exited $rc or changed the Dock when dockutil --list failed: $out"
    return 1
  }
}
check "a missing or failing dockutil is a broken checker, not an empty Dock" dock_refuses_a_missing_or_failing_dockutil

# Shapes the plain case does not cover. Observed with dockutil 3.1.3 on
# 2026-10-03: Safari, whose /Applications path is a symlink into the system
# cryptex, listed as that cryptex path, bare, with no file:// and no slash;
# and five fields, the bundle id last. Not observed, guarded against: an
# accented name stored decomposed (NFD) while the manifest is typed composed
# (NFC) -- macOS file APIs commonly hand back NFD, and the two would never
# compare equal as strings.
dock_matches_symlinked_and_accented_apps() {
  local tmp nfc
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  # "Cafe" with an acute e, written as bytes: composed (C3 A9) in the
  # manifest, decomposed (65 CC 81) and percent-encoded in the Dock's URL.
  nfc=$(printf 'Caf\xc3\xa9')
  mkdir -p "$tmp/Cryptex/Safari.app" "$tmp/Applications/$nfc.app"
  ln -s "$tmp/Cryptex/Safari.app" "$tmp/Applications/Safari.app"
  printf '%s/Applications/Safari.app\n%s/Applications/%s.app\n' "$tmp" "$tmp" "$nfc" > "$tmp/machines/test/dock.txt"
  {
    printf 'Safari\t%s/Cryptex/Safari.app\tpersistentApps\t/p.plist\tcom.apple.Safari\n' "$(cd -P "$tmp" && pwd)"
    printf '%s\tfile://%s/Applications/Cafe%%CC%%81.app/\tpersistentApps\t/p.plist\tcom.example.cafe\n' "$nfc" "${tmp// /%20}"
  } > "$tmp/state"
  dock_run "$tmp" check > "$tmp/out" 2>&1 || {
    echo "check reported a difference for the same two apps:"
    cat "$tmp/out"
    return 1
  }
  dock_run "$tmp" apply > "$tmp/out" 2>&1 || return 1
  [ ! -s "$tmp/writes" ] && [ ! -s "$tmp/out" ] || {
    echo "apply rebuilt a Dock that already matched:"
    cat "$tmp/writes" "$tmp/out"
    return 1
  }
}
check "a symlinked app and a decomposed accent match their manifest lines" dock_matches_symlinked_and_accented_apps

# A spacer in the app section has an empty label and an empty URL. The
# manifest cannot declare one, so it is drift: check names it, apply removes
# it. Two empty fields in a row are the trap -- split on IFS, tabs collapse
# and the section lands in the wrong field.
dock_reports_and_removes_a_spacer() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  dock_state "$tmp/state" "$tmp/Applications/Google Chrome.app" "$tmp/Applications/Ghostty.app"
  printf '\t\tpersistentApps\t/p.plist\t\n' >> "$tmp/state"
  if out=$(dock_run "$tmp" check); then
    echo "check exited 0 with a spacer in the app section"
    return 1
  fi
  diff - <(printf '%s\n' "$out") << 'EOF' || return 1
Dock: want Google Chrome, Ghostty
Dock: have Google Chrome, Ghostty, spacer
EOF
  dock_run "$tmp" apply > /dev/null || return 1
  grep -qx -- '--remove spacer-tiles --no-restart' "$tmp/writes" || {
    echo "apply did not remove the spacer:"
    cat "$tmp/writes"
    return 1
  }
}
check "a spacer in the app section is reported by check and removed by apply" dock_reports_and_removes_a_spacer

# A Mac with a profile but no dock.txt in it has a Dock nobody declared: not
# a broken checker, but not a match either. check says so until one is
# written; apply leaves the Dock alone.
machine_without_a_dock_manifest_is_reported() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  dock_stub "$tmp"
  rm "$tmp/machines/test/dock.txt"
  dock_state "$tmp/state" "$tmp/Applications/Ghostty.app"
  rc=0
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:$PATH" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh check) || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "check exited $rc with no dock.txt for this machine, want 1: $out"
    return 1
  }
  [ "$out" = "no dock.txt for machine test: the Dock is not declared" ] || {
    echo "unexpected report: $out"
    return 1
  }
  STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:$PATH" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh apply 2> /dev/null || return 1
  [ ! -s "$tmp/writes" ] || {
    echo "apply changed a Dock no manifest declares"
    return 1
  }
  printf '%s/Applications/Ghostty.app\n' "$tmp" > "$tmp/machines/test/dock.txt"
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" KILLED="$tmp/killed" PATH="$tmp/bin:$PATH" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/dock.sh check) || {
    echo "check did not read the machine's dock.txt: $out"
    return 1
  }
}
check "the Dock is read from the machine's dock.txt, and its absence is reported" machine_without_a_dock_manifest_is_reported

# ── macOS file handlers ──────────────────────────────────────────────────────
# macos/handlers.sh sets the default app per file extension through duti. The
# stub answers `-x ext` from $STATE ("ext bundle_id" lines) in duti's
# three-line shape, failing like the real one for an extension with no
# handler, records every `-s` to $WRITES, and fails a `-s` for any bundle id
# listed in $MISSING -- what the real duti does for an app that is not
# installed (error -50, exit 2, seen here on 2026-10-03).
printf '\n%smacOS file handlers%s\n' "$DIM" "$OFF"

handlers_manifest() {
  local bad f
  [ -f macos/handlers.txt ] || {
    echo "macos/handlers.txt missing"
    return 1
  }
  # Checked per pair, shared plus one machine, which is what a machine reads:
  # an extension in both would be set twice, and the last write would win.
  bad=$(for f in macos/handlers.txt macos/machines/*/handlers.txt; do
    [ -f "$f" ] || continue
    if [ "$f" = macos/handlers.txt ]; then
      set -- macos/handlers.txt
    else
      set -- macos/handlers.txt "$f"
    fi
    awk '
    { sub(/#.*/, "") }
    NF == 0 { next }
    NF != 2 { print FILENAME":"FNR": want two fields, extension and bundle id"; next }
    $1 !~ /^[a-z0-9]+$/ { print FILENAME":"FNR": extension is lowercase, without the dot: "$1; next }
    $2 !~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/ { print FILENAME":"FNR": not a bundle id: "$2; next }
    seen[$1]++ { print FILENAME":"FNR": "$1" is also in an earlier file, or twice in this one" }
  ' "$@"
  done)
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "every handlers manifest is extension and bundle id per line, none in two" handlers_manifest

handlers_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/duti" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  -x)
    b=$(awk -v e="$2" '$1 == e { print $2; exit }' "$STATE")
    [ -n "$b" ] || { echo "Failed to get default application for extension '$2'" >&2; exit 2; }
    printf 'Some App\n/Applications/Some App.app\n%s\n' "$b" ;;
  -s)
    if grep -qx "$2" "$MISSING" 2> /dev/null; then
      echo "failed to set $2 as handler for x (error -50)" >&2
      exit 2
    fi
    echo "$*" >> "$WRITES" ;;
  *) echo "duti stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$dir/bin/duti"
  cat > "$dir/handlers.txt" << 'EOF'
# comment
md    abnerworks.Typora     # trailing comment
sh    com.microsoft.VSCode
EOF
  : > "$dir/writes"
  : > "$dir/missing"
  machine_fixture "$dir"
}

handlers_run() {
  local tmp=$1
  shift
  STATE="$tmp/state" WRITES="$tmp/writes" MISSING="$tmp/missing" \
    PATH="$tmp/bin:$PATH" MANIFEST="$tmp/handlers.txt" \
    MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" bash macos/handlers.sh "$@"
}

handlers_apply_is_a_noop_when_matching() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  handlers_run "$tmp" apply > "$tmp/out" 2>&1 || {
    cat "$tmp/out"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "set a handler although everything matched:"
    cat "$tmp/writes"
    return 1
  }
  [ ! -s "$tmp/out" ] || {
    echo "printed output although nothing changed:"
    cat "$tmp/out"
    return 1
  }
}
check "apply sets nothing when every handler already matches" handlers_apply_is_a_noop_when_matching

handlers_apply_sets_only_the_difference() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  # md matches; sh opens in a terminal, which runs the script.
  printf 'md abnerworks.Typora\nsh com.mitchellh.ghostty\n' > "$tmp/state"
  handlers_run "$tmp" apply > "$tmp/out" || return 1
  diff <(echo "-s com.microsoft.VSCode .sh all") "$tmp/writes" || return 1
  diff <(echo "sh -> com.microsoft.VSCode") "$tmp/out" || return 1
}
check "apply sets exactly the differing extensions, for every role" handlers_apply_sets_only_the_difference

handlers_check_reports_and_never_writes() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  # sh has a different handler; md has none at all.
  printf 'sh com.mitchellh.ghostty\n' > "$tmp/state"
  if out=$(handlers_run "$tmp" check); then
    echo "check exited 0 with differences present"
    return 1
  fi
  diff - <(printf '%s\n' "$out") << 'EOF' || return 1
md: want abnerworks.Typora, have unset
sh: want com.microsoft.VSCode, have com.mitchellh.ghostty
EOF
  [ ! -s "$tmp/writes" ] || {
    echo "check set a handler"
    return 1
  }
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  out=$(handlers_run "$tmp" check) || {
    echo "check exited non-zero with every handler matching: $out"
    return 1
  }
  [ -z "$out" ] || {
    echo "check printed with every handler matching: $out"
    return 1
  }
}
check "check reports each difference, exits 0 on a match, and never writes" handlers_check_reports_and_never_writes

# Same contract as the Dock: an app that is not installed yet must not stop
# install.sh, and must not be silent either. The other lines still apply.
handlers_apply_survives_an_app_that_is_not_installed() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  echo abnerworks.Typora > "$tmp/missing"
  printf 'md com.apple.TextEdit\nsh com.mitchellh.ghostty\n' > "$tmp/state"
  handlers_run "$tmp" apply > "$tmp/out" 2> "$tmp/err" || {
    echo "apply failed on an app that is not installed"
    cat "$tmp/err"
    return 1
  }
  diff <(echo "-s com.microsoft.VSCode .sh all") "$tmp/writes" || return 1
  diff <(echo "sh -> com.microsoft.VSCode") "$tmp/out" || return 1
  diff <(echo "md: could not set abnerworks.Typora, left as is (duti: failed to set abnerworks.Typora as handler for x (error -50))") "$tmp/err" || return 1
}
check "apply skips a handler whose app is not installed and sets the rest" handlers_apply_survives_an_app_that_is_not_installed

handlers_refuses_a_missing_manifest() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  rc=0
  out=$(STATE="$tmp/state" WRITES="$tmp/writes" MISSING="$tmp/missing" PATH="$tmp/bin:$PATH" \
    MANIFEST="$tmp/nope/handlers.txt" bash macos/handlers.sh check 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "exited $rc on a missing manifest, want 2: $out"
    return 1
  }
  case "$out" in
    *"no manifest at $tmp/nope/handlers.txt"*) ;;
    *)
      echo "did not name the missing manifest: $out"
      return 1
      ;;
  esac
}
check "check refuses a missing manifest instead of reading it as a match" handlers_refuses_a_missing_manifest

handlers_refuses_a_missing_duti() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  rm "$tmp/bin/duti"
  printf 'md abnerworks.Typora\n' > "$tmp/state"
  for verb in check apply; do
    rc=0
    out=$(STATE="$tmp/state" WRITES="$tmp/writes" MISSING="$tmp/missing" PATH="$tmp/bin:/usr/bin:/bin" \
      MANIFEST="$tmp/handlers.txt" MACHINE_FILE="$tmp/machine" MACHINES="$tmp/machines" \
      /bin/bash macos/handlers.sh "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "$verb exited $rc without duti, want 2: $out"
      return 1
    }
  done
}
check "a missing duti is a broken checker, not every handler unset" handlers_refuses_a_missing_duti

handlers_reads_the_machine_overlay() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'pdf com.adobe.Acrobat.Pro\n' > "$tmp/machines/test/handlers.txt"
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  if out=$(handlers_run "$tmp" check); then
    echo "check exited 0 with the machine's line unmet"
    return 1
  fi
  [ "$out" = "pdf: want com.adobe.Acrobat.Pro, have unset" ] || {
    echo "unexpected report: $out"
    return 1
  }
}
check "the machine's handlers.txt is read after the shared one" handlers_reads_the_machine_overlay

handlers_refuses_a_missing_profile() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'md com.apple.TextEdit\n' > "$tmp/state"
  rm "$tmp/machine"
  for verb in check apply; do
    rc=0
    out=$(handlers_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or set a handler with no machine profile: $out"
      return 1
    }
  done
}
check "no machine profile is a broken checker, and no handler is set" handlers_refuses_a_missing_profile

handlers_reads_an_unterminated_last_line() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  handlers_stub "$tmp"
  printf 'pdf com.adobe.Acrobat.Pro' > "$tmp/machines/test/handlers.txt"
  printf 'md abnerworks.Typora\nsh com.microsoft.VSCode\n' > "$tmp/state"
  if out=$(handlers_run "$tmp" check); then
    echo "check ignored the machine's last line, the one with no newline"
    return 1
  fi
}
check "the last line counts without a newline after it" handlers_reads_an_unterminated_last_line

# ── Touch ID for sudo ────────────────────────────────────────────────────────
# macos/touchid.sh turns on Touch ID for sudo through /etc/pam.d/sudo_local,
# the file Apple keeps across system updates. Same contract as power.sh:
# check never reaches sudo, apply reaches it once and only for a difference.
# PAM_DIR points both at a fixture holding Apple's template, and the sudo
# stub records its arguments and then runs them, so `tee` really writes the
# fixture file.
printf '\n%sTouch ID for sudo%s\n' "$DIM" "$OFF"

touchid_stub() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/pam.d"
  cat > "$dir/bin/sudo" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WRITES"
exec "$@"
STUB
  chmod +x "$dir/bin/sudo"
  # Apple's template as macOS 27.0 ships it, read 2026-10-03.
  cat > "$dir/pam.d/sudo_local.template" << 'EOF'
# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
#auth       sufficient     pam_tid.so
EOF
  : > "$dir/writes"
}

touchid_run() {
  local tmp=$1
  shift
  WRITES="$tmp/writes" PATH="$tmp/bin:$PATH" PAM_DIR="$tmp/pam.d" bash macos/touchid.sh "$@"
}

touchid_check_reports_and_never_sudos() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  rc=0
  out=$(touchid_run "$tmp" check) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "Touch ID for sudo is off: no pam_tid.so line in $tmp/pam.d/sudo_local" ] || {
    echo "check exited $rc with no sudo_local: $out"
    return 1
  }
  # The template's own line is commented out, which is still off.
  cp "$tmp/pam.d/sudo_local.template" "$tmp/pam.d/sudo_local"
  rc=0
  touchid_run "$tmp" check > /dev/null || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "check exited $rc with the line commented out, want 1"
    return 1
  }
  [ ! -s "$tmp/writes" ] || {
    echo "check called sudo:"
    cat "$tmp/writes"
    return 1
  }
}
check "check reports Touch ID off, commented line included, and never calls sudo" touchid_check_reports_and_never_sudos

touchid_apply_writes_the_template_once() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  out=$(touchid_run "$tmp" apply) || return 1
  [ "$out" = "Touch ID for sudo -> on" ] || {
    echo "unexpected output: $out"
    return 1
  }
  diff - "$tmp/pam.d/sudo_local" << 'EOF' || return 1
# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
auth       sufficient     pam_tid.so
EOF
  [ "$(wc -l < "$tmp/writes")" -eq 1 ] || {
    echo "apply called sudo more than once:"
    cat "$tmp/writes"
    return 1
  }
  : > "$tmp/writes"
  out=$(touchid_run "$tmp" apply) || return 1
  [ -z "$out" ] && [ ! -s "$tmp/writes" ] || {
    echo "a second apply called sudo or printed: $out"
    return 1
  }
  touchid_run "$tmp" check > /dev/null || {
    echo "check did not see the line apply wrote"
    return 1
  }
}
check "apply writes Apple's template with the line uncommented, once, through sudo" touchid_apply_writes_the_template_once

# A sudo_local someone already wrote -- another PAM module, a comment -- is
# theirs: apply adds the one line and keeps the rest.
touchid_apply_keeps_an_existing_file() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  printf '# mine\nauth       optional       pam_example.so\n' > "$tmp/pam.d/sudo_local"
  touchid_run "$tmp" apply > /dev/null || return 1
  diff - "$tmp/pam.d/sudo_local" << 'EOF' || return 1
# mine
auth       optional       pam_example.so
auth       sufficient     pam_tid.so
EOF
}
check "apply adds the line to an existing sudo_local and keeps what was there" touchid_apply_keeps_an_existing_file

touchid_refuses_without_a_template() {
  local tmp rc out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  touchid_stub "$tmp"
  rm "$tmp/pam.d/sudo_local.template"
  for verb in check apply; do
    rc=0
    out=$(touchid_run "$tmp" "$verb" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$tmp/writes" ] || {
      echo "$verb exited $rc or called sudo with no template and no sudo_local: $out"
      return 1
    }
  done
}
check "no template and no sudo_local is a broken checker, not a file to invent" touchid_refuses_without_a_template

# ── Git guard ────────────────────────────────────────────────────────────────
# The guard exists because permission rules cannot express these decisions. A
# rule matches a command prefix, so `git push origin main --force` slips past
# `Bash(git push --force *)` -- git permutes flags and the matcher does not.
# And a deny rule cannot carry an exception, so blocking `git clean -fdx` would
# also block `git clean -n`, which destroys nothing and is how you check.
#
# Like the statusline, it is a pure function from a JSON payload to a verdict,
# which is the property that makes it testable rather than merely written.
printf '\n%sGit guard%s\n' "$DIM" "$OFF"

# Exit 2 is the block. Every other status falls through to the permission
# rules, which means a crashed guard fails open -- the reason the deny list
# still carries the operations that have no safe form at all.
# Absolute, because the reset cases run from a temp repository: a relative
# path there resolves to nothing, every call returns 127, and the tests pass
# while exercising the guard not at all. That is not hypothetical -- it is what
# the first run of these tests did, and only an inverted stub revealed it.
GUARD=$PWD/claude/git-guard.sh

# Runs a command without the variables a hook, or a shell, can hand git. The
# guard tests build a throwaway repository and ask git about it, and this
# script is run by the pre-commit hook: git hands that hook GIT_INDEX_FILE,
# and for `git commit -a` it is an absolute path to this repository's index
# lock. Inherited, it wins over the temp directory's own .git, so a clean temp
# tree reads as dirty and the guard blocks. Plain `git commit` passes a
# relative `.git/index`, which resolves inside the temp directory by accident
# -- every commit here since the guard tests landed was a plain one, and the
# first `-a` was refused. GIT_DIR and GIT_WORK_TREE are not exported by git
# (measured with a hook that printed its environment); they are cleared for
# the shell that might. The checks must mean the same thing run by hand, by
# the hook and in CI, so every git call that is about the throwaway
# repository goes through here -- and only those: `git ls-files` and `git
# grep` above are about this repository and must read the index the commit
# is being made from.
hookless() {
  env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX "$@"
}

guard_verdict() {
  local payload rc
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1")
  printf '%s' "$payload" | hookless "$GUARD" > /dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then printf 'blocked'; else printf 'allowed'; fi
}

guard_decisions() {
  local want cmd got fails=0
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    got=$(guard_verdict "$cmd")
    if [ "$got" != "$want" ]; then
      printf 'want %s, got %s: %s\n' "$want" "$got" "$cmd"
      fails=1
    fi
  done << 'CASES'
blocked|git clean -fdx
blocked|git clean -f
blocked|git clean --force -d
blocked|mise exec -- git clean -fdx
blocked|git push --force origin main
blocked|git push origin main --force
blocked|git push -f origin main
blocked|git push --force-with-lease origin main
blocked|npm test && git clean -fdx
allowed|git clean -n
allowed|git clean --dry-run -d
allowed|git status
allowed|git push origin main
allowed|git push --force-with-lease origin feature/x
allowed|git log --oneline
allowed|echo git clean -fdx
allowed|git commit -m "clean -fdx"
CASES
  return "$fails"
}
check "guard verdicts match the table" guard_decisions

# The reset rule is the one that reads the repository rather than the command:
# `git reset --hard` with nothing uncommitted is a no-op, and blocking it is
# friction that buys nothing. These two cases differ only in whether work
# exists to lose, so a guard that ignored state would fail one of them.
guard_reset_clean_tree() {
  local dir out
  dir=$(mktemp -d)
  hookless git -C "$dir" init -q
  hookless git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  out=$(cd "$dir" && guard_verdict 'git reset --hard')
  rm -r "$dir"
  [ "$out" = allowed ] || {
    echo "clean tree should allow reset --hard, got $out"
    return 1
  }
}
check "reset --hard is allowed when nothing would be lost" guard_reset_clean_tree

guard_reset_dirty_tree() {
  local dir out
  dir=$(mktemp -d)
  hookless git -C "$dir" init -q
  hookless git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo change > "$dir/tracked.txt"
  hookless git -C "$dir" add tracked.txt
  out=$(cd "$dir" && guard_verdict 'git reset --hard')
  rm -r "$dir"
  [ "$out" = blocked ] || {
    echo "dirty tree should block reset --hard, got $out"
    return 1
  }
}
check "reset --hard is blocked when it would discard work" guard_reset_dirty_tree

# The same verdict with the `git commit -a` hook environment in place: an
# absolute GIT_INDEX_FILE set at the call, which is what the hook does to this
# whole script. Only that variable -- git does not export GIT_DIR to a hook,
# measured with a hook that printed its environment -- and the index belongs
# to a decoy repository built here, never to this one. The first version of
# this check set GIT_DIR to this repository's own .git, and while it was red
# the fixture's `commit --allow-empty -m init` landed three empty commits on
# two real branches. A test that mutates the thing it checks when it fails is
# worse than no test. The decoy tracks one file so that, judged through its
# index, the temp repository's empty tree reads as a deletion: without
# hookless the guard sees that and blocks.
#
# Both fixtures run this way, because they fail differently. The clean one
# reads the decoy's file as deleted and blocks, which the verdict shows. The
# dirty one's verdict is blocked either way -- a file git does not know about
# is uncommitted work too -- so its failure is not in the verdict but in the
# side effect: its `git add` is the one call here that writes into the
# foreign index, which under the real hook is the commit being made. So the
# decoy's index is read back afterwards and must still list only its own file.
guard_tests_under_hook() {
  local decoy out rc=0 listed
  decoy=$(mktemp -d)
  hookless git -C "$decoy" init -q
  echo x > "$decoy/decoy.txt"
  hookless git -C "$decoy" add decoy.txt
  hookless git -C "$decoy" -c user.email=t@t -c user.name=t commit -q -m init
  out=$(GIT_INDEX_FILE="$decoy/.git/index" guard_reset_clean_tree 2>&1 &&
    GIT_INDEX_FILE="$decoy/.git/index" guard_reset_dirty_tree 2>&1) || rc=$?
  listed=$(hookless git -C "$decoy" ls-files)
  rm -r "$decoy"
  [ "$rc" -eq 0 ] || {
    echo "under a hook's git environment: $out"
    return 1
  }
  [ "$listed" = decoy.txt ] || {
    echo "the dirty fixture wrote into the foreign index: $listed"
    return 1
  }
}
check "the guard tests ignore the git environment a hook exports" guard_tests_under_hook

# A guard that is not wired runs never, and because it fails open that costs
# nothing visible: no error, no warning, just no guard. The tests above prove
# the script decides correctly; this one proves the settings ask it to.
guard_is_declared() {
  python3 - << 'DECL'
import json
import sys

settings = json.load(open('claude/settings.json', encoding='utf-8'))
entries = settings.get('hooks', {}).get('PreToolUse', [])
commands = [
    hook.get('command', '')
    for entry in entries
    for hook in entry.get('hooks', [])
]
if not any('git-guard.sh' in command for command in commands):
    print('claude/settings.json declares no PreToolUse hook running git-guard.sh')
    sys.exit(1)
DECL
}
check "the guard is wired into settings" guard_is_declared

# The settings merge replaces arrays whole, which is deliberate for `deny` and
# destructive for `hooks`: this machine carries PreToolUse entries from other
# tools, and a wholesale replace deletes them without saying so. It very
# nearly did -- a dry run of the merge returned a PreToolUse array holding the
# guard and nothing else. Twice, because installing must be repeatable: the
# guard appears once however many times you run it.
install_preserves_foreign_hooks() {
  local tmp steps live commands count
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 3\. Symlinks/,/^# --- 3c\./p' install.sh
  } > "$steps"

  live="$tmp/home/.claude/settings.json"
  mkdir -p "$tmp/home/.claude"
  cat > "$live" << 'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": "/opt/other-tool/hook.sh" }]
      }
    ]
  }
}
JSON

  HOME="$tmp/home" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1
  HOME="$tmp/home" DOTFILES="$PWD" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1

  commands=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command] | join(" ")' "$live")
  case "$commands" in
    *other-tool*) ;;
    *)
      echo "the merge dropped a PreToolUse hook this repo does not own: $commands"
      return 1
      ;;
  esac

  count=$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command | test("git-guard"))] | length' "$live")
  [ "$count" = 1 ] || {
    echo "expected the guard exactly once after two installs, found $count"
    return 1
  }
}
check "installing keeps hooks this repo does not own" install_preserves_foreign_hooks

# The merge never deletes, so a key the repo declares can still vanish from the
# live file afterwards -- `/model` clearing `model` did exactly that, and drift.sh
# reported nothing because it only looked at keys present on both sides. Run its
# settings check against fixtures: one key missing from the live file, one
# missing key the check excludes on purpose, and one that matches.
drift_reports_missing_settings() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  # Up to the heredoc terminator: the Python inside closes its own braces at
  # column 0, so the function's `}` is not the first one.
  {
    sed -n '/^claude_settings_drift() {$/,/^PY$/p' drift.sh
    echo '}'
  } > "$fn"
  grep -qF 'LOCAL_ONLY' "$fn" || {
    echo "could not extract claude_settings_drift from drift.sh"
    return 1
  }

  mkdir -p "$tmp/repo/claude" "$tmp/home/.claude"
  echo '{"theme": "dark", "model": "opus", "hooks": {}}' > "$tmp/repo/claude/settings.json"
  echo '{"theme": "dark"}' > "$tmp/home/.claude/settings.json"

  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && HOME="$tmp/home" bash -c '. "$1" && claude_settings_drift' _ "$fn") || return 1
  [ "$out" = 'model: repo says "opus", this machine does not set it' ] || {
    echo "expected one line about model, got: ${out:-nothing}"
    return 1
  }
}
check "drift.sh reports a declared setting missing from this machine" drift_reports_missing_settings

# A server only one profile declares is declared all the same. Against fixtures:
# registered servers matching both manifests report nothing, and one the
# profile declares but this machine lacks is named.
drift_counts_profile_mcp_servers() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  {
    sed -n '/^mcp_servers_drift() {$/,/^MCP$/p' drift.sh
    echo '}'
  } > "$fn"
  grep -qF 'mcpServers' "$fn" || {
    echo "could not extract mcp_servers_drift from drift.sh"
    return 1
  }

  mkdir -p "$tmp/repo/claude" "$tmp/machine" "$tmp/home"
  echo '{"mcpServers": {"shared": {"type": "http", "url": "https://s.invalid"}}}' > "$tmp/repo/claude/mcp.json"
  echo '{"mcpServers": {"local": {"type": "stdio", "command": "l", "args": []}}}' > "$tmp/machine/mcp.json"
  echo '{"mcpServers": {"shared": {"type": "http", "url": "https://s.invalid"}, "local": {"type": "stdio", "command": "l", "args": []}}}' > "$tmp/home/.claude.json"

  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && HOME="$tmp/home" machine_dir="$tmp/machine" bash -c '. "$1" && mcp_servers_drift' _ "$fn") || return 1
  [ -z "$out" ] || {
    echo "expected no drift with both manifests registered, got: $out"
    return 1
  }

  echo '{"mcpServers": {"shared": {"type": "http", "url": "https://s.invalid"}}}' > "$tmp/home/.claude.json"
  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && HOME="$tmp/home" machine_dir="$tmp/machine" bash -c '. "$1" && mcp_servers_drift' _ "$fn") || return 1
  [ "$out" = 'declared but not registered: local' ] || {
    echo "expected the profile's server reported missing, got: ${out:-nothing}"
    return 1
  }
}
check "drift.sh counts the profile's MCP servers as declared" drift_counts_profile_mcp_servers

# A pin and the machine can disagree in two directions, and they close in
# opposite ways. When `specify self upgrade` moved the machine past the pin,
# drift.sh said "./install.sh", and running it put the old version back. So:
# machine ahead -> move the pin; machine behind -> install. Against a stub `uv`
# whose tool dir holds one receipt.
drift_uv_pin_direction() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  {
    sed -n '/^uv_tools_drift() {$/,/^PY$/p' drift.sh
    echo '}'
  } > "$fn"
  grep -qF 'uv-receipt.toml' "$fn" || {
    echo "could not extract uv_tools_drift from drift.sh"
    return 1
  }

  mkdir -p "$tmp/repo" "$tmp/bin" "$tmp/tools/demo"
  printf '#!/bin/sh\necho %s/tools\n' "$tmp" > "$tmp/bin/uv"
  chmod +x "$tmp/bin/uv"
  echo 'demo  git+https://example.invalid/demo.git@v1.9.0' > "$tmp/repo/uv-tools.txt"

  receipt() {
    printf '[tool]\nrequirements = [{ name = "demo", git = "%s?rev=%s" }]\n' "$1" "$2" \
      > "$tmp/tools/demo/uv-receipt.toml"
  }
  drift() {
    # shellcheck disable=SC2016  # expanded by the inner shell
    (cd "$tmp/repo" && PATH="$tmp/bin:$PATH" bash -c '. "$1" && uv_tools_drift' _ "$fn")
  }

  # 1.10 against 1.9: ahead by number, behind as a string, so this is the case
  # that tells the two comparisons apart.
  receipt https://example.invalid/demo.git v1.10.0
  out=$(drift) || return 1
  case "$out" in
    *'this machine is ahead'*'uv-tools.txt'*'downgrade'*) ;;
    *)
      echo "machine ahead of the pin, expected the pin moved and a downgrade warning, got: ${out:-nothing}"
      return 1
      ;;
  esac

  # Behind, the same tag spelled shorter, and a higher tag from another
  # repository all close with an install: only the same source can be ahead.
  for case in 'https://example.invalid/demo.git v1.8.0' \
    'https://example.invalid/demo.git v1.9.0.0' \
    'https://example.invalid/fork.git v2.0.0'; do
    # shellcheck disable=SC2086  # two words on purpose
    receipt $case
    out=$(drift) || return 1
    case "$out" in
      *'is ahead'*)
        echo "$case: expected ./install.sh, got: $out"
        return 1
        ;;
      *': ./install.sh') ;;
      *)
        echo "$case: expected ./install.sh, got: ${out:-nothing}"
        return 1
        ;;
    esac
  done
}
check "drift.sh says which way a moved uv pin closes" drift_uv_pin_direction

# ── Result ───────────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  printf '\n%sAll checks passed%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sSome checks failed%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
