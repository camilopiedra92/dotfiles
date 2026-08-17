# Global preferences

## Environment

`~/Development` is a container folder, not a project. Each subfolder is an
independent project with its own git, its own toolchain and its own
conventions. Do not assume something seen in one project applies to another,
and do not create loose files at the root of `~/Development`.

Claude Code and shell configuration live in `~/dotfiles` (versioned). Changes
to `~/.claude/*.sh` go there, not into stray copies.

Usual stack: Python, Node/TypeScript/JavaScript, React, shell and infra.

## Language

Reply to me in Spanish. That is the only thing in Spanish: everything you
write into a file goes in English — names, comments, commit messages, repo
documentation, log strings, test fixtures, CLI output. A repo may end up
public or shared.

## How to work

Calibrate by size. Make a small or mechanical change directly and tell me
afterwards. If it touches several files, changes an interface, or involves a
design decision with real alternatives, propose the approach before writing.

Ask before introducing a new dependency. I almost always prefer solving it
with what is already in the project or with the standard library.

When I ask whether something is best practice, judge it against the
authoritative source — the published schema, the vendor's docs, the upstream
release calendar — and not against what is already configured here. Reading a
setup in order to review it biases towards keeping it. Deleting a line is a
valid answer and often the right one: pinning a value that is already the
default buys nothing today and blocks the better default tomorrow.

Prove things rather than assert them. If a claim can be settled with a command,
run it first — and say plainly when something cannot be determined from here
instead of picking the likely answer. When you add a check, break it on purpose
before trusting it: a check nobody has watched fail is a check nobody should
rely on.

Respect the toolchain each project already uses: the package manager the
lockfile points to, the formatter and the linter that are configured. Do not
change them or add new config on your own initiative.

In a new project there is nothing to respect yet, so start from this machine's:
runtimes come from mise and never from Homebrew, Python packages and virtualenvs
from uv, and a project that needs a version other than the global one gets its
own `mise.toml` rather than a global change. Never `pip install` into the
interpreter itself, and never reach for `python -m venv` when `uv venv` is
there. If a project needs a native library — the kind uv installs a wrapper for
and cannot provide, like the pango behind weasyprint — say so, because that
dependency is invisible to the lockfile and only surfaces at runtime.

A project I will come back to commits its lockfile — `uv.lock`,
`package-lock.json`, whatever its manager writes. Without one, the only record
of which versions worked is the environment itself, and an environment stops
being able to answer the moment its interpreter goes: eight virtualenvs here
died that way on 2026-08-17, four of them with nothing written down. Commit it
for a library too. What a library publishes are the constraints in its
`pyproject.toml`; the lock is so its own development is reproducible, and the
two do not compete. A scratch script is not a project and needs none of this.

For node it is pnpm, declared in `mise/config.toml` and never installed with
`npm i -g`, which writes into a directory named after node's patch version and
loses everything in it on the next bump. npm's `node_modules` is flat, so a
package can require something it never declared — a transitive dependency got
hoisted next to it — and that works until the hoisting changes and then breaks
somewhere else. pnpm resolves only what a package declares, which is the same
thing this file asks for everywhere else: that a declaration mean what it says.
Not yarn, whose Plug'n'Play is stricter still and charges for it continuously,
a trade that pays off for a monorepo with workspaces and not for ten separate
projects. Existing npm projects stay on npm; the rule above about respecting a
project's toolchain outranks this one.

Do not declare `packageManager` in `package.json` on this machine: corepack is
what reads that field, and node removed corepack from the distribution — 26
ships `node`, `npm` and `npx` and nothing else. The lockfile is what says which
manager a project uses, and it cannot be wrong about it, because the manager is
what wrote it.

The version file has to be one mise reads. `.nvmrc` and `.python-version` are
ignored on this machine — mise leaves `idiomatic_version_file_enable_tools`
empty by default — so they read like a declaration and do nothing at all. That
is worse than declaring nothing: a project here asked for node 22 in `.nvmrc`,
ran on 26 for months, and published from CI on 22. `mise.toml`, always.

Do not create files that are not needed. No READMEs, summaries or
"implementation notes" documents unless I ask for them.

## Code

Comment the why, not the what. If the comment repeats what the next line
already says, drop it. The ones worth keeping explain a decision, an edge case,
or something that would surprise the reader.

Write tests when there is logic with real edge cases. Not for getters,
wrappers or one-line functions.

When you finish, tell me what actually happened: if a test fails, show me the
output; if you left something half done, say so. I prefer an uncomfortable
report to an optimistic one.
