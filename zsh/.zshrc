# ---------- PATH ----------
# Binarios de usuario (claude, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Rust: la formula de Homebrew no enlaza rustup al PATH principal
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

# ---------- Runtimes ----------
# mise gestiona node, python, go, java... por proyecto via mise.toml
# Respeta tambien .nvmrc, .python-version y .tool-versions
eval "$(mise activate zsh)"
