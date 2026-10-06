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

English everywhere: replies to me, and everything that lands in a file —
names, comments, commit messages, repo documentation, log strings, test
fixtures, CLI output. A repo may end up public or shared. This holds when
I write to you in Spanish, which I sometimes will: my language is not the
file's.

## How to work

Calibrate by size. Make a small or mechanical change directly and tell me
afterwards. If it touches several files, changes an interface, or involves a
design decision with real alternatives, propose the approach before writing.

Anything with a real alternative gets the alternative written down before it is
built: what else was considered, and why it lost. Two lines in the commit
message when the decision dies with the commit, a document only when it
outlives it.

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

That applies to comments and documentation, not only to code. A comment or a
README line that describes behaviour is a claim: write what was observed, when
and how it was observed, and say "not tested" or "pending" when it was not —
those are valid states, and a plan's expectation written as a finding is not.
The reader cannot tell the two apart, and will build on either.

The one who reviews cannot be the one who wrote. Re-reading your own diff in the
context that produced it finds the typos and none of the assumptions; what is
needed is a different context, not a particular tool.

No fix before the root cause is understood. Read the whole error, reproduce it,
and find where the bad value comes from rather than where it surfaced. One fix
at a time, and a third failed fix is not a fourth hypothesis — it means the
design is wrong, and that is a conversation rather than another patch.

Do not create files that are not needed. No READMEs, summaries or
"implementation notes" documents unless I ask for them. Directories are named
for what they hold, not for the tool that wrote them: tools get replaced and the
name outlives them.

## Spec-driven development

Spec Kit is the only spec process here; no other planning framework runs
alongside it. Size the process to what a wrong decision would cost:

- Bug fixes, changes to one to three files, scripts, docs and configuration go
  direct, without a spec: test first where there is logic of its own, the
  alternative in the commit. Direct means without a spec; whether to propose
  first still follows "How to work".
- A feature with a real design choice, or a changed interface, takes the short
  path: `/speckit-specify`, `/speckit-plan`, `/speckit-tasks`,
  `/speckit-implement`, then `/speckit-converge` until it reports converged.
  The preset makes implement end each user story with a review from a fresh
  context that tries wrong versions of the code against the tests.
- Domain or money logic, a contract something external consumes, or work across
  more than three or four modules adds `/speckit-clarify` before the plan and
  `/speckit-checklist` and `/speckit-analyze` before implementing.
- When the way to do something is unknown, spike on a throwaway branch and
  specify from what it taught. A spec is not a way to explore.

A repo without `.specify/` gets it at its first feature: `sdd-init` from the
root, which commits Spec Kit with the released test-first and
constitution-authoring presets. Then `/speckit-constitution`, whose preset
decides what goes in for a new project and an existing one alike, and
`@.specify/memory/constitution.md` in its CLAUDE.md, so the constitution
holds for direct changes too and not only inside the speckit skills. The
test-first preset is what keeps each task to one behaviour with its test
first, citing the requirement IDs it implements; `specify preset list` shows
which presets a repo has.

The first time `/speckit-implement` sees the whole suite green, the test-first
preset (v1.4.0 and later) commits a Stop hook: from then on a Claude turn that
ends on a red suite is blocked once, with the failure, so even an unattended
run has been shown it before it ends. A repo with a Stop gate of its own does
not get a second one, and a repo set up with an older preset gets it after
`specify preset update test-first --from <the tag's zip>`, the URL `sdd-init`
holds. To change the command, edit `TEST_COMMAND` in
`.claude/hooks/stop-gate.sh`; to turn the gate off, remove its `hooks.Stop`
entry in `.claude/settings.json` and keep that file, because a missing file
is what makes the next run install it again.

`specs/<n>-<slug>/` is the source of truth for a feature, and the plan's
`research.md` is where its decisions and their alternatives go. Later features
never read it, so a decision that binds them moves out before the feature's
PR opens: a rule every change must meet becomes a constitution principle;
anything else becomes `docs/decisions/NNNN-slug.md` in MADR's shape —
context, options, outcome and its consequences — linking its research.md
entry, and the project CLAUDE.md points there. Only a decision a later
feature would otherwise reopen.

## Toolchain

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
answering the moment its interpreter goes: eight virtualenvs here died that way
on 2026-08-17, four of them with nothing written down. Commit it for a library
too — what a library publishes are the constraints in its `pyproject.toml`, and
the lock is so its own development is reproducible; the two do not compete. A
scratch script is not a project and needs none of this.

For node it is pnpm, declared in `mise/config.toml` and never installed with
`npm i -g` — that directory is named after node's patch version and empties on
the next bump. pnpm resolves only what a package declares, which npm's flat
`node_modules` does not. Not yarn. Existing npm projects stay on npm; respecting
a project's toolchain outranks this.

Do not declare `packageManager` in `package.json` on this machine: corepack is
what reads that field, and node removed corepack from the distribution — 26
ships `node`, `npm` and `npx` and nothing else. The lockfile is what says which
manager a project uses, and it cannot be wrong about it, because the manager is
what wrote it.

The version file has to be one something actually reads. mise leaves
`idiomatic_version_file_enable_tools` empty by default, so it reads neither
`.nvmrc` nor `.python-version`. For node that settles it: corepack is gone,
nothing else reads `.nvmrc`, and a project here asked for node 22 in one, ran on
26 for months, and published from CI on 22. A declaration nothing honours is
worse than none, because with none you look.

`.python-version` is the exception and it matters: uv reads it, and it is what
decides the interpreter `uv venv` builds on. In a uv project that file is the
pin, and deleting it because mise ignores it would break the thing it exists
for. `mise.toml` is for a version something outside a venv has to resolve — a
node project, or a tool that runs before the venv exists.

## Code

Comment the why, not the what. If the comment repeats what the next line
already says, drop it. The ones worth keeping explain a decision, an edge case,
or something that would surprise the reader.

Write tests for logic of its own: a branch, a computation, a parse, a state
change. Not for getters, wrappers, wiring or one-line delegations — the same
line the preset draws. Start from a list of the cases — in the conversation or
the task list, not a new file — simplest first, and take them one at a time. A
test you have not watched fail is not a test: write it first, run it, and check
it failed for the reason you expected — an import or collection error proves the
test was collected, not that it exercises anything. If the first run errors
instead of failing, stub the thing under test until it fails from inside. Then
write the simplest thing that makes it pass: a design document is not a licence
to build past the test in front of you. With the suite green, refactor what that
cycle left — duplication, names that no longer fit — without changing behaviour,
running the suite after each step. A case you think of along the way goes on the
list, not into the test in progress.

When you finish, tell me what actually happened: if a test fails, show me the
output; if you left something half done, say so. I prefer an uncomfortable
report to an optimistic one.
