# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

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
  # Two dangling links: one left by a skill since deleted from the repo, one
  # another tool put there. Install must drop the first and keep the second.
  # The other tool's directory exists and only its skill is gone, so the link
  # is kept by the path comparison, not by a directory that cannot be entered.
  mkdir -p "$tmp/home/.claude/skills" "$tmp/elsewhere"
  ln -s "$tmp/dotfiles/claude/skills/deleted" "$tmp/home/.claude/skills/deleted"
  ln -s "$tmp/elsewhere/theirs" "$tmp/home/.claude/skills/theirs"
  # And one into a directory a tool has since uninstalled: its parent cannot
  # be entered, which must neither stop install nor drop the link.
  ln -s "$tmp/uninstalled/x" "$tmp/home/.claude/skills/orphan"
  # The same deleted-skill case, made through a symlinked alias of the repo.
  ln -s "$tmp/dotfiles" "$tmp/alias"
  ln -s "$tmp/alias/claude/skills/gone" "$tmp/home/.claude/skills/gone"
  # A real directory where a skill link goes. Its backup must land outside
  # ~/.claude/skills, where Claude Code would load it as one more skill.
  mkdir -p "$tmp/home/.claude/skills/brainstorm"
  echo old > "$tmp/home/.claude/skills/brainstorm/SKILL.md"
  echo old > "$tmp/home/.claude/skills/diagnose"
  # The links point into a copy, not into this tree: a step that writes through
  # a link (ln -s without -n onto a linked directory) would otherwise write
  # into the repository being checked.
  rsync -a --exclude .git "$PWD/" "$tmp/dotfiles/" || return 1
  HOME="$tmp/home" DOTFILES="$tmp/dotfiles" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1
  HOME="$tmp/home" DOTFILES="$tmp/dotfiles" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1

  [ -L "$tmp/home/.config/zsh/.zshrc" ] || {
    echo ".zshrc was not symlinked"
    return 1
  }
  [ "$(readlink "$tmp/home/.config/zsh/.zshrc")" = "$tmp/dotfiles/zsh/.zshrc" ] || {
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
  # A skill is a directory, and ln -s onto a link that already points at one
  # descends into it unless -n is given: the second run would then leave a
  # stray brainstorm/brainstorm link inside the repo instead of failing.
  local skill
  for skill in "$tmp"/dotfiles/claude/skills/*/; do
    skill=$(basename "$skill")
    [ -f "$tmp/home/.claude/skills/$skill/SKILL.md" ] || {
      echo "the $skill skill is not reachable under ~/.claude/skills"
      return 1
    }
  done
  [ ! -L "$tmp/home/.claude/skills/deleted" ] || {
    echo "a link to a skill no longer in the repo was kept"
    return 1
  }
  [ -L "$tmp/home/.claude/skills/theirs" ] || {
    echo "a skill link another tool owns was removed"
    return 1
  }
  [ ! -L "$tmp/home/.claude/skills/gone" ] || {
    echo "a link to a deleted skill made through an alias of the repo was kept"
    return 1
  }
  [ -L "$tmp/home/.claude/skills/orphan" ] || {
    echo "a link into an uninstalled tool's directory was removed"
    return 1
  }
  # find, not a glob, so a hidden backup counts as inside too.
  if find "$tmp/home/.claude/skills" -mindepth 1 -maxdepth 1 -name '*backup*' | grep -q .; then
    echo "something in the way was backed up inside ~/.claude/skills"
    return 1
  fi
  ls "$tmp"/home/.claude/skills.backup.*/brainstorm/SKILL.md > /dev/null 2>&1 || {
    echo "the directory in the way was not backed up"
    return 1
  }
  ls "$tmp"/home/.claude/skills.backup.*/diagnose > /dev/null 2>&1 || {
    echo "the file in the way was not backed up"
    return 1
  }
  [ ! -e "$tmp/dotfiles/claude/skills/brainstorm/brainstorm" ] || {
    echo "the second run linked the skill inside itself"
    return 1
  }
  # The routed Spec Kit commands (specs/003-sdd-model-routing): sdd-run is
  # what the owner runs, sdd-step what the workflow's steps run; both find
  # their dotfiles by resolving these links.
  local cmd
  for cmd in sdd-run sdd-step; do
    [ "$(readlink "$tmp/home/.local/bin/$cmd")" = "$tmp/dotfiles/bin/$cmd.sh" ] || {
      echo "$tmp/home/.local/bin/$cmd is not a link to bin/$cmd.sh: $(readlink "$tmp/home/.local/bin/$cmd")"
      return 1
    }
  done
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

  # No item, an item holding an empty password -- what `security ... -w` stored
  # on 2026-10-05 when run from a session that could not answer its prompt --
  # and one holding only whitespace. All must stop the wrapper, not start the
  # server.
  rm "$tmp/started"
  for stub in '#!/bin/sh\nexit 44\n' '#!/bin/sh\necho\n' '#!/bin/sh\necho "  "\n'; do
    printf '%b' "$stub" > "$tmp/bin/security"
    if out=$(PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" ./bin/ynab-mcp.sh 2>&1); then
      echo "the wrapper succeeded with no usable token in the Keychain"
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
  done
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
    inside=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_GLOBAL="$home/.config/git/config" git -C "$home/work/client/repo" config user.email)
    outside=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_GLOBAL="$home/.config/git/config" git -C "$home/elsewhere" config user.email)
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
