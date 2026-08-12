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
zsh/.zshenv            sets ZDOTDIR; the only file that must live in $HOME
zsh/.zshrc             PATH, history, fzf, aliases
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
| `~/.zshenv` | the single exception. zsh reads it before it can know about `ZDOTDIR`, so it cannot be moved — it exists to point at the directory below |
| `~/.config/zsh/` | `.zshrc`, `.zsh_plugins.txt`, and the generated `.zsh_plugins.zsh` |
| `~/.local/state/zsh/history` | state the shell writes, not config you edit |
| `~/.config/git/` | `config`, `ignore`, and the unversioned `config.local` |
| `~/.local/bin/` | `dev-nuke` |

`install.sh` deletes the pre-XDG paths after linking the new ones. It has to:
git reads `~/.gitconfig` *and* `~/.config/git/config`, and the legacy file wins,
so leaving it behind means the linked config is read and then overruled.

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
`install.sh` merges `statusLine` and `subagentStatusLine` into it with `jq`,
which is idempotent.

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

It is not part of `check.sh` and CI never runs it, on purpose. Every check in
there has to mean the same thing on a runner as on this laptop; this one cannot,
because a runner arrives with its own preinstalled packages and would report
drift forever.

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
