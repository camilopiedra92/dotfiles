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
log "Installing Homebrew packages"
brew bundle install --file="$DOTFILES/Brewfile"

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

# .zshenv is the exception that has to stay in $HOME: zsh reads it before it can
# know about ZDOTDIR, and all it does is point at the directory below.
link "$DOTFILES/zsh/.zshenv" "$HOME/.zshenv"
# Under ZDOTDIR and not $HOME: once .zshenv exports ZDOTDIR, zsh looks for
# everything except .zshenv there. See the file for why it exists at all.
link "$DOTFILES/zsh/.zprofile" "$HOME/.config/zsh/.zprofile"
link "$DOTFILES/zsh/.zshrc" "$HOME/.config/zsh/.zshrc"
link "$DOTFILES/zsh/.zsh_plugins.txt" "$HOME/.config/zsh/.zsh_plugins.txt"
# XDG paths, not ~/.gitconfig and ~/.gitignore_global. git reads both locations
# but the legacy one wins, so the two cannot coexist: step 4 below deletes them.
link "$DOTFILES/git/config" "$HOME/.config/git/config"
link "$DOTFILES/git/ignore" "$HOME/.config/git/ignore"
link "$DOTFILES/mise/config.toml" "$HOME/.config/mise/config.toml"
link "$DOTFILES/vscode/settings.json" "$HOME/Library/Application Support/Code/User/settings.json"
link "$DOTFILES/ghostty/config" "$HOME/.config/ghostty/config"
link "$DOTFILES/starship.toml" "$HOME/.config/starship.toml"
link "$DOTFILES/claude/statusline.sh" "$HOME/.claude/statusline.sh"
link "$DOTFILES/claude/subagent-statusline.sh" "$HOME/.claude/subagent-statusline.sh"
link "$DOTFILES/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
# Dropped without the .sh so it reads as a command: ~/.local/bin is already on
# PATH, which is what lets the alias be `sudo dev-nuke` and not a path.
link "$DOTFILES/bin/dev-nuke.sh" "$HOME/.local/bin/dev-nuke"

# --- 3b. Claude Code settings ---
# settings.json is not symlinked: Claude Code rewrites it on its own (the
# theme, /config, the permissions you approve on the fly) and a symlink would
# end up overwritten. CLAUDE.md IS symlinked above: only you edit that one.
#
# The settings do not live in here but in claude/settings.json, as data. This
# block is only the merge mechanism, so adding a new setting means editing that
# JSON and this step is never touched again.
#
# `.[0] * .[1]` is jq's recursive merge, with the repo on the right so it wins
# key by key. Two intended consequences: any local key we do not manage is
# preserved (the ones Claude Code writes by itself), and arrays are replaced
# whole instead of concatenated, so `deny` ends up being the repo's list and
# not the historical union of every installation.
log "Applying Claude Code settings"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$DOTFILES/claude/settings.json" \
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

# --- 5. Runtimes ---
log "Installing runtimes with mise"
mise install

# --- 6. Rust ---
if ! rustc --version > /dev/null 2>&1; then
  log "Installing the Rust toolchain"
  /opt/homebrew/opt/rustup/bin/rustup default stable
fi

# VS Code extensions need no step of their own: the Brewfile declares them with
# `vscode "..."` entries and `brew bundle install` installs them in step 2.

log "Done. Open Ghostty."
