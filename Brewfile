# Static checker for GitHub Actions workflow files
brew "actionlint"
# Plugin manager for zsh, inspired by antigen and antibody
brew "antidote"
# Clone of cat(1) with syntax highlighting and Git integration
brew "bat"
# Resource monitor. Not a development tool in the strict sense, and here anyway:
# what you reach for when a build pins a core or a container eats the machine.
brew "btop"
# Modern, maintained replacement for ls
brew "eza"
# Like neofetch, but much faster because written mostly in C
brew "fastfetch"
# Simple, fast and user-friendly alternative to find
brew "fd"
# Command-line fuzzy finder written in Go
brew "fzf"
# Disk usage analyzer with console interface written in Go
brew "gdu"
# GitHub command-line tool
brew "gh"
# macOS already ships git through the Xcode command line tools, and this is here
# anyway. Two reasons, neither of them "the Apple one is old" -- 2.50.1 is recent
# and supports every option in git/config.
#
# It is installed, so leaving it undeclared is drift by definition. And the
# Xcode tools are outside this file's reach: they update on Apple's schedule,
# can be absent on a fresh machine, and are occasionally reset by an OS upgrade.
# A Brewfile that claims to rebuild this machine cannot depend on a component it
# neither installs nor pins.
brew "git"
# Rewrites history in ways filter-branch cannot do safely or quickly
brew "git-filter-repo"
# Task runner. There is a Taskfile.yml in the projects here that needs it.
brew "go-task"
# Lightweight and flexible command-line JSON processor
brew "jq"
# Polyglot runtime manager (asdf rust clone)
brew "mise"
# Object-relational database system. Keg-only: zsh/.zshrc puts it on PATH.
brew "postgresql@17"
# Search tool like grep and The Silver Searcher
brew "ripgrep"
# Shell script analysis tool
brew "shellcheck"
# Autoformat shell script source code
brew "shfmt"
# Community-written examples for a command, which is what you actually want from
# `man tar` nine times out of ten.
#
# tlrc and not tldr: the tldr formula is the old C client, unmaintained upstream
# and disabled by Homebrew on 2025-10-24, so that line could never be satisfied
# and `brew bundle check` reported it as missing forever. tlrc is the same
# project's official client and still installs the `tldr` command.
brew "tlrc"
# Terminal multiplexer
brew "tmux"
# Rust toolchain installer
brew "rustup"
# Cross-shell prompt for astronauts
brew "starship"
# Extremely fast Python package installer and resolver, written in Rust
brew "uv"
# Shell extension to navigate your filesystem faster
brew "zoxide"
# Casks are development environment only, by the same rule the formulae follow:
# it goes here if a new machine needs it on day one to be able to work. Personal
# apps stay off this list on purpose -- reproducing them costs install time and
# inherits choices made once and never revisited.
#
# Credentials, and the SSH agent behind them
cask "1password"
cask "claude"
# Reaches the private networks the work is on
cask "cloudflare-warp"
cask "cursor"
# Ships the CLI too, symlinked into /usr/local/bin. The `docker` formula is
# deliberately not here: it is the same client binary from a second source, and
# both want that path.
cask "docker-desktop"
cask "font-jetbrains-mono-nerd-font"
cask "gcloud-cli"
# Terminal emulator that uses platform-native UI and GPU acceleration
cask "ghostty"
# Not the daily browser but the one with the devtools everything is debugged in
cask "google-chrome"
# Open-source code editor
cask "visual-studio-code"
vscode "charliermarsh.ruff"
vscode "dbaeumer.vscode-eslint"
vscode "editorconfig.editorconfig"
vscode "esbenp.prettier-vscode"
vscode "hverlin.mise-vscode"
vscode "ms-python.debugpy"
vscode "ms-python.python"
vscode "ms-python.vscode-pylance"
vscode "ms-python.vscode-python-envs"
vscode "pkief.material-icon-theme"
vscode "usernamehw.errorlens"
