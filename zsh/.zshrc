# ═══════════════════════════════════════════════════════════
#  .zshrc  —  gestionado en ~/dotfiles
#  Plugins: antidote con carga estatica (ver .zsh_plugins.txt)
# ═══════════════════════════════════════════════════════════

# ---------- PATH ----------
# Homebrew normalmente lo pone .zprofile, que solo se lee en shells de login.
# Esto cubre los que no lo son: terminal integrado de editores, tmux, `zsh`
# lanzado dentro de otro shell. Con la guarda no duplica entradas.
if [[ -x /opt/homebrew/bin/brew && ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

export PATH="$HOME/.local/bin:$PATH"             # claude, binarios de usuario
export PATH="/opt/homebrew/opt/rustup/bin:$PATH" # rustup no se enlaza solo

# ---------- Historial ----------
# Lo mas util y lo que casi nadie configura: por defecto zsh guarda pocas
# lineas y las pierde al cerrar varias ventanas a la vez.
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS      # un comando repetido no ensucia el historial
setopt HIST_IGNORE_SPACE         # comando con espacio delante = no se guarda
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY               # al expandir !!, muestra antes de ejecutar
setopt SHARE_HISTORY             # historial compartido entre terminales
setopt EXTENDED_HISTORY          # guarda timestamp de cada comando

# ---------- Comportamiento ----------
setopt AUTO_CD                   # "Development" == "cd Development"
setopt AUTO_PUSHD                # cada cd apila el anterior
setopt PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS      # permite # comentarios en el prompt
setopt NO_BEEP

# ---------- Plugins (antidote) ----------
# Red de seguridad: varios plugins de ohmyzsh escriben aqui y fuera del
# framework la variable no existe.
export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
[[ -d "$ZSH_CACHE_DIR/completions" ]] || mkdir -p "$ZSH_CACHE_DIR/completions"

# Carga estatica: antidote solo se ejecuta si .zsh_plugins.txt ha cambiado.
# En el arranque normal se hace un unico `source` de un fichero ya generado.
zsh_plugins_txt="$HOME/.zsh_plugins.txt"
zsh_plugins_zsh="$HOME/.zsh_plugins.zsh"
if [[ ! ${zsh_plugins_zsh} -nt ${zsh_plugins_txt} ]]; then
  source /opt/homebrew/opt/antidote/share/antidote/antidote.zsh
  antidote bundle <"${zsh_plugins_txt}" >| "${zsh_plugins_zsh}"
fi
source "${zsh_plugins_zsh}"

# ---------- Completado ----------
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'   # ignora mayus/minus
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
# fzf-tab sustituye al menu nativo, asi que se desactiva para no duplicar
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:complete:z:*'  fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:*' switch-group '<' '>'

# ---------- Runtimes ----------
# mise gestiona node, python, go... segun el mise.toml de cada proyecto
eval "$(mise activate zsh)"

# ---------- Prompt ----------
eval "$(starship init zsh)"

# ---------- Navegacion inteligente ----------
# zoxide aprende de tus cd: "z dotfiles" salta ahi desde cualquier sitio
eval "$(zoxide init zsh)"

# ---------- Busqueda difusa ----------
# Ctrl+R  historial   |   Ctrl+T  ficheros   |   Alt+C  cd a directorio
source <(fzf --zsh)
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'

# ---------- Teclas ----------
# Flecha arriba/abajo buscan en el historial por lo ya escrito
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^[[1;5C' forward-word      # Ctrl+derecha
bindkey '^[[1;5D' backward-word     # Ctrl+izquierda

# ---------- Alias ----------
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first --git'
alias la='eza -la --icons --group-directories-first --git'
alias lt='eza --tree --level=2 --icons'
alias cat='bat --style=plain --paging=never'
alias cd='z'

alias dotfiles='cd ~/dotfiles'
alias reload='exec zsh'

# Actualizar todo el entorno de una vez (antidote incluido)
alias update-all='brew upgrade && brew cleanup && mise upgrade && antidote update'

# ---------- Editor ----------
export EDITOR="code --wait"
export VISUAL="$EDITOR"

# ---------- Claude Code ----------
alias c='claude'
alias cc='claude --continue'    # retomar la ultima sesion en esta carpeta

# ---------- Local (no versionado) ----------
# Para secretos, tokens y ajustes de esta maquina concreta
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
