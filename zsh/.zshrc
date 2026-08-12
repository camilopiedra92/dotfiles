# ═══════════════════════════════════════════════════════════
#  .zshrc  —  managed in ~/dotfiles
#  Plugins: antidote with static loading (see .zsh_plugins.txt)
# ═══════════════════════════════════════════════════════════

# ---------- PATH ----------
# Homebrew usually sets this in .zprofile, which is only read by login shells.
# This covers the ones that are not: editor integrated terminals, tmux, `zsh`
# launched inside another shell. The guard keeps entries from being duplicated.
if [[ -x /opt/homebrew/bin/brew && ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

export PATH="$HOME/.local/bin:$PATH"             # claude, user binaries
export PATH="/opt/homebrew/opt/rustup/bin:$PATH" # rustup does not symlink itself
# Keg-only too: Homebrew keeps versioned formulae out of the main prefix so two
# major versions can coexist. Without this there is no psql or pg_dump.
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"

# ---------- Homebrew ----------
export HOMEBREW_NO_ENV_HINTS=1                # stop repeating hints already read
export HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1

# ---------- History ----------
# The most useful thing and the one almost nobody configures: by default zsh
# keeps few lines and loses them when several windows close at once.
#
# Under state and not config: this is data the shell writes, not something you
# edit or would ever want versioned. XDG draws that line and zsh, being older
# than the spec, does not -- hence the explicit path.
HISTFILE="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
[[ -d "${HISTFILE:h}" ]] || mkdir -p "${HISTFILE:h}"
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS      # a repeated command does not clutter history
setopt HIST_IGNORE_SPACE         # command with a leading space = not saved
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY               # when expanding !!, show before running
setopt SHARE_HISTORY             # history shared across terminals
setopt EXTENDED_HISTORY          # store a timestamp for each command

# ---------- Behavior ----------
setopt AUTO_CD                   # "Development" == "cd Development"
setopt AUTO_PUSHD                # every cd pushes the previous one
setopt PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS      # allow # comments at the prompt
setopt NO_BEEP

# ---------- Plugins (antidote) ----------
# Safety net: several ohmyzsh plugins write here and outside the framework the
# variable does not exist.
export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
[[ -d "$ZSH_CACHE_DIR/completions" ]] || mkdir -p "$ZSH_CACHE_DIR/completions"

# Static loading: antidote only runs if .zsh_plugins.txt has changed. On a
# normal startup this is a single `source` of an already generated file.
zsh_plugins_txt="${ZDOTDIR:-$HOME}/.zsh_plugins.txt"
zsh_plugins_zsh="${ZDOTDIR:-$HOME}/.zsh_plugins.zsh"
if [[ ! ${zsh_plugins_zsh} -nt ${zsh_plugins_txt} ]]; then
  source /opt/homebrew/opt/antidote/share/antidote/antidote.zsh
  antidote bundle <"${zsh_plugins_txt}" >| "${zsh_plugins_zsh}"
fi
source "${zsh_plugins_zsh}"

# ---------- Completion ----------
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'   # case insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
# fzf-tab replaces the native menu, so it is disabled to avoid duplication
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:complete:z:*'  fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:*' switch-group '<' '>'

# ---------- Runtimes ----------
# mise manages node, python, go... per the mise.toml of each project
eval "$(mise activate zsh)"

# ---------- Prompt ----------
eval "$(starship init zsh)"

# ---------- Smart navigation ----------
# zoxide learns from your cd's: "z dotfiles" jumps there from anywhere
eval "$(zoxide init zsh)"

# ---------- Fuzzy finding ----------
# Ctrl+R  history   |   Ctrl+T  files   |   Alt+C  cd into a directory
source <(fzf --zsh)
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'

# ---------- Keys ----------
# Up/down arrows search history by what you have already typed
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^[[1;5C' forward-word      # Ctrl+right
bindkey '^[[1;5D' backward-word     # Ctrl+left

# ---------- Aliases ----------
alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first --git'
alias la='eza -la --icons --group-directories-first --git'
alias lt='eza --tree --level=2 --icons'
alias cat='bat --style=plain --paging=never'
alias cd='z'

alias dotfiles='cd ~/dotfiles'
alias reload='exec zsh'

# Resets a machine left in a bad state: hung apps, dev servers still holding a
# port, stale DNS. Needs root for `purge`; see bin/dev-nuke.sh.
alias nuke='sudo dev-nuke'

# Update the whole environment at once (antidote included)
alias update-all='brew upgrade && brew cleanup && mise upgrade && antidote update'

# ---------- Editor ----------
export EDITOR="code --wait"
export VISUAL="$EDITOR"

# ---------- Claude Code ----------
alias c='claude'
alias cc='claude --continue'    # resume the last session in this folder

# ---------- Greeting ----------
# Around 10ms, so the cost is not the reason for the guard: a banner reprinted
# by every nested shell turns a greeting into noise. SHLVL is 1 in a terminal
# tab and in an editor's integrated terminal, and only grows when a shell is
# opened inside another one.
[[ $SHLVL -eq 1 ]] && fastfetch

# ---------- Local (not versioned) ----------
# For secrets, tokens and settings specific to this machine. Next to this file
# rather than in $HOME, so everything zsh reads lives in one directory.
[ -f "${ZDOTDIR:-$HOME}/.zshrc.local" ] && source "${ZDOTDIR:-$HOME}/.zshrc.local"
