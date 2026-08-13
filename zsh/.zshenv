# Read for every zsh invocation -- login shell, interactive shell, script -- and
# always from $HOME, because zsh looks for this file before it has any way of
# knowing where else to look. It is the one dotfile that genuinely cannot move,
# which is exactly what makes it the right place to say where the rest live.
#
# Keep this file trivial. It runs for non-interactive shells too, so anything
# slow here is paid by every script on the machine, and anything that prints
# breaks tools that parse a command's output.
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

# Deduplicated, leftmost occurrence wins. This is what makes everything below
# idempotent rather than guarded: prepending a directory that is already further
# down the list moves it to the front instead of adding a second copy. So this
# file can be sourced a second time -- and $ZDOTDIR/.zprofile does exactly that,
# for the reason documented there -- without stacking entries.
typeset -U path PATH

# Homebrew, here rather than in .zshrc, because .zshrc is only read by
# interactive shells. Everything else got the system PATH, where /opt/homebrew
# does not appear -- so a launchd job resolved /usr/bin/git (Apple's fork, three
# minors behind) while the terminal resolved the one this Brewfile installs.
# Same tool, different binary, decided by whether a terminal was attached.
#
# `brew shellenv` has a fast path that does not load the rest of Homebrew, so
# this costs about 10ms and is worth the exactness. It is a subprocess rather
# than a hardcoded PATH prepend because it also exports HOMEBREW_PREFIX,
# HOMEBREW_CELLAR, FPATH and INFOPATH, which would have to be duplicated here
# and would rot the day Homebrew moves anything.
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

# The rest of what every zsh needs, not just the interactive ones: a git hook or
# a launchd job has to resolve these too, and until now they were set in .zshrc
# and so existed only where a terminal was attached.
path=(
  "$HOME/.local/bin"                  # claude, dev-nuke, user binaries
  /opt/homebrew/opt/rustup/bin        # rustup does not symlink itself
  /opt/homebrew/opt/postgresql@17/bin # keg-only, so no psql without this
  $path
)

# mise shims go in front of all of it: a runtime is then always resolved by mise
# even if one is ever installed through Homebrew again.
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
path=("${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims" $path)
