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
  check "shellcheck" shellcheck -x ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/*
else
  skip "shellcheck" "brew install shellcheck"
fi

# shfmt reads .editorconfig, so the style lives there and not in flags here:
# the editor, this check and the hook cannot drift apart if there is only one
# definition to read.
if command -v shfmt > /dev/null 2>&1; then
  check "shfmt" shfmt -d ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/*
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

syntax_bash() { for f in ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/*; do bash -n "$f" || return 1; done; }
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
# CI pins these four and verifies them by checksum; the Brewfile installs
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
  esac
}

versions_match() {
  local status=0 tool var want have
  for pair in shellcheck:SHELLCHECK_VERSION shfmt:SHFMT_VERSION \
    actionlint:ACTIONLINT_VERSION ghostty:GHOSTTY_VERSION; do
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

# tomllib is stdlib from 3.11 on, and macOS still ships 3.9 at /usr/bin/python3
# — so this check's real dependency is a python newer than the system one, which
# it was not declaring. Unguarded it did not skip, it FAILED, with
# `ModuleNotFoundError: No module named 'tomllib'` under a heading that reads
# "toml". That names the wrong culprit: the file is fine and the interpreter is
# old, but the run says the config is broken.
#
# Which interpreter answers is decided by PATH, so this is the .zshenv failure
# in another coat: a commit made from a GUI launched by launchd gets the system
# python and a bad verdict, while the same commit from a terminal gets mise's
# and a good one. The guard cannot make the check run there, but it can stop it
# from blaming the config, and under strict it still refuses to pass.
#
# mise parses TOML too and would need no guard, but CI does not install it, so
# there it would skip -- and a skip is a failure under CI. Adding mise to the
# workflow to validate two files is a dependency this does not need.
if python3 -c 'import tomllib' 2> /dev/null; then
  check "toml" python3 -c "
import tomllib
for f in ('starship.toml', 'mise/config.toml'):
    tomllib.load(open(f, 'rb'))
"
else
  skip "toml" "python 3.11+ for tomllib, this one is $(python3 -V 2>&1 | cut -d' ' -f2)"
fi

check "gitconfig" git config --file git/config --list

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
