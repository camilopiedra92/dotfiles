# dotfiles Constitution

This machine's development environment, declared as code: macOS on Apple
Silicon only, the assumption everything here is built on.

## Core Principles

### I. Declared, Never Hand-Installed

Whatever this repository puts on a machine MUST come from a manifest in it,
besides the two bootstraps `install.sh` runs directly — Homebrew's installer
and rustup's stable toolchain:
`Brewfile` and each profile's `macos/machines/<p>/Brewfile`, `mise/config.toml`,
`uv-tools.txt`, `macos/*.txt` and each profile's `defaults.txt`, `dock.txt`
and `handlers.txt`, `claude/mcp.json` and each profile's `mcp.json`. A change
that adds a tool, a server or a setting adds it to its manifest in the same
commit; installing by hand and declaring later is drift.

Checked by `./drift.sh`, run on the machine the manifests describe, which
reports what is present and undeclared and what is declared and missing. It is
deliberately outside `./check.sh`: a CI runner arrives with packages of its
own, so there it would always fail.

### II. One Owner per Layer

Homebrew installs programs, mise installs runtimes, `uv tool` installs Python
applications through `uv-tools.txt`. A runtime MUST NOT come from Homebrew, a
Python package MUST NOT be installed into an interpreter with `pip`, and the
system Python is never touched. Configuration lands at its XDG path, and
identity and secrets — git's name, email and signing key, tokens — are never
versioned: they live in files `install.sh` writes outside the repository
(`config.local`) or in the Keychain.

Checked by `./drift.sh` (`runtimes_not_from_mise`, `dormant_version_managers`,
`uv_tools_drift`) and by gitleaks in `./check.sh`, over the whole history in
CI. The rest only a reviewer can check: no `pip install`, nothing written to
the system Python, no path outside XDG, no identity in a versioned file.

### III. One Gate, Seen Red

`./check.sh` is the single gate: the pre-commit hook, CI and a person run the
same command, and a check means the same on a runner as on a laptop. Every
script, verb, hook or guard this repository writes with logic of its own — a
branch that decides an outcome, a computation, a parse, a state change, a
refusal — MUST ship with a check in `checks/` that drives it against scratch
fixtures, and that check MUST have been seen to fail on the behaviour broken
by hand before it is trusted. The one exemption, which wins over that list: a
wrapper whose only branches choose which command to exec, or stop because a
prerequisite — a file, a command, a variable — is absent, without parsing or
computing anything to decide it, needs none; `bin/aware.sh` is one. Passing
on another command's verdict with an option this repository chose, as
`githooks/pre-commit` does with `check.sh --strict`, is logic of its own.

Checked by a reviewer: each new or changed script, verb, hook or guard with
logic of its own has its check in `checks/`, and the pull request or commit
message names the red run.

### IV. Apply and Report Are Twins

Every path that changes the machine has a counterpart that only reports and
never writes: `install.sh` against `./drift.sh`, and `apply` against `check`
in each `macos/*.sh` that takes them. Applying MUST be idempotent: a second
run on a machine that already matches changes nothing.

Checked by `./check.sh`: "install.sh is idempotent", and in each
`checks/7*-macos-*.sh` a check that apply leaves a matching machine alone and
one that check never writes.

### V. Upstream's Files Stay Upstream's

Files another project publishes are vendored byte-for-byte and never edited
here: `schemas/`, what Spec Kit writes under `.specify/` (all but
`memory/constitution.md`) and `.claude/skills/speckit-*/`. Each is marked
`linguist-vendored` in `.gitattributes`. They, and every pin — CI tool
versions with their checksums, action SHAs, `uv-tools.txt` references — move
only through their upgrade path, and a person reading the resulting diff:
`./bump-tools.sh` for CI tools, Dependabot for action SHAs, the command
`./drift.sh` prints for a `uv-tools.txt` tag or a schema, the `specify` CLI
for Spec Kit.

Checked by `./check.sh` ("installed tools match the ci.yml pins", "uv-tools.txt
declares a pinned reference per tool", and zizmor for unpinned actions), and
by `./drift.sh` (`stale_schemas`) for a vendored copy upstream has moved.

### VI. The Why Beside the Subject

The reason behind a choice someone competent would not guess — a workaround,
a deliberate deviation from a default, a trap that cost time once — MUST be
written beside it: a comment next to the code, or `docs/<subject>.md` when it
spans files, saying what was observed, when and how.

Checked by a reviewer, who reads each non-obvious line of the diff for its
reason and its date.

## Governance

This constitution holds for every change, with or without a spec. `main`
takes no direct pushes: every change reaches it through a pull request,
squash-merged with `gh pr merge --auto --squash` only once CI has run
`./check.sh` green, `check` being required by the ruleset `bin/repo-rules.sh`
applies from `github/repos.json`. A change made outside `/speckit-*` commands
is checked against these principles by its reviewer before the pull request
is marked ready.

Amendments are made through `/speckit-constitution` in a pull request of their
own. The version follows semantic versioning: MAJOR for a principle removed or
redefined, MINOR for one added or materially expanded, PATCH for wording.

**Version**: 2.0.0 | **Ratified**: 2026-10-12 | **Last Amended**: 2026-10-12
