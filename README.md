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
| Python | uv | packages, venvs and projects, plus CLI tools (`uv-tools.txt`) |
| Rust | rustup | toolchains |

Rule: **Homebrew installs programs, mise installs runtimes.** Never a runtime
through Homebrew — it ties you to a single global version and breaks projects
that need a different one.

A program Homebrew does not carry goes in `uv-tools.txt` if it is a Python
application, never into a global `pip install`. That file is the third manifest
here for the same reason the other two exist: `uv tool` installs into
`~/.local/share/uv/tools` and has nothing to read a list from, so without it a
rebuilt machine came up missing those commands and nothing said so.

The system Python (`/usr/bin/python3`) is never touched.

## Files

```
Brewfile               packages, apps and VS Code extensions
zsh/.zshenv            sets ZDOTDIR and builds PATH; linked into both $HOME and ZDOTDIR (see [Shell](docs/shell.md))
zsh/.zprofile          re-asserts PATH after macOS rewrites it (see [Shell](docs/shell.md))
zsh/.zshrc             history, completion, fzf, aliases
zsh/.zsh_plugins.txt   plugins (antidote)
starship.toml          prompt
ghostty/config         terminal
git/config             git config (without identity)
git/ignore             global gitignore
ssh/config             ssh client config: agent + Keychain, and where the per-machine hosts go
launchd/               login agent that loads the signing key into ssh-agent (see [Git](docs/git.md))
mise/config.toml       global runtime versions
uv-tools.txt           CLI tools installed with `uv tool`, each pinned to a reference
vscode/settings.json   editor settings
bin/dev-nuke.sh        resets a machine left in a bad state
bin/aware.sh           runs the aware-connector CLI from anywhere
bin/ynab-mcp.sh        runs the YNAB MCP server with a log directory of its own
macos/defaults.txt     macOS settings, one `defaults` key per line
macos/defaults.sh      applies the manifest (install.sh) or reports where the machine differs (drift.sh)
macos/power.sh         the `pmset` settings, declared inline; same two verbs, `apply` is the one that needs sudo
macos/touchid.sh       turns on Touch ID for sudo through /etc/pam.d/sudo_local, or reports it off
macos/dock.sh          applies a machine's dock.txt through `dockutil`, or reports where the Dock differs
macos/handlers.txt     the default app per file extension on every Mac, only where it differs from Apple's
macos/handlers.sh      applies it, plus the machine's own, through `duti`, or reports where the Mac differs
macos/machine.sh       which profile under macos/machines/ this Mac is (`dir`), or records it (`set`)
macos/machines/<p>/    what only one Mac has: dock.txt, mcp.json, Brewfile, and defaults.txt / handlers.txt read after the shared ones
claude/mcp.json                 user-scope MCP servers for every Mac, applied through `claude mcp`
claude/config-guard.sh          PreToolUse hook: asks before a lint, format or test config is edited
claude/statusline.sh            Claude Code statusline
claude/subagent-statusline.sh   per-agent telemetry in the agent panel
claude/statusline-demo.sh       renders both with sample cases
claude/skills/<name>/           personal skills, each linked into ~/.claude/skills by install.sh:
                                `/brainstorm` (shape an open idea), `/diagnose` (root cause of a bug),
                                `/wrap-up` (close a session and hand off), `/wp` (shortcut for it)
install.sh             symlinks + full installation
check.sh               the runner, for you, the hook and CI: arguments, strict mode, which sections run (`--staged`), the verdict
checks/                the checks themselves, one file per area, each run by check.sh in a shell of its own, printed in file-name order
drift.sh               what this machine has that the Brewfile does not say
bump-tools.sh          moves the CI tool pins to their latest releases
githooks/pre-commit    runs the sections the staged files select (`check.sh --staged`) before each commit
githooks/pre-push      refuses to rewrite or delete main
.editorconfig          formatting, read by shfmt and by the editor
.taplo.toml            which schema validates which TOML, for taplo and the editor
schemas/               vendored JSON schemas for starship.toml and mise/config.toml
.gitattributes         marks the vendored trees, which the English-only check skips
.specify/              Spec Kit; memory/constitution.md holds the principles every change meets
CLAUDE.md              this repo's instructions for Claude Code; imports the constitution
```

`$ZDOTDIR/.zsh_plugins.zsh` is **generated**, not versioned: antidote
regenerates it on its own whenever `.zsh_plugins.txt` changes.

## Where things land

Everything goes to its XDG path, which for the older tools here is not the one
they are usually installed to:

| | |
|---|---|
| `~/.zshenv` | cannot be moved: zsh reads it before it can know about `ZDOTDIR`, and it is what points at the directory below |
| `~/.config/zsh/` | `.zshenv` again — the same file, linked twice, see [Shell](docs/shell.md) — plus `.zprofile`, `.zshrc`, `.zsh_plugins.txt` and the generated `.zsh_plugins.zsh` |
| `~/.local/state/zsh/history` | state the shell writes, not config you edit |
| `~/.config/git/` | `config`, `ignore`, and two files `install.sh` writes and never versions: `config.local` (name, email, signing key) and `allowed_signers` (what local signature verification checks against); plus `identities/`, one file per identity scoped to a directory, written by hand (see [Git](docs/git.md)) |
| `~/.ssh/` | `config`, linked; the key pair `install.sh` generates; and an optional `config.local` for hosts that need their own key or user, which `ssh/config` includes first |
| `~/Library/LaunchAgents/` | `com.piedrac.ssh-add-keychain.plist`, linked: the login agent that puts the signing key in the agent, bootstrapped by `install.sh` |
| `~/.local/bin/` | `dev-nuke`, `aware`, `ynab-mcp` |
| `~/.local/state/ynab-mcp/` | where the YNAB MCP server logs, once it is started through the wrapper — see [Claude Code](docs/claude-code.md) |
| `~/.claude.json` | Claude Code's own state file; `install.sh` registers the servers in `claude/mcp.json` and the profile's `mcp.json` into it through the CLI, and `drift.sh` reports one registered by hand and never declared |

`install.sh` deletes the pre-XDG paths after linking the new ones. It has to:
git reads `~/.gitconfig` *and* `~/.config/git/config`, and the legacy file wins,
so leaving it behind means the linked config is read and then overruled.

## Documentation

Why things are the way they are, one file per subject:

- [Shell](docs/shell.md): why `.zshenv` is linked twice and why there is a `.zprofile`.
- [Git](docs/git.md): why git is linked at its XDG paths, and commit signing.
- [Claude Code settings](docs/claude-settings.md): the reasoning behind `settings.json`, which its strict JSON cannot hold.
- [Claude Code](docs/claude-code.md): why the sandbox is off, why the YNAB server runs through a wrapper.
- [Checks](docs/checks.md): what `check.sh` runs, and how configs are validated against schemas.
- [macOS](docs/macos.md): defaults, power, Touch ID, firewall, Dock, file handlers and more than one Mac.
- [Maintenance](docs/maintenance.md): finding drift and updating the pins.
- [Routed Spec Kit runs](docs/sdd-routing.md): `sdd-run`, a feature through Spec Kit's phases, each on its own model, contained.

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
