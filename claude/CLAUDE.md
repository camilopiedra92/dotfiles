# Global preferences

## Environment

- `~/Development` is a container folder, not a project. Each subfolder is an
  independent project with its own git, toolchain and conventions: what holds
  in one is checked again in the next, and files go inside a project, never
  loose at the root of `~/Development`.
- Claude Code and shell configuration live in `~/dotfiles` (versioned). The
  symlinks in `~/.claude/` (CLAUDE.md, `*.sh`, each skill in `skills/`) are
  edited at their target under `~/dotfiles/claude/`, never as stray copies.
- Usual stack: Python, Node/TypeScript/JavaScript, React, shell and infra.

## Language

English everywhere: replies to me, and everything that lands in a file —
names, comments, commit messages, repo documentation, log strings, test
fixtures, CLI output. A repo may end up public or shared. This holds when I
write to you in Spanish, which I sometimes will: my language is not the file's.

## How to work

### Before building

- Calibrate by size. Make a small or mechanical change directly and tell me
  afterwards. If it touches several files, changes an interface, or involves a
  design decision with real alternatives, propose the approach before writing.
  If what I asked for has a simpler way to the same result, say so before
  building mine.
- When a request reads two ways and the reading changes the result, do not
  pick one silently: ask if a wrong guess is costly to undo, otherwise take the
  likelier reading and say which one you took when you finish.
- Once you have read the code the change touches, reuse before writing, in
  order: this codebase, the stdlib, the platform (`<input type="date">`, a DB
  constraint), an installed dependency, new code. Ask before a new dependency.
- When I ask whether something is best practice, judge it against the
  authoritative source — the published schema, the vendor's docs, the upstream
  release calendar — not against what is already configured here: reading a
  setup in order to review it biases towards keeping it. Deleting a line is a
  valid answer and often the right one: pinning a value that is already the
  default buys nothing today and blocks the better default tomorrow.

### While building

- Every changed line traces to the request. Something unrelated you notice on
  the way — dead code, a nearby bug, a style you would not have chosen — is out
  of scope: mention it, do not fix it. What your own change left orphaned, you
  remove.
- Anything with a real alternative gets the alternative written down before it
  is built: what else was considered, and why it lost. Two lines in the commit
  message when the decision dies with the commit, a document only when it
  outlives it.
- An escape hatch — `# fmt: off`, a `noqa`, a skipped test, a linter exclude
  for one file — is a workaround until justified: first look for the design
  that needs none. One that stays carries a comment beside it saying why, and
  what would let it go. A tree the project chose not to check, such as vendored
  or frozen code, is scope, not an escape hatch.
- No fix before the root cause is understood. Read the whole error, reproduce
  it, and find where the bad value comes from rather than where it surfaced.
  One fix at a time, and a third failed fix is not a fourth hypothesis — it
  means the design is wrong, and that is a conversation rather than another
  patch. `/diagnose` carries the method.
- Do not create files that are not needed. No READMEs, summaries or
  "implementation notes" documents unless I ask for them. Directories are named
  for what they hold, not for the tool that wrote them: tools get replaced and
  the name outlives them.

### Proving and reviewing

- Prove things rather than assert them. If a claim can be settled with a
  command, run it first — and say plainly when something cannot be determined
  from here instead of picking the likely answer.
- When you add a check, break it on purpose and watch it go red before trusting
  it: a check nobody has seen go red is a check nobody should rely on.
- That applies to comments and documentation, not only to code. A comment or a
  README line that describes behaviour is a claim: write what was observed,
  when and how it was observed, and say "not tested" or "pending" when it was
  not — those are valid states, and a plan's expectation written as a finding
  is not. The reader cannot tell the two apart, and will build on either.
- The one who reviews cannot be the one who wrote. Re-reading your own diff in
  the context that produced it finds the typos and none of the assumptions;
  what is needed is a different context, not a particular tool.
- The review comes before the PR is ready: if CI only runs on pull requests,
  open it as a draft and mark it ready once the review is back.
- Ready is not merged: a PR merges only on green CI, for the commit that was
  green. Where the platform can require checks, a ruleset on the default
  branch does, and the merge is `gh pr merge --auto`. Where it cannot — a
  private repository on GitHub's free plan — I get the merge as
  `merge-on-green <n> <merge flags>`, to run in a terminal of its own. A
  repository without CI has no green to wait for: it gets CI first, since its
  checks belong in one command CI runs (see "Toolchain").
- A subagent's report is a claim: verify its diff or rerun its command before
  passing it on as done.

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
- When the idea itself is still open, `/brainstorm` shapes it first and hands
  off to one of the paths above; it writes nothing.

Setup and lifecycle:

- A repo without `.specify/` gets it at its first feature: `sdd-init` from the
  root, which commits Spec Kit with the released test-first and
  constitution-authoring presets. Then `/speckit-constitution`, whose preset
  decides what goes in for a new project and an existing one alike, and
  `@.specify/memory/constitution.md` in its CLAUDE.md, so the constitution
  holds for direct changes too and not only inside the speckit skills.
- The first time `/speckit-implement` sees the whole suite green, the
  test-first preset commits a Stop hook (`.claude/hooks/stop-gate.sh`): from
  then on a turn that ends on a red suite is blocked once, with the failure, so
  even an unattended run has been shown it. A repo with a Stop gate of its own
  does not get a second one. To turn the gate off, remove its `hooks.Stop`
  entry in `.claude/settings.json` and keep that file: a missing file is what
  makes the next run install it again.
- `specs/<n>-<slug>/` is the source of truth for a feature, and the plan's
  `research.md` is where its decisions and their alternatives go. Later
  features never read it, so a decision that binds them moves out before the
  feature's PR opens: a rule every change must meet becomes a constitution
  principle; anything else becomes `docs/decisions/NNNN-slug.md` in MADR's
  shape — context, options, outcome and its consequences — linking its
  research.md entry, and the project CLAUDE.md points there. Only a decision a
  later feature would otherwise reopen.

## Toolchain

- Respect the toolchain each project already uses: the package manager its
  lockfile points to, the formatter, linter and type checker the project
  configures. Do not change them or add new config on your own initiative.
- In a new project there is nothing to respect yet, so start from this
  machine's: runtimes from mise, never Homebrew; Python packages and virtualenvs
  from uv (`uv add`, `uv venv`), never `pip install` into the interpreter nor
  `python -m venv`; a version other than the global one in the project's own
  `mise.toml`, never a global change. Say so when a project needs a native
  library uv installs the wrapper for but cannot provide (the pango behind
  weasyprint): the lockfile cannot see it, and it only surfaces at runtime.
- A project I will come back to commits its lockfile, whatever its manager
  writes (`uv.lock`, `package-lock.json`), libraries included: they publish
  their `pyproject.toml` constraints, the lock makes their own development
  reproducible; the two do not compete. Without one, only the environment
  records which versions worked, until its interpreter goes: eight virtualenvs
  here died that way on 2026-08-17, four with nothing written down.
- Such a Python, TypeScript or JavaScript project has a formatter, a linter and,
  outside plain JS, a type checker: dev dependencies, config in the repo, one
  command CI runs (else a pre-commit hook) and you run before calling work done.
  Defaults, as in ~/Development: ruff and mypy via `uv add --dev`; prettier and
  eslint, plus typescript-eslint and `tsc --noEmit` for TypeScript. New projects
  get them at scaffold; a role an existing one lacks is offered once, as its own
  change, not mid-task. Scratch scripts need none of this, nor a lockfile.
- For node it is pnpm, declared in `mise/config.toml`, never `npm i -g` (that
  directory is named after node's patch version and empties on the next bump).
  pnpm resolves only what a package declares; npm's flat `node_modules` does
  not. Not yarn. Existing npm projects stay on npm: a project's toolchain wins.
- Do not declare `packageManager` in `package.json` on this machine: corepack is
  what reads that field, and node removed corepack from the distribution — 26
  ships `node`, `npm` and `npx` and nothing else. The lockfile says which
  manager a project uses, and cannot be wrong about it: the manager wrote it.
- The version file has to be one something reads. mise leaves
  `idiomatic_version_file_enable_tools` empty by default, so it reads neither
  `.nvmrc` nor `.python-version`, and with corepack gone nothing else reads
  `.nvmrc`: a project here asked for node 22 in one, ran on 26 for months and
  published from CI on 22. A declaration nothing honours is worse than none,
  because with none you look: for node, no `.nvmrc`.
- `.python-version` is the exception: uv reads it to pick the interpreter
  `uv venv` builds on, so it is a uv project's pin, and deleting it because mise
  ignores it breaks what it exists for. `mise.toml` is for a version resolved
  outside a venv: a node project, or a tool that runs before the venv exists.

## Code

- Comment the why, not the what: a decision, an edge case, a surprise, or a
  deliberate shortcut's ceiling and its trigger (`O(n²); index past 10k rows`).
- Build only what today's callers need. No abstraction with a single caller,
  no option or extension point nobody asked for, no handling for a state the
  code cannot reach. If someone reading it cold would call it overbuilt, it is.
- Write tests for logic of its own: a branch, a computation, a parse, a state
  change. Not for getters, wrappers, wiring or one-line delegations. Where a
  project's constitution draws this line, its line applies there.
- Start from a list of the cases — in the conversation or the task list, not a
  new file — simplest first, and take them one at a time. A case you think of
  along the way goes on the list, not into the test in progress.
- A test you have not seen go red, for the reason you expected, is not a test:
  write it first, run it, and read why it failed — an import or collection
  error proves the test was collected, not that it exercises anything. If the
  first run errors instead of failing, stub the thing under test until it fails
  from inside.
- Then write the simplest thing that makes it pass: a design document is not a
  licence to build past the test in front of you. With the suite green,
  refactor what that cycle left — duplication, names that no longer fit —
  without changing behaviour, running the suite after each step.

When you finish, tell me what actually happened: if a test fails, show me the
output; if you left something half done, say so. I prefer an uncomfortable
report to an optimistic one. Close loose ends inside what was agreed instead of
listing them; pending is only what needs my decision or is out of scope.
