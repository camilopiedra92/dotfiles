# Claude Code: decisions behind the setup

## Why the sandbox is not enabled

`sandbox` is the OS-level layer that does cover Bash subprocesses, so it is the
obvious answer to the gap described at the end of
[the `settings.json` notes](claude-settings.md): deny rules reach Claude's own
file tools and not what a Bash subprocess does. It is off here on purpose, and the reason is
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
  system directly. The [deny rules](claude-settings.md) and the sandbox protect different
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

## Why the YNAB MCP server runs through a wrapper

Because it writes its log to a relative path. `mcp-framework`, which the server
is built on, opens `logs` with the directory hardcoded:

```js
const logDir = "logs";                       // Logger.js
mkdir(logDir, { recursive: true })
```

A relative path resolves against the working directory of the process, and an
MCP server inherits that from the editor that spawned it — so an untracked
`logs/` appears in whatever repository you happened to open, with one file per
session inside it. The server is configured globally, so this is every
repository, not one.

There is no environment variable for it and no `cwd` field for a stdio server in
Claude Code's configuration, which leaves the working directory itself as the
only thing that can be changed. `bin/ynab-mcp.sh` sets it to
`~/.local/state/ynab-mcp` and execs the server; the registration in
`macos/machines/personal/mcp.json` points at the wrapper instead of at `npx`.

The wrapper also supplies the token, from a `ynab-mcp` item in the login
Keychain, so that no file holds it. It used to be in the registration's `env`,
which is plain text in `~/.claude.json`. Store or replace it with
`security add-generic-password -U -s ynab-mcp -a ynab -w`, which prompts for
it rather than taking it as an argument that would land in shell history. Do
that before `./install.sh` on a Mac still registered the old way: the install
replaces the registration, and its `env` block goes with it.

Not a `.gitignore` entry, which is where this ends up by default. In one
repository it is a workaround for a bug in another program; in the global ignore
it would be worse — `logs/` is a name a project may well want to commit, and
hiding it there is the mistake `git/ignore` had already made with `.vscode/`,
where `git add` does nothing and prints no reason.
