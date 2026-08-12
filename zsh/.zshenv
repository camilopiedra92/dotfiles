# Read for every zsh invocation -- login shell, interactive shell, script -- and
# always from $HOME, because zsh looks for this file before it has any way of
# knowing where else to look. It is the one dotfile that genuinely cannot move,
# which is exactly what makes it the right place to say where the rest live.
#
# Keep this file trivial. It runs for non-interactive shells too, so anything
# slow here is paid by every script on the machine, and anything that prints
# breaks tools that parse a command's output.
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
