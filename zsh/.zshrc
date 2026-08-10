# ═══════════════════════════════════════════════════════════
#  .zshrc  —  gestionado en ~/dotfiles
#  Sin Oh My Zsh a proposito: son ~3000 lineas para lo que aqui
#  se resuelve en 60, y es la causa habitual de shells lentos.
# ═══════════════════════════════════════════════════════════

# ---------- PATH ----------
export PATH="$HOME/.local/bin:$PATH"            # claude, binarios de usuario
export PATH="/opt/homebrew/opt/rustup/bin:$PATH" # rustup no se enlaza solo

# ---------- Historial ----------
# Lo mas util y lo que casi nadie configura: por defecto zsh guarda
# unas pocas lineas y las pierde al cerrar varias ventanas a la vez.
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS      # un comando repetido no ensucia el historial
setopt HIST_IGNORE_SPACE         # comando con espacio delante = no se guarda
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY               # al expandir !!, muestra antes de ejecutar
setopt SHARE_HISTORY             # historial compartido entre terminales abiertas
setopt EXTENDED_HISTORY          # guarda timestamp de cada comando

# ---------- Comportamiento ----------
setopt AUTO_CD                   # "Development" == "cd Development"
setopt AUTO_PUSHD                # cada cd apila el anterior
setopt PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS      # permite # comentarios en el prompt
setopt NO_BEEP

# ---------- Autocompletado ----------
autoload -Uz compinit
# Regenera el cache solo una vez al dia: arranque mas rapido
if [[ -n "$HOME/.zcompdump"(#qN.mh+24) ]]; then compinit; else compinit -C; fi

zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'   # ignora mayus/minus
zstyle ':completion:*' menu select                        # menu navegable
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

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

# ---------- Sugerencias y colores ----------
# El orden importa: syntax-highlighting debe ir al final del fichero.
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# ---------- Alias ----------
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first --git'
alias la='eza -la --icons --group-directories-first --git'
alias lt='eza --tree --level=2 --icons'
alias cat='bat --style=plain --paging=never'
alias cd='z'

alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'

alias dotfiles='cd ~/dotfiles'
alias reload='exec zsh'

# Actualizar todo el entorno de una vez
alias update-all='brew upgrade && brew cleanup && mise upgrade'

# ---------- Editor ----------
export EDITOR="code --wait"
export VISUAL="$EDITOR"

# ---------- Claude Code ----------
alias c='claude'
alias cc='claude --continue'    # retomar la ultima sesion en esta carpeta

# ---------- Local (no versionado) ----------
# Para secretos, tokens y ajustes de esta maquina concreta
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"

# ---------- DEBE IR AL FINAL ----------
source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
