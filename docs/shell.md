# Shell

## Why .zshenv is linked twice

The usual one-line summary — "`.zshenv` is the one file zsh always reads from
`$HOME`" — is only true of a cold start. The actual rule has two branches:

| how the shell starts | which `.zshenv` zsh reads |
|---|---|
| `ZDOTDIR` unset in the environment | `$HOME/.zshenv` |
| `ZDOTDIR` already exported | `$ZDOTDIR/.zshenv` |

It reads one or the other, never both. The second branch is every shell spawned
from one this repo already configured: a git hook, `zsh -c` from an editor,
anything under a running session. With only the `$HOME` copy linked those read
*neither* file and start with the bare system `PATH` — no mise shims, so a hook
reports `node: command not found` on a machine where the terminal beside it
resolves node fine. A login shell hid this, because `$ZDOTDIR/.zprofile`
re-sources `$HOME/.zshenv` by name for the reason below; only `zsh -c` broke.

So `install.sh` links the same file into both places. That is safe rather than
merely tolerable: `typeset -U path` makes the file idempotent by construction,
which is the property `.zprofile` already leans on.

This fixes shells. It does not fix `sh` — `/bin/sh` reads no zsh file under any
branch, so anything invoked as `sh -c` still needs the shims put on `PATH`
by whatever invokes it.

## Why there is a .zprofile

Setting `ZDOTDIR` is not free, and this is what it costs. `.zprofile`, `.zshrc`
and `.zlogin` are read from `ZDOTDIR` and never from `$HOME`. The Homebrew
installer writes a `~/.zprofile`, and from the moment `.zshenv` exports
`ZDOTDIR` that file is never read again — which matters here, because it was the
only thing putting Homebrew ahead of `/usr/bin` on this machine.

The mechanism underneath is macOS-specific and worth stating plainly, because
every "put it in `.zshenv` so scripts get it too" instinct runs into it. Between
`.zshenv` and `.zprofile`, `/etc/zprofile` runs `/usr/libexec/path_helper`, and
path_helper does not append to `PATH` — it **rebuilds** it, `/etc/paths` and
`/etc/paths.d` first, then whatever `PATH` already held. Everything `.zshenv`
prepended lands behind `/usr/bin`. Measured in a login shell with a clean
environment:

| | mise shims | `/opt/homebrew/bin` | `/usr/bin` |
|---|---|---|---|
| `.zshenv` alone | 13th | 12th | **3rd** |
| with `.zprofile` | 1st | 5th | 9th |

So `git` resolved to `/usr/bin/git` — Apple's fork — in exactly the shell you
type in, which is the failure `.zshenv` was written to prevent. `.zprofile`
re-sources `.zshenv` once path_helper is done. That is a re-source and not a
copy: `typeset -U path` in `.zshenv` makes every prepend hoist an entry that is
already there instead of duplicating it, so the file is idempotent by
construction and `.zprofile` needs to know nothing about what it contains.

The git identity lives in `~/.config/git/config.local`, **outside the repo**, so
this can be public and each machine uses its own name/email.
