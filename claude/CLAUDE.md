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
