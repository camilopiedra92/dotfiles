# dotfiles

[![CI](https://github.com/camilopiedra92/dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/camilopiedra92/dotfiles/actions/workflows/ci.yml)

This machine's development environment, declared as code.

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
zsh/.zshrc             PATH, history, fzf, aliases
zsh/.zsh_plugins.txt   plugins (antidote)
starship.toml          prompt
ghostty/config         terminal
git/.gitconfig         git config (without identity)
git/.gitignore_global
mise/config.toml       global runtime versions
vscode/settings.json   editor settings
claude/statusline.sh            Claude Code statusline
claude/subagent-statusline.sh   per-agent telemetry in the agent panel
claude/statusline-demo.sh       renders both with sample cases
install.sh             symlinks + full installation
check.sh               every check, run by you, the hook and CI
githooks/pre-commit    runs check.sh before each commit
githooks/pre-push      refuses to rewrite or delete main
.editorconfig          formatting, read by shfmt and by the editor
```

`~/.zsh_plugins.zsh` is **generated**, not versioned: antidote regenerates it
on its own whenever `.zsh_plugins.txt` changes.

The git identity lives in `~/.gitconfig.local`, **outside the repo**, so this
can be public and each machine uses its own name/email.

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

Linting (shellcheck), formatting (shfmt), syntax for every config format here,
the statuslines' behaviour, and that `install.sh` is still idempotent.

One script is the whole point. You run it by hand, `githooks/pre-commit` runs it
before every commit, and CI runs that same file on both Linux and macOS rather
than reimplementing anything — checks written twice drift, and the moment CI and
local disagree you stop trusting both. To bypass the hook once:
`git commit --no-verify`.

A check reports one of four things, and the last two are not the same:

| | |
|---|---|
| `ok` / `FAIL` | it ran |
| `skip` | the tool is missing, so nothing ran |
| `n/a` | the check does not apply on this platform |

`skip` is a hole in coverage, so under CI it is a failure — `./check.sh
--strict` reproduces that locally. Without it a missing tool turns into a green
run that verified less than you think, which is not hypothetical: both runners
passed for a while without ever validating the Ghostty config. `n/a` is not a
hole and never fails; the Ghostty config is macOS-only, so the Linux runner has
nothing to assert.

This is why CI installs pinned, checksummed copies of shellcheck, shfmt and
Ghostty instead of trusting the runner image: strict mode means anything it
fails to install stops the build rather than quietly shrinking it.

Formatting is defined in `.editorconfig`, which shfmt parses natively and the
EditorConfig extension applies in VS Code, so the editor and the hook cannot
disagree about what the code should look like.

`githooks/pre-push` refuses any push that would rewrite or delete `main`,
detected as a push whose remote tip is not an ancestor of what is being sent.
It is defence in depth, not the real defence: it only covers clones that have
it installed and `--no-verify` walks past it. The real one is a server-side
ruleset, which this repo cannot have while it is private on a free plan.
A deliberate rewrite is still possible, it just has to be deliberate:
`git push --no-verify --force-with-lease`.

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
