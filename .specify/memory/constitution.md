# dotfiles Constitution

This machine's development environment, declared as code: macOS on Apple
Silicon only, the assumption everything here is built on.

## Core Principles

### I. Declared, Never Hand-Installed

Whatever this repository puts on a machine MUST come from a manifest in it:
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
`uv_tools_drift`) and by CI's gitleaks scan of the whole history.

### III. One Gate, Seen Red

`./check.sh` is the single gate: the pre-commit hook, CI and a person run the
same command, and a check means the same on a runner as on a laptop. Every
script, verb, hook or guard this repository writes MUST ship with a check in
`checks/` that drives it against scratch fixtures, and that check MUST have
been seen to fail on the behaviour broken by hand before it is trusted.

Checked by `./check.sh` for the first half; the second only a reviewer can
check, by asking for the red run in the pull request or commit message.

### IV. Apply and Report Are Twins

Every path that changes the machine has a counterpart that only reports and
never writes: `install.sh` against `./drift.sh`, and `apply` against `check`
in each `macos/*.sh` that takes them. Applying MUST be idempotent: a second
run on a machine that already matches changes nothing.

Checked by `./check.sh` ("install.sh is idempotent", and each macOS area's
"apply writes nothing when the machine already matches" and "check … never
writes").

### V. Upstream's Files Stay Upstream's

Files another project publishes are vendored byte-for-byte and never edited
here: `schemas/`, what Spec Kit writes under `.specify/` (all but `memory/`)
and `.claude/skills/speckit-*/`. Each is marked `linguist-vendored` in
`.gitattributes`. They, and every pin — CI tool versions with their checksums,
action SHAs, `uv-tools.txt` references — move only through the tool that owns
them (`./bump-tools.sh`, Dependabot, the `specify` CLI) and a person reading
the resulting diff.

Checked by `./check.sh` ("installed tools match the ci.yml pins", "uv-tools.txt
declares a pinned reference per tool"), by zizmor in CI for unpinned actions,
and by `./drift.sh` (`stale_schemas`) for a vendored copy upstream has moved.

### VI. The Why Beside the Subject

The reason behind a choice someone competent would not guess — a workaround,
a deliberate deviation from a default, a trap that cost time once — MUST be
written beside it: a comment next to the code, or `docs/<subject>.md` when it
spans files, saying what was observed, when and how. `README.md` keeps only
entry points and links to `docs/`.

Checked by a reviewer, who reads each non-obvious line of the diff for its
reason and its date.

## Governance

This constitution holds for every change, with or without a spec. `main`
takes no direct pushes: every change reaches it through a pull request,
squash-merged with `gh pr merge --auto --squash` only once CI has run
`./check.sh` green, under the ruleset declared in `github/repos.json`. A
change made outside `/speckit-*` commands is checked against these principles
by its reviewer before the pull request is marked ready.

Amendments are made through `/speckit-constitution` in a pull request of their
own. The version follows semantic versioning: MAJOR for a principle removed or
redefined, MINOR for one added or materially expanded, PATCH for wording.

**Version**: 1.0.0 | **Ratified**: 2026-10-12 | **Last Amended**: 2026-10-12
