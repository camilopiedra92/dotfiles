# Login shells, which on macOS is every terminal window: Ghostty, Terminal and
# tmux all start the shell with -l. Read from $ZDOTDIR and not from $HOME --
# only .zshenv comes from $HOME, everything after it follows ZDOTDIR.
#
# That relocation is also why install.sh retires ~/.zprofile. The Homebrew
# installer writes one, and from the moment .zshenv exports ZDOTDIR zsh stops
# reading it. Leaving it in place means a file that looks like it configures the
# shell and has not run since.
#
# This file exists for one reason. Between .zshenv and here, /etc/zprofile runs
# /usr/libexec/path_helper, and path_helper does not append to PATH -- it
# rebuilds it, putting /etc/paths and /etc/paths.d first and whatever PATH
# already held after. Everything .zshenv put in front therefore ends up behind
# /usr/bin. Measured on this machine, in a login shell with a clean environment:
#
#   .zshenv alone      /usr/bin 3rd, /opt/homebrew/bin 12th, mise shims 13th
#   with this file     mise shims 1st, /opt/homebrew/bin 5th, /usr/bin 9th
#
# So `git` resolved to /usr/bin/git in exactly the shell you type in, which is
# the failure .zshenv was written to prevent.
#
# Re-sourcing .zshenv is the whole fix, and it is deliberately not a copy of
# what that file does: `typeset -U path` in there means every prepend hoists an
# existing entry instead of duplicating it, so this needs to know nothing except
# that it has to happen again once path_helper is done.
source "$HOME/.zshenv"
