# Read for every zsh invocation -- login shell, interactive shell, script -- and
# always from $HOME, because zsh looks for this file before it has any way of
# knowing where else to look. It is the one dotfile that genuinely cannot move,
# which is exactly what makes it the right place to say where the rest live.
#
# Keep this file trivial. It runs for non-interactive shells too, so anything
# slow here is paid by every script on the machine, and anything that prints
# breaks tools that parse a command's output.
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

# mise shims, here rather than in .zshrc, and this is the whole reason this file
# does more than one thing.
#
# `mise activate` lives in .zshrc, which only interactive shells read. Every
# other zsh -- a script, a hook, anything invoked without a terminal -- skipped
# it and fell through to whatever came next on PATH. While node was also
# installed through Homebrew that meant an interactive shell got the pinned
# version and a script silently got a different major.
#
# Shims cover exactly that gap: they are plain symlinks to mise, so they cost
# nothing to put on PATH and resolve the same versions. .zshrc still activates
# afterwards and takes precedence there, which avoids paying a subprocess hop
# per command in the shell you actually type in.
# The guard is the same one .zshrc uses for Homebrew: zsh reads this file from
# $ZDOTDIR instead of $HOME when ZDOTDIR is already exported, so in a nested
# shell it can run more than once and would otherwise stack duplicates.
mise_shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
if [[ ":$PATH:" != *":$mise_shims:"* ]]; then
  export PATH="$mise_shims:$PATH"
fi
unset mise_shims
