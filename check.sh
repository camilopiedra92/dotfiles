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
check "claude mcp manifest" python3 -c "
import json
m = json.load(open('claude/mcp.json'))
servers = m['mcpServers']
assert isinstance(servers, dict) and servers, 'mcpServers must be a non-empty object'
for name, server in servers.items():
    assert server.get('type') in ('http', 'sse', 'stdio', 'ws'), f'{name}: type missing or unknown'
    assert ('url' in server) == (server['type'] != 'stdio'), f'{name}: url and type disagree'
    assert ('command' in server) == (server['type'] == 'stdio'), f'{name}: command and type disagree'
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

# Step 8 has the same split as step 7: whether `claude mcp` registers a server
# is Claude Code's problem, but which servers it is asked to add, remove, or
# leave alone is decided here, from a comparison against ~/.claude.json. So it
# runs with HOME pointed at a fixture state file and a `claude` that records
# its arguments, and the fixture covers each branch of that decision once: a
# server already registered as declared, one registered differently, one not
# registered at all, and one registered that the manifest does not name.
mcp_step() {
  local tmp steps
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"

  {
    echo 'log() { :; }'
    sed -n '/^# --- 8\. Claude Code MCP servers/,/^# --- 9\./p' install.sh
  } > "$steps"
  grep -qF 'claude mcp add-json' "$steps" || {
    echo "could not extract step 8 from install.sh"
    return 1
  }
  one_step_only "$steps" || return 1

  mkdir -p "$tmp/claude" "$tmp/home" "$tmp/bin"
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

  HOME="$tmp/home" PATH="$tmp/bin:$PATH" DOTFILES="$tmp" \
    bash -euo pipefail "$steps" > /dev/null || return 1

  # Order is by name, which is what `jq keys` yields, so the expectation is
  # stable. `same` and `extra` must produce no call at all.
  cat > "$tmp/want" << 'WANT'
mcp remove changed --scope user
mcp add-json changed {"type":"http","url":"https://changed.invalid/v2"} --scope user
mcp add-json missing {"type":"stdio","command":"missing-mcp","args":[]} --scope user
WANT
  diff -u "$tmp/want" "$tmp/calls" || return 1

  # A state file that does not exist yet -- a machine on its first run -- must
  # be created rather than tripped over, and every server then added.
  rm "$tmp/home/.claude.json"
  : > "$tmp/calls"
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" DOTFILES="$tmp" \
    bash -euo pipefail "$steps" > /dev/null || return 1
  [ "$(grep -c 'mcp add-json' "$tmp/calls")" -eq 3 ] || {
    echo "first run did not add every declared server:"
    cat "$tmp/calls"
    return 1
  }
  ! grep -q 'mcp remove' "$tmp/calls" || {
    echo "first run tried to remove from an empty state file"
    return 1
  }
}
check "install.sh registers the MCP servers the manifest declares" mcp_step

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
    [ "$(wc -l < "$home/.config/git/allowed_signers")" -eq 1 ] || {
      echo "$start: allowed_signers has $(wc -l < "$home/.config/git/allowed_signers") lines"
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

# ── macOS defaults ───────────────────────────────────────────────────────────
# macos/defaults.txt is the fourth manifest here and the only one whose
# consumer is a script of this repo's own. So the parsing is where the bugs
# would be, and it is exercised against a stub `defaults` that records what
# it was asked and answers `read` from a fixture: the real one writes to this
# machine's preferences, which a check must never do.
printf '\n%smacOS defaults%s\n' "$DIM" "$OFF"

macos_manifest() {
  local bad
  # sed's "No such file" goes to its own stderr, not into $bad, so a missing
  # manifest would otherwise feed awk nothing and read as zero problems.
  [ -f macos/defaults.txt ] || {
    echo "macos/defaults.txt missing"
    return 1
  }
  # `host:` is the one prefix defaults.sh interprets (it strips it and adds
  # `-currentHost`), so it is the one place a typo'd or unknown prefix has to
  # be refused here -- otherwise `hots:NSGlobalDomain` reads as a plain
  # domain and `defaults` would happily create a plist literally named that.
  bad=$(sed 's/#.*//' macos/defaults.txt | awk '
    NF == 0 { next }
    NF < 4 { print NR": fewer than four fields"; next }
    $1 ~ /:/ && $1 !~ /^host:./ { print NR": unknown domain prefix "$1; next }
    NF > 4 && $3 != "string" { print NR": extra fields"; next }
    $3 !~ /^(bool|int|float|string)$/ { print NR": unknown type "$3; next }
    $3 == "bool" && $4 !~ /^(true|false)$/ { print NR": bool must be true or false" }
    $3 == "int" && $4 !~ /^-?[0-9]+$/ { print NR": int must be an integer" }
    $3 == "float" && $4 !~ /^-?[0-9]+(\.[0-9]+)?$/ { print NR": float must be a number" }
  ')
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}
check "macos/defaults.txt has domain key type value per line" macos_manifest

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
    bash macos/defaults.sh apply > "$tmp/out" || return 1
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
    bash macos/defaults.sh apply > "$tmp/out" || return 1
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
    bash macos/defaults.sh check); then
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
    bash macos/defaults.sh apply > "$tmp/out" || return 1
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
    bash macos/defaults.sh check); then
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
    bash macos/defaults.sh check 2>&1) || rc=$?
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
    bash macos/defaults.sh check 2>&1) || rc=$?
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

# ── Result ───────────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  printf '\n%sAll checks passed%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sSome checks failed%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
