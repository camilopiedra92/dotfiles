# Claude Code settings.json

`~/.claude/settings.json` is not a symlink: Claude Code rewrites it on
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
- **`effortLevel` is absent on purpose.** Each model ships its own default —
  `medium` on Opus 5.5, where the model-config docs say to start rather than
  carry over Opus 5's `high` — and writing a level down would freeze it: a
  future model shipping a better default would be overridden by a line nobody
  revisits. It is the same argument as `node = "lts"` rather than a number.
  `/effort` changes it, and since v2.1.251 saving a level as the default
  writes it per model under `modelSettings`; `drift.sh` leaves that key alone
  for this reason, as a record of a choice made in a session rather than a
  policy. `max` is accepted by neither key: it is reached with `/effort`,
  `--effort` or `CLAUDE_CODE_EFFORT_LEVEL`.
- **`model` is not set.** The default on this plan is already Opus 5.5 with
  the 1M context window, so the `opus[1m]` that used to be here selected
  nothing the default did not; it only kept a newer default from applying.
- **`fallbackModel` is only `sonnet`.** Without a chain an overload is a
  stopped session rather than a slower one. `opus` is not in it because it is
  the primary model: falling back to the model that is overloaded buys
  nothing.
- **`autoUpdatesChannel` is `latest`, written out although it is the
  default.** It is a choice, made on 2026-10-05: new releases the day they
  ship, over `stable`'s week of delay and its skipping of releases with major
  regressions. Written down so that the choice holds if the default ever
  changes, and so the merge overwrites a `stable` already on a machine — this
  one carried it for a few hours that day. The alternative on record is
  `stable`, which pairs with everything else here being pinned; it lost to
  getting fixes and features as they ship.
- **`attribution` replaces `includeCoAuthoredBy`**, which the schema marks
  deprecated. Same intent, the key that still exists.
- **`enabledPlugins` lists only the ones that are on.** A `false` entry is a
  plugin someone tried and turned off, and reproducing it on a new machine would
  mean installing it in order to disable it. Removing a line here does not
  disable anything on a machine — the merge keeps live keys — so a plugin is
  dropped with `claude plugin uninstall` as well.
- **`commit-commands` is gone** (2026-10-06). It had 2 uses in 453 sessions,
  none in the last 30 days, and `commit-push-pr` commits, pushes and opens a
  ready PR in one message with no test run and no review before it, which
  the global CLAUDE.md asks for. `/wrap-up` covers the end of a session
  following those rules. A ready PR is not wrong in itself: GitHub's drafts
  exist to share work "without formally requesting reviews", which is what
  the draft-until-reviewed rule uses them for.
- **Spec Kit is the only process plugin, so superpowers is gone** (2026-10-05).
  Its SessionStart hook re-injected "a 1% chance a skill applies means you MUST
  invoke it" on every start, clear and compaction, and its brainstorming gate
  hands off only to its own plan format: 15 repos under `~/Development` had
  grown `docs/superpowers/` against 1 with `.specify/`. It cannot be trimmed —
  plugin skills ignore `skillOverrides`, and upstream declined an opt-out in
  #645 and #1456. The alternative on record is keeping it beside Spec Kit with
  a bridge extension; it lost because the hook keeps pulling either way. What
  it did well, shaping an idea before a spec exists, is `/brainstorm` in
  `claude/skills/` (2026-10-06): written here rather than copied, so there is
  no upstream to fall behind; its description is meant to bring Claude to it
  only while an idea is still open, with no hook pushing it (observed on six
  prompts, 2026-10-06); and it writes no document,
  handing off instead to a direct change, a spike, or `/speckit-specify` (what
  and why) plus `/speckit-plan` (approach and alternatives). Also
  removed the same day: `security-guidance` (an extra LLM review on every
  Stop, commit and push; `/security-review` is built in), `claude-md-management`
  (overlaps `/doctor`), and `chrome-devtools-mcp` (~800 tokens in every session
  for a tool only web projects use; enable it in those projects instead).
- **`extraKnownMarketplaces` is not versioned at all.** Every enabled plugin
  comes from `claude-plugins-official`, so declaring the extra marketplaces adds
  surface and no reproducibility.
- **`syncClaudeAiPlugins` is `false`.** The claude.ai account enables plugins
  for Cowork and the web — sales, legal, finance, zoom — and Claude Code loads
  all of them into every terminal session as `<name>@synced`, which added
  hundreds of skills to each one and three servers failing authentication at
  every start. A plugin wanted in the terminal is declared above instead.
  Synced skills are a separate switch, `syncClaudeAiSkills`, also `false`
  since 2026-10-05: the 19 it brought (docx, pptx, morning, todoist-tasks…)
  are for claude.ai, and their descriptions sat in every coding session. The
  key is missing from the published schema, so it was checked by effect: the
  skills were listed in a session before the change and absent from a fresh
  `claude -p` session after it.
- **`deniedMcpServers` blocks the claude.ai connectors that never belong in a
  terminal** — travel and music. By URL, because `serverName` only accepts
  `[a-zA-Z0-9_-]` and connector names carry a space and a dot. Not
  `disableClaudeAiConnectors`: Context7 arrives as a connector, and so do the
  market-data ones the investing repos use. Each blocked server prints a
  warning at startup in `-p` mode; that is the cost of the block.
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
- **`rm -rf` is not denied, and that is the protection, not a gap in it.** A
  deny rule is a prefix on the command text, so `Bash(rm -rf:*)` never matched
  `rm -fr`, `rm -r -f`, `/bin/rm -rf` or `bash -c '…'`: it read as protection
  while granting none, the same failure `git-guard.sh` exists for. What it did
  stop was the legitimate case, Claude clearing away files it had just made. The
  real guards need no rule: Claude Code refuses any removal of a critical path
  (`/`, `~`, …) even over an allow rule or hook, and auto mode's classifier
  blocks irreversibly destroying files that existed before the session, deletes
  through unresolved variables, and is shown `git status` before an `rm -rf` in a
  repo. A hook was the alternative and lost: it cannot know which files the
  session created, which is the one distinction that matters here.
- **An edit to a lint, format or test config asks first** (`claude/config-guard.sh`,
  2026-10-06). Changing the config is the cheapest way to make a red check
  green without fixing anything. It asks rather than denies: a hook's `ask`
  shows its reason to you in the permission prompt (code.claude.com hooks
  reference), so a change you requested costs one keypress, and a denial would
  leave the agent to work around it. In `pyproject.toml` it asks only for a
  change inside `[tool.ruff|mypy|pytest|mutmut|importlinter|black|isort]`,
  because that is where the projects here keep that config. Creating such a
  file asks too: a new `ruff.toml` or `pytest.ini` overrides `pyproject.toml`,
  which an independent review showed by turning `ruff check` from 2 errors to
  none with one new file. The idea came from ECC's
  `config-protection` hook; ECC itself was not adopted. ECC blocks instead of
  asking and looks at filenames only, so it would have missed almost all of
  the Python config here. It covers the Edit and Write tools only: a
  config rewritten through Bash never reaches it, and that is a stated ceiling,
  not something to patch with patterns. Its verdicts are tested in `checks/`
  against stdin payloads. A headless `claude -p` run (observed 2026-10-06, with
  `acceptEdits`) has no one to ask, so the edit is refused and the agent sees
  the reason, reports it and stops rather than working around it. So a
  headless phase that has to change such a config stops there and waits for
  you. Not yet observed: the prompt in an interactive auto-mode session (the
  docs say a hook `ask` prompts).

Note what a deny rule can and cannot reach. It covers Claude's own file tools
and the shell commands Claude Code recognises — `cat`, `head`, `sed` — and stops
at anything that opens a file itself. A one-line Python or Node script reads a
denied path without touching any of it; that was checked here with a decoy, and
both read it.
