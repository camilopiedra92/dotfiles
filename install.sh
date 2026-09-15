#!/usr/bin/env bash
# Rebuilds the development environment on a new machine.
# Usage:  git clone <repo> ~/dotfiles && ~/dotfiles/install.sh
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

# --- 1. Homebrew ---
if ! command -v brew > /dev/null 2>&1; then
  log "Installing Homebrew (it will ask for your password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# --- 2. Brewfile packages ---
# --no-upgrade because this script installs, and upgrading is a different
# decision. `brew bundle install` upgrades every outdated dependency by default,
# which makes running this after a `git pull` -- to pick up a new symlink, say --
# also download whatever grew stale since the last time, apps included.
#
# Nothing is lost on the machine this script is written for: a new one has
# nothing installed to upgrade, so it installs current versions either way. What
# it costs is that bumping a pinned version in the Brewfile no longer reaches an
# existing machine through here; `brew upgrade <name>` is where that lives now.
log "Installing Homebrew packages"
brew bundle install --no-upgrade --file="$DOTFILES/Brewfile"

# --- 3. Symlinks ---
log "Linking dotfiles"
link() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  # If a real file already exists (not a symlink), back it up before replacing it
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "$dest.backup.$(date +%Y%m%d%H%M%S)"
    echo "    backed up: $dest"
  fi
  ln -sfn "$src" "$dest"
  echo "    $dest -> $src"
}

# .zshenv is linked twice, to the same file, because zsh picks exactly one of the
# two depending on how it was started -- it never reads both.
#
#   ZDOTDIR unset in the environment  ->  $HOME/.zshenv       (cold start)
#   ZDOTDIR already exported          ->  $ZDOTDIR/.zshenv    (nested shell)
#
# The second case is every shell spawned from one this repo already configured:
# a git hook, `zsh -c` from an editor, anything under a running session. With
# only the $HOME copy linked, those shells read neither file and start with the
# bare system PATH -- no mise shims, so `node: command not found` from a hook
# while the terminal right next to it resolves node fine.
#
# Linking both is safe rather than merely tolerable: `typeset -U path` makes the
# file idempotent by construction, which is the same property $ZDOTDIR/.zprofile
# already relies on when it re-sources it.
link "$DOTFILES/zsh/.zshenv" "$HOME/.zshenv"
link "$DOTFILES/zsh/.zshenv" "$HOME/.config/zsh/.zshenv"
# Under ZDOTDIR and not $HOME: once .zshenv exports ZDOTDIR, zsh looks for
# .zprofile, .zshrc and .zlogin there. See the file for why it exists at all.
link "$DOTFILES/zsh/.zprofile" "$HOME/.config/zsh/.zprofile"
link "$DOTFILES/zsh/.zshrc" "$HOME/.config/zsh/.zshrc"
link "$DOTFILES/zsh/.zsh_plugins.txt" "$HOME/.config/zsh/.zsh_plugins.txt"
# XDG paths, not ~/.gitconfig and ~/.gitignore_global. git reads both locations
# but the legacy one wins, so the two cannot coexist: step 4 below deletes them.
link "$DOTFILES/git/config" "$HOME/.config/git/config"
link "$DOTFILES/git/ignore" "$HOME/.config/git/ignore"
# 700 is for the private key step 4b puts beside this link, and it is set on
# every run, not only at creation, because a ~/.ssh that already existed
# arrives with whatever mode it had. The config itself ssh checks on its own:
# it refuses one that is group- or world-writable or not owned by you, which
# a link into a repo you own satisfies. config.local next to it is per
# machine and never versioned.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
link "$DOTFILES/ssh/config" "$HOME/.ssh/config"
link "$DOTFILES/mise/config.toml" "$HOME/.config/mise/config.toml"
link "$DOTFILES/vscode/settings.json" "$HOME/Library/Application Support/Code/User/settings.json"
link "$DOTFILES/ghostty/config" "$HOME/.config/ghostty/config"
link "$DOTFILES/starship.toml" "$HOME/.config/starship.toml"
link "$DOTFILES/claude/statusline.sh" "$HOME/.claude/statusline.sh"
link "$DOTFILES/claude/subagent-statusline.sh" "$HOME/.claude/subagent-statusline.sh"
link "$DOTFILES/claude/git-guard.sh" "$HOME/.claude/git-guard.sh"
link "$DOTFILES/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
# Dropped without the .sh so it reads as a command: ~/.local/bin is already on
# PATH, which is what lets the alias be `sudo dev-nuke` and not a path.
link "$DOTFILES/bin/dev-nuke.sh" "$HOME/.local/bin/dev-nuke"
# Same reasoning. This one replaces an `npm link`, which put the command in the
# npm prefix of a single Node version and left no trace in any repo.
link "$DOTFILES/bin/aware.sh" "$HOME/.local/bin/aware"
# Not a command you run: it is what ~/.claude.json points the ynab MCP server
# at, so the server logs into its own directory instead of into whichever
# repository the editor was started in. See the file.
link "$DOTFILES/bin/ynab-mcp.sh" "$HOME/.local/bin/ynab-mcp"

# --- 3b. Claude Code settings ---
# settings.json is not symlinked: Claude Code rewrites it on its own (the
# theme, /config, the permissions you approve on the fly) and a symlink would
# end up overwritten. CLAUDE.md IS symlinked above: only you edit that one.
#
# The settings do not live in here but in claude/settings.json, as data. This
# block is only the merge mechanism, so adding a new setting means editing that
# JSON and this step is never touched again.
#
# `$live * $repo` is jq's recursive merge, with the repo on the right so it wins
# key by key. Two intended consequences: any local key we do not manage is
# preserved (the ones Claude Code writes by itself), and arrays are replaced
# whole instead of concatenated, so `deny` ends up being the repo's list and
# not the historical union of every installation.
#
# Hooks are the one place where replacing an array whole is wrong, so they are
# held out of that merge and spliced afterwards. A machine carries PreToolUse
# entries this repo does not own -- another tool's integration, installed by
# that tool -- and the plain merge deletes them without a word. It nearly did:
# a dry run returned a PreToolUse array holding this repo's guard and nothing
# else. The splice drops only the entries running a command the repo declares,
# which is what makes a second run land on the same file as the first.
log "Applying Claude Code settings"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
jq -s '
  .[0] as $live
  | .[1] as $repo
  | ([($repo.hooks // {}) | to_entries[] | .value[] | .hooks[]? | .command]) as $owned
  | ($live * ($repo | del(.hooks)))
  | reduce (($repo.hooks // {}) | to_entries[]) as $event (
      .;
      .hooks[$event.key] = (
        (((.hooks // {})[$event.key] // [])
          | map(select(([.hooks[]?.command] - $owned) == [.hooks[]?.command])))
        + $event.value
      )
    )
' "$CLAUDE_SETTINGS" "$DOTFILES/claude/settings.json" \
  > "$CLAUDE_SETTINGS.tmp" &&
  mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"

# --- 3c. Pre-commit hook ---
# core.hooksPath points git at a directory inside the repo, so the hook is
# versioned and arrives with a clone. Hooks dropped in .git/hooks are not: they
# only ever protect the machine they were written on.
log "Enabling the pre-commit hook"
git -C "$DOTFILES" config core.hooksPath githooks

# --- 3d. Retire the pre-XDG paths ---
# git reads ~/.gitconfig and $XDG_CONFIG_HOME/git/config both, and the legacy
# one overrides. Leaving it behind would mean the file linked above is read and
# then quietly overruled, which is worse than either path on its own. Same for
# the ignore file: naming it through core.excludesfile is what disables the
# default XDG path, so the old one has to go for the new one to take effect.
#
# ~/.zprofile is the opposite failure and worth the separate mention: zsh stops
# reading it the moment .zshenv exports ZDOTDIR, so the Homebrew installer's
# copy does not conflict with anything -- it simply never runs again. Retiring
# it is about not leaving a file that reads like live shell configuration and
# has not been executed since.
#
# Only ever removes a symlink this repo created. A real file there belongs to
# someone else's setup and is moved aside, never deleted.
retire() {
  local legacy="$1"
  [ -e "$legacy" ] || [ -L "$legacy" ] || return 0
  if [ -L "$legacy" ]; then
    rm "$legacy"
    echo "    removed legacy symlink: $legacy"
  else
    mv "$legacy" "$legacy.backup.$(date +%Y%m%d%H%M%S)"
    echo "    backed up legacy file:  $legacy"
  fi
}

log "Retiring the pre-XDG paths"
retire "$HOME/.gitconfig"
retire "$HOME/.gitignore_global"
retire "$HOME/.zshrc"
retire "$HOME/.zprofile"
retire "$HOME/.zsh_plugins.txt"
# Generated by antidote, never versioned. It is rebuilt under ZDOTDIR on the
# next shell, so the stale copy is only a leftover.
retire "$HOME/.zsh_plugins.zsh"

# Shell history is the one thing here that is neither config nor disposable:
# losing it is losing years of typing. Moved, never retired.
ZSH_HISTORY="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
if [ -f "$HOME/.zsh_history" ] && [ ! -f "$ZSH_HISTORY" ]; then
  log "Moving your shell history to $ZSH_HISTORY"
  mkdir -p "$(dirname "$ZSH_HISTORY")"
  mv "$HOME/.zsh_history" "$ZSH_HISTORY"
fi

# --- 4. Git identity (not versioned) ---
# Sits next to the config that includes it, which is why the [include] there can
# be the relative "config.local" and stays correct wherever the pair ends up.
GIT_IDENTITY="$HOME/.config/git/config.local"
mkdir -p "$(dirname "$GIT_IDENTITY")"

# An earlier version of this script wrote the identity to ~/.gitconfig.local.
# Move it rather than ask again for something already answered once.
if [ ! -f "$GIT_IDENTITY" ] && [ -f "$HOME/.gitconfig.local" ]; then
  log "Moving your git identity to $GIT_IDENTITY"
  mv "$HOME/.gitconfig.local" "$GIT_IDENTITY"
fi

if [ ! -f "$GIT_IDENTITY" ]; then
  log "Your git identity is missing. Creating $GIT_IDENTITY"
  read -rp "    Name for commits:  " GIT_NAME
  read -rp "    Email for commits: " GIT_EMAIL
  cat > "$GIT_IDENTITY" << EOF
[user]
	name = $GIT_NAME
	email = $GIT_EMAIL
EOF
fi

# --- 4b. Signing key ---
# One ed25519 key for both authentication and signing. Generated here, on
# the machine, with a passphrase you type now and the Keychain remembers;
# the private half never leaves ~/.ssh and never enters this repo. Each
# piece checks for itself before acting, so a second run does nothing.
SSH_KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
  log "Generating your SSH key (choose a passphrase; the Keychain will remember it)"
  ssh-keygen -t ed25519 -C "$(git config --file "$GIT_IDENTITY" user.email)" -f "$SSH_KEY"
fi
PUBKEY=$(awk '{ print $2 }' "$SSH_KEY.pub")
# Nothing above logs gh in, and a new machine is not: `gh auth status` then
# exits 1, and under set -e that would end the script here with its message
# captured in a variable and never shown. So the login is done here, the
# second thing this step asks of you (a browser round trip), asking for the
# key scopes at the same time so the refresh below has nothing to do.
if ! gh auth status > /dev/null 2>&1; then
  log "Logging gh into GitHub (opens a browser)"
  gh auth login -h github.com -s admin:public_key -s admin:ssh_signing_key
fi
# A token from an earlier login cannot manage keys. Without these two scopes
# `gh ssh-key list` prints a 404 to stderr and nothing to stdout, exit 0 --
# an empty list that reads as "not registered" -- and `add` fails. So they
# are asked for first, in the browser, and only while missing: the third
# interactive moment of this step, and one a second run never sees.
GH_SCOPES=$(gh auth status 2>&1) || {
  printf '%s\n' "$GH_SCOPES"
  exit 1
}
if ! grep -qF "'admin:public_key'" <<< "$GH_SCOPES" ||
  ! grep -qF "'admin:ssh_signing_key'" <<< "$GH_SCOPES"; then
  log "Granting gh the scopes that manage SSH keys (opens a browser)"
  gh auth refresh -h github.com -s admin:public_key -s admin:ssh_signing_key
fi
# GitHub keeps authentication and signing keys in separate lists, and a key
# in one is not in the other. Both are added, each only if missing. One
# listing covers both, tab-separated: TITLE, KEY, ADDED, ID, TYPE. The key
# column holds `ssh-ed25519 <base64> [comment]`, so the base64 is looked for
# inside it -- with index() and not ~, because base64 contains `+` and as a
# regex a `++` never matches, which would re-add one key in a hundred on
# every run -- and the type is compared whole in its own column rather than
# searched for on the row, where a title like "signing key" would match too.
registered() {
  gh ssh-key list 2> /dev/null |
    awk -F'\t' -v k="$PUBKEY" -v t="$1" 'index($2, k) > 0 && $5 == t { found = 1 } END { exit !found }'
}
for type in authentication signing; do
  if ! registered "$type"; then
    log "Registering the key with GitHub for $type"
    gh ssh-key add "$SSH_KEY.pub" --type "$type" --title "$(scutil --get LocalHostName)"
  fi
done
# The signing key is identity, so it lives with the identity and not in the
# versioned config. `git config --file` is what makes the write idempotent:
# it replaces the value instead of appending a second [user] section.
git config --file "$GIT_IDENTITY" user.signingkey "$SSH_KEY.pub"
# The switch goes next to the key, not into git/config: that file is live from
# the first clone, and gpgsign without a key refuses every commit on the
# machine. Written here, the two cannot disagree.
git config --file "$GIT_IDENTITY" commit.gpgsign true
git config --file "$GIT_IDENTITY" tag.gpgsign true
# What local verification checks against. Rewritten whole from the current
# identity and key so it can never hold a stale line.
printf '%s %s\n' "$(git config --file "$GIT_IDENTITY" user.email)" "$(cat "$SSH_KEY.pub")" \
  > "$HOME/.config/git/allowed_signers"

# --- 5. Runtimes ---
log "Installing runtimes with mise"
mise install

# --- 6. Rust ---
if ! rustc --version > /dev/null 2>&1; then
  log "Installing the Rust toolchain"
  /opt/homebrew/opt/rustup/bin/rustup default stable
fi

# --- 7. CLI tools from uv ---
# uv-tools.txt exists because `uv tool` is the one package manager here with no
# manifest to read; see the header of that file for why these live neither in the
# Brewfile nor in mise.
#
# Unconditional, and unlike step 2 this one does converge the machine on the
# declared version: `uv tool install` re-run with an identical reference is a
# cached no-op, and re-run with a reference that moved replaces the tool in place
# without needing --force. Both verified, the second by installing v0.16.2 and
# then asking for v0.16.4.
#
# That is the opposite choice from --no-upgrade above, for a reason that is not
# inconsistency. There, the version comes from the internet, so "install" and
# "upgrade to whatever shipped since" are genuinely different decisions. Here the
# version is written down in this repo, so converging on it is not an upgrade --
# it is what applying the file means, and the alternative is a pin that only
# takes effect on machines that never had the tool.
log "Installing CLI tools with uv"
while read -r name ref; do
  [ -n "$name" ] || continue
  uv tool install --from "$ref" "$name"
done < <(sed 's/#.*//' "$DOTFILES/uv-tools.txt")

# VS Code extensions need no step of their own: the Brewfile declares them with
# `vscode "..."` entries and `brew bundle install` installs them in step 2.

# --- 8. Claude Code MCP servers ---
# User-scope servers live in ~/.claude.json, a file Claude Code owns and rewrites
# freely, so they are neither symlinked nor merged in: the CLI is the interface
# that file is meant to be changed through, and claude/mcp.json is what the CLI
# is told. The file uses the same shape as a project's .mcp.json, so an entry
# moves between the two without translation.
#
# Converges on the manifest the way step 7 does. A server already registered
# with the same definition is left alone; one that differs is removed and added
# back, because `claude mcp add-json` refuses to overwrite and that pair is the
# only edit the CLI offers. Servers the manifest does not name are not touched:
# drift.sh is what reports those.
#
# The comparison reads ~/.claude.json directly rather than parsing `claude mcp
# get`, whose output is prose for a person. Reading is safe where writing would
# not be: Claude Code rewrites this file underneath anything that edits it.
log "Registering Claude Code MCP servers"
CLAUDE_STATE="$HOME/.claude.json"
[ -f "$CLAUDE_STATE" ] || echo '{}' > "$CLAUDE_STATE"
for name in $(jq -r '.mcpServers | keys[]' "$DOTFILES/claude/mcp.json"); do
  want=$(jq -c --arg n "$name" '.mcpServers[$n]' "$DOTFILES/claude/mcp.json")
  if jq -e --arg n "$name" --argjson want "$want" '.mcpServers[$n] == $want' \
    "$CLAUDE_STATE" > /dev/null; then
    continue
  fi
  if jq -e --arg n "$name" '.mcpServers[$n] != null' "$CLAUDE_STATE" > /dev/null; then
    claude mcp remove "$name" --scope user
  fi
  claude mcp add-json "$name" "$want" --scope user
done

# --- 9. macOS defaults ---
# The system layer this repo used to leave to hand: Finder, Dock, keyboard,
# trackpad, screenshots. Declared in macos/defaults.txt, applied only where
# the machine differs, so a second run writes nothing and restarts nothing.
# Last because a Finder restart in the middle of a run is a surprise, and
# because nothing above depends on it.
log "Applying macOS defaults"
"$DOTFILES/macos/defaults.sh" apply

log "Done. Open Ghostty."
