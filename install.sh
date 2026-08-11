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

link "$DOTFILES/zsh/.zshrc" "$HOME/.zshrc"
link "$DOTFILES/zsh/.zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
link "$DOTFILES/git/.gitconfig" "$HOME/.gitconfig"
link "$DOTFILES/git/.gitignore_global" "$HOME/.gitignore_global"
link "$DOTFILES/mise/config.toml" "$HOME/.config/mise/config.toml"
link "$DOTFILES/vscode/settings.json" "$HOME/Library/Application Support/Code/User/settings.json"
link "$DOTFILES/ghostty/config" "$HOME/.config/ghostty/config"
link "$DOTFILES/starship.toml" "$HOME/.config/starship.toml"
link "$DOTFILES/claude/statusline.sh" "$HOME/.claude/statusline.sh"
link "$DOTFILES/claude/subagent-statusline.sh" "$HOME/.claude/subagent-statusline.sh"
link "$DOTFILES/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"

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

# --- 4. Git identity (not versioned) ---
if [ ! -f "$HOME/.gitconfig.local" ]; then
  log "Your git identity is missing. Creating ~/.gitconfig.local"
  read -rp "    Name for commits:  " GIT_NAME
  read -rp "    Email for commits: " GIT_EMAIL
  cat > "$HOME/.gitconfig.local" << EOF
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
