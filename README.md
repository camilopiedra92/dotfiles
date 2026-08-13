# dotfiles

[![CI](https://github.com/camilopiedra92/dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/camilopiedra92/dotfiles/actions/workflows/ci.yml)

This machine's development environment, declared as code.

**macOS on Apple Silicon only.** Not a limitation waiting to be lifted, but the
assumption everything here is built on: `install.sh` expects Homebrew at
`/opt/homebrew`, the Brewfile installs casks, and VS Code is linked under
`~/Library`. On Linux it fails at the first step. CI runs on macOS for the same
reason — it is the only platform there is anything to verify against.

## New machine

```bash
git clone <this-repo> ~/dotfiles
~/dotfiles/install.sh
```

## Architecture

| Layer | Tool | What it manages |
|---|---|---|
| System | Homebrew | CLIs and native apps (`Brewfile`) |
| Runtimes | mise | node, python, go… per project (`mise/config.toml`) |
| Python | uv | packages, venvs and projects |
| Rust | rustup | toolchains |

Rule: **Homebrew installs programs, mise installs runtimes.** Never a runtime
through Homebrew — it ties you to a single global version and breaks projects
that need a different one.

The system Python (`/usr/bin/python3`) is never touched.

## Files

```
Brewfile               packages, apps and VS Code extensions
zsh/.zshenv            sets ZDOTDIR and builds PATH; linked into both $HOME and ZDOTDIR (see below)
zsh/.zprofile          re-asserts PATH after macOS rewrites it (see below)
zsh/.zshrc             history, completion, fzf, aliases
zsh/.zsh_plugins.txt   plugins (antidote)
starship.toml          prompt
ghostty/config         terminal
git/config             git config (without identity)
git/ignore             global gitignore
mise/config.toml       global runtime versions
vscode/settings.json   editor settings
bin/dev-nuke.sh        resets a machine left in a bad state
claude/statusline.sh            Claude Code statusline
claude/subagent-statusline.sh   per-agent telemetry in the agent panel
claude/statusline-demo.sh       renders both with sample cases
install.sh             symlinks + full installation
check.sh               every check, run by you, the hook and CI
drift.sh               what this machine has that the Brewfile does not say
bump-tools.sh          moves the CI tool pins to their latest releases
githooks/pre-commit    runs check.sh before each commit
githooks/pre-push      refuses to rewrite or delete main
.editorconfig          formatting, read by shfmt and by the editor
```

`$ZDOTDIR/.zsh_plugins.zsh` is **generated**, not versioned: antidote
regenerates it on its own whenever `.zsh_plugins.txt` changes.

## Where things land

Everything goes to its XDG path, which for the older tools here is not the one
they are usually installed to:

| | |
|---|---|
| `~/.zshenv` | cannot be moved: zsh reads it before it can know about `ZDOTDIR`, and it is what points at the directory below |
| `~/.config/zsh/` | `.zshenv` again — the same file, linked twice, see below — plus `.zprofile`, `.zshrc`, `.zsh_plugins.txt` and the generated `.zsh_plugins.zsh` |
| `~/.local/state/zsh/history` | state the shell writes, not config you edit |
| `~/.config/git/` | `config`, `ignore`, and the unversioned `config.local` |
| `~/.local/bin/` | `dev-nuke` |

`install.sh` deletes the pre-XDG paths after linking the new ones. It has to:
git reads `~/.gitconfig` *and* `~/.config/git/config`, and the legacy file wins,
so leaving it behind means the linked config is read and then overruled.

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

Git is linked to its XDG paths (`~/.config/git/config` and `~/.config/git/ignore`)
and not to `~/.gitconfig` and `~/.gitignore_global`. The two cannot coexist —
git reads both and the legacy one wins — so `install.sh` removes the old paths
after linking the new ones. Using the default ignore location is also what lets
`core.excludesfile` disappear from the config: naming a non-standard path is the
only reason that option ever needs to exist, and doing so silently disables
`~/.config/git/ignore` for everything else that expects to find it there.

`~/.claude/settings.json` is not symlinked either: Claude Code rewrites it on
its own (theme, `/config`…) and a symlink would end up overwritten.
`install.sh` merges `claude/settings.json` into it with `jq`, which is
idempotent.

That file is strict JSON with no room for comments, so the reasoning lives here:

- **`forceLoginMethod` is `claudeai`, matching the account that pays for this.**
  It is not cosmetic in either direction. Set to `console` it would refuse the
  login entirely on a new machine, and the wrong value in the other direction
  lets an accidental Console login bill per token instead of drawing on the
  subscription. Nothing surfaces this on a machine that is already signed in,
  which is what makes it worth writing down.
- **`effortLevel` is absent on purpose, and not set to `high` either.** The
  model's own default is already `high`, and writing that down would freeze it:
  a future model shipping a better default would be overridden by a line nobody
  revisits. It is the same argument as `node = "lts"` rather than a number.
  Escalate per session with `/effort`, which is also the only place `max` and
  `ultracode` are reachable — the settings file does not accept them.
- **`fallbackModel` matters because `model` is pinned.** With one model named
  and no chain, an overload is a stopped session rather than a slower one.
- **`autoUpdatesChannel` is `stable`**, described as roughly a week behind and
  skipping releases with major regressions. Every other tool here is pinned and
  checksum-verified; following `latest` for the tool doing the work was the
  inconsistency.
- **`attribution` replaces `includeCoAuthoredBy`**, which the schema marks
  deprecated. Same intent, the key that still exists.
- **`enabledPlugins` lists only the eight that are on.** A `false` entry is a
  plugin someone tried and turned off, and reproducing it on a new machine would
  mean installing it in order to disable it.
- **`extraKnownMarketplaces` is not versioned at all.** Every enabled plugin
  comes from `claude-plugins-official`, so declaring the extra marketplaces adds
  surface and no reproducibility. One of them points at a local directory and
  could not transfer anyway.
- **`permissions` has split ownership.** The repo owns `deny`, which is the same
  everywhere. `allow` accumulates per project — domains, MCP tools — and stays
  out, which is why `deny` is an array the merge replaces whole while `allow` is
  never mentioned.
- **`deny` covers the credential stores that exist on this machine**, not a
  generic list. Blocking `~/.ssh/**` while leaving `~/.config/gh/hosts.yml`
  readable protects the key and hands over the token that can push in its place.
- **Home rules carry a `~/` prefix and project rules do not**, which is the
  difference between a rule that works and one that reads as if it does. An
  unprefixed pattern in user settings anchors at the *current directory*, so
  `Read(**/.ssh/**)` only ever matched a `.ssh` folder inside whatever project
  was open. Verified by putting the same file in two places: inside the working
  directory it was refused, outside it was read.
- **`disableBypassPermissionsMode` is `disable`, set on purpose.** The
  documentation limits `bypassPermissions` to "isolated environments like
  containers or VMs where Claude Code can't cause damage", and this laptop is
  neither. The same page notes a user can set this in their own settings to lock
  themselves out of the mode, which is what this does.

Note what a deny rule can and cannot reach. It covers Claude's own file tools
and the shell commands Claude Code recognises — `cat`, `head`, `sed` — and stops
at anything that opens a file itself. A one-line Python or Node script reads a
denied path without touching any of it; that was checked here with a decoy, and
both read it.

## Why the sandbox is not enabled

`sandbox` is the OS-level layer that does cover Bash subprocesses, so it is the
obvious answer to the gap above. It is off here on purpose, and the reason is
fit rather than friction.

Its whole model is that the project is the world: sandboxed commands may write
to the working directory and the session temp directory, nothing else. That is
the right shape for an agent working inside a repository, and the wrong one for
a repository whose job is to configure the machine — `brew` writes to
`/opt/homebrew`, and `install.sh` writes symlinks across `$HOME`. The default
scope agrees: the `/sandbox` panel saves to a project's
`.claude/settings.local.json`, not to user settings. Per project is the
granularity it was designed for, and it is worth turning on in repositories
where Claude runs unattended on code that did not come from here.

Three things are worth stating plainly before treating it as a security answer:

- **It does not protect credentials by default.** The default read policy is the
  entire computer, and the documentation names `~/.aws/credentials` and `~/.ssh/`
  as still readable. That takes a deliberate `sandbox.credentials` block.
- **It does not cover Read, Edit or Write**, which go through the permission
  system directly. The deny rules above and the sandbox protect different
  things; neither replaces the other, which is why the docs recommend both.
- **The documentation does not call it a boundary**: "Sandboxing reduces risk but
  is not a complete isolation boundary." The proxy does not inspect TLS, so a
  broad `allowedDomains` entry can be reached around by domain fronting.

The tools that would need excluding here are the ones in daily use. `docker` is
documented as incompatible. `gh`, `gcloud` and `terraform` may fail TLS
verification under Seatbelt and are meant to go in `excludedCommands` too — and
an excluded command runs with no sandbox at all, so each exception reopens the
hole for that tool.

To see them without restarting Claude, including the cases you cannot trigger
at will (limit at 95%, context in red, PR with changes requested, a stuck
agent):

```bash
~/dotfiles/claude/statusline-demo.sh
```

The main statusline is two lines: identity on top (model, path, branch, PR) in
powerline style, and gauges below (context, 5h and 7d limits, cost) on a clean
background, so color keeps working as an alarm. `STYLE` and `LINES`, at the top
of the script, switch to `minimal` and to a single line. Both require a Nerd
Font: the Ghostty config already sets one.

## Checks

```bash
./check.sh
```

Linting (shellcheck), formatting (shfmt), the CI workflow itself (actionlint),
syntax for every config format here, the statuslines' behaviour, that the tools
you have installed are the versions `ci.yml` pins, and that `install.sh` is
still idempotent.

One script is the whole point. You run it by hand, `githooks/pre-commit` runs it
before every commit, and CI runs that same file rather than reimplementing
anything — checks written twice drift, and the moment CI and local disagree you
stop trusting both. To bypass the hook once: `git commit --no-verify`.

A check either runs (`ok` / `FAIL`) or is skipped because its tool is missing.
A skip is a hole in coverage, not a neutral third outcome, so under CI it is a
failure; `./check.sh --strict` reproduces that locally. Without it a missing
tool turns into a green run that verified less than you think, which is not
hypothetical: CI passed for a while without ever validating the Ghostty config.

This is why CI installs pinned, checksummed copies of shellcheck, shfmt,
actionlint and Ghostty instead of trusting the runner image: strict mode means
anything it fails to install stops the build rather than quietly shrinking it.

Those pins only mean something while your machine agrees with them, and the
Brewfile installs whatever is current — Ghostty updates itself outright. So the
versions you have are checked against the ones `ci.yml` pins, and a drift fails
here rather than turning into a CI failure nobody can explain later. When it
does fail, either upgrade the pin and its hash in `.github/tool-checksums.txt`,
or pin your local tool back.

## Finding drift

```bash
./drift.sh
```

`brew bundle check` only asks whether everything declared is installed, and a
subset always answers yes to that. The gap it leaves is everything installed and
never written down, which is the direction drift actually grows in. `drift.sh`
reports both, plus VS Code extensions, plus any runtime that came from Homebrew
instead of mise — the rule stated at the top of this file, which nothing
enforced until now.

It also asks endoflife.date whether anything mise installed has stopped being
supported. That is drift against a calendar rather than between two files: a pin
that was right when it was written becomes wrong on a date, and the only symptom
is that security fixes quietly stop arriving. It would have caught the node 25
this repo was serving through Homebrew, end of life since 2026-06-01.

It is not part of `check.sh` and CI never runs it, on purpose. Every check in
there has to mean the same thing on a runner as on this laptop; this one cannot,
because a runner arrives with its own preinstalled packages and would report
drift forever. The end-of-life check adds a second reason: it needs the network,
and a check that fails because DNS blinked has no business gating a commit.

## Updating the pins

```bash
./bump-tools.sh
```

Resolves each tool's latest release, downloads the artifact, records its SHA256
and rewrites both `ci.yml` and `.github/tool-checksums.txt`. It refuses to walk
a pin backwards, and refuses a version that is tagged but whose artifact is not
downloadable yet, which Ghostty's tags do briefly.

`.github/workflows/tool-updates.yml` runs it on the 1st of each month and opens
a pull request if anything moved. It authenticates with a GitHub App rather
than the default token, because a pull request opened with `GITHUB_TOKEN` does
not start workflows and so could never satisfy the required check.

That pull request does not auto-merge, deliberately. The hashes in it are
whatever upstream is publishing at that moment, which is exactly what
`tool-checksums.txt` exists not to take on trust. CI proves the new versions
install and everything still passes; you decide they should be trusted.

Formatting is defined in `.editorconfig`, which shfmt parses natively and the
EditorConfig extension applies in VS Code, so the editor and the hook cannot
disagree about what the code should look like.

`githooks/pre-push` refuses any push that would rewrite or delete `main`,
detected as a push whose remote tip is not an ancestor of what is being sent.
It is defence in depth, not the real defence: it only covers clones that have
it installed and `--no-verify` walks past it. The real one is the server-side
ruleset described under [Changing something](#changing-something), which
applies no matter who pushes or from where. The hook earns its place by failing
on your machine instead of after a round trip, and by still being there if the
ruleset is ever relaxed. A deliberate rewrite is still possible, it just has to
be deliberate: `git push --no-verify --force-with-lease`.

## Changing something

`main` does not take direct pushes. Everything goes through a pull request that
the CI has to pass first, which is the whole point: pushing straight to `main`
runs the checks *after* the commit is already in, so a failure means `main` is
already broken. This way nothing lands that has not passed.

```bash
git switch -c what-youre-doing
# ...edit, commit (the hook runs check.sh)...
git push -u origin HEAD
gh pr create --fill
gh pr merge --auto --squash
```

`--auto` is what keeps this from being a chore: the PR merges by itself the
moment CI goes green, and the branch is deleted. You do not wait around for it.

The ruleset on `main` also blocks force pushes, deletion, and merge commits, and
has no bypass actors — it applies to the repo owner too.

## Daily use

```bash
brew upgrade                  # update everything from the system layer
mise upgrade                  # update runtimes

# After installing something new, dump it into the repo (VS Code extensions included):
brew bundle dump --file=~/dotfiles/Brewfile --force
```

Pin versions in a project (creates `mise.toml`, version it with the repo):

```bash
mise use node@24 python@3.13
```
