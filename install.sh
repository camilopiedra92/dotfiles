#!/usr/bin/env bash
# Reconstruye el entorno de desarrollo en una maquina nueva.
# Uso:  git clone <repo> ~/dotfiles && ~/dotfiles/install.sh
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

# --- 1. Homebrew ---
if ! command -v brew >/dev/null 2>&1; then
  log "Instalando Homebrew (pedira tu password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# --- 2. Paquetes del Brewfile ---
log "Instalando paquetes de Homebrew"
brew bundle install --file="$DOTFILES/Brewfile"

# --- 3. Symlinks ---
log "Enlazando dotfiles"
link() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  # Si ya existe un archivo real (no symlink), lo respalda antes de sustituirlo
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "$dest.backup.$(date +%Y%m%d%H%M%S)"
    echo "    respaldado: $dest"
  fi
  ln -sfn "$src" "$dest"
  echo "    $dest -> $src"
}

link "$DOTFILES/zsh/.zshrc"             "$HOME/.zshrc"
link "$DOTFILES/zsh/.zsh_plugins.txt"   "$HOME/.zsh_plugins.txt"
link "$DOTFILES/git/.gitconfig"         "$HOME/.gitconfig"
link "$DOTFILES/git/.gitignore_global"  "$HOME/.gitignore_global"
link "$DOTFILES/mise/config.toml"       "$HOME/.config/mise/config.toml"
link "$DOTFILES/vscode/settings.json"   "$HOME/Library/Application Support/Code/User/settings.json"
link "$DOTFILES/ghostty/config"         "$HOME/.config/ghostty/config"
link "$DOTFILES/starship.toml"          "$HOME/.config/starship.toml"
link "$DOTFILES/claude/statusline.sh"          "$HOME/.claude/statusline.sh"
link "$DOTFILES/claude/subagent-statusline.sh" "$HOME/.claude/subagent-statusline.sh"

# --- 3b. Statuslines de Claude Code ---
# settings.json no se enlaza: Claude Code lo reescribe solo (tema, /config...)
# y un symlink acabaria sobrescrito. Se hace merge de los bloques que nos
# importan, que ademas deja el paso idempotente.
log "Registrando las statuslines en Claude Code"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
jq '.statusLine = {
      type: "command",
      command: "~/.claude/statusline.sh",
      padding: 0,
      refreshInterval: 60
    }
    | .subagentStatusLine = {
      type: "command",
      command: "~/.claude/subagent-statusline.sh"
    }' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" \
  && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"

# --- 4. Identidad de git (no se versiona) ---
if [ ! -f "$HOME/.gitconfig.local" ]; then
  log "Falta tu identidad de git. Creando ~/.gitconfig.local"
  read -rp "    Nombre para los commits: " GIT_NAME
  read -rp "    Email para los commits:  " GIT_EMAIL
  cat > "$HOME/.gitconfig.local" <<EOF
[user]
	name = $GIT_NAME
	email = $GIT_EMAIL
EOF
fi

# --- 5. Runtimes ---
log "Instalando runtimes con mise"
mise install

# --- 6. Rust ---
if ! rustc --version >/dev/null 2>&1; then
  log "Instalando toolchain de Rust"
  /opt/homebrew/opt/rustup/bin/rustup default stable
fi

# Las extensiones de VS Code no necesitan paso propio:
# el Brewfile las declara con entradas `vscode "..."` y las instala
# `brew bundle install` en el paso 2.

log "Listo. Abre Ghostty."
