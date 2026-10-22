# Checks

## Checks

```bash
./check.sh
```

Linting (shellcheck), formatting (shfmt), the CI workflow itself (actionlint, plus zizmor for
exploitable patterns such as persisted credentials), secrets in history and in
what is staged (gitleaks),
syntax for every config format here, that the login agent plist parses and its
`Label` matches its filename, the statuslines' behaviour, that the tools you
have installed are the versions `ci.yml` pins, that `install.sh` is still
idempotent, that its signing step generates and registers the key once and
only once (against a stub `ssh-keygen`, `ssh-add` and `gh`), that its login
agent step bootstraps once and kickstarts every run (against a stub
`launchctl`), that `macos/defaults.txt` is well-formed, and that
`macos/defaults.sh` writes exactly the differing keys and nothing when the
machine already matches (against a stub `defaults`), and that `macos/power.sh`
writes only through `sudo`, only for a difference, and never from `check`
(against a stub `pmset` and `sudo`), and that `macos/dock.sh` and
`macos/handlers.sh` change only what differs and skip, without failing, an app
that is not installed (against a stub `dockutil` and `duti`), that
`githooks/pre-push` refuses deleting or rewriting the remote's default branch
and nothing else and `githooks/pre-commit` runs the staged paths' sections in strict mode and
refuses any commit they fail (through real pushes and commits in scratch
repositories), that `bump-tools.sh` moves each pin with its checksum and
refuses a downgrade, a 404 or a pin with no checksum line untouched (under a
`PATH` holding only a stub `gh`, `curl` and `mktemp` and links to the
utilities it uses), and that `bin/dev-nuke.sh` signals, quits
and deletes only what it should, as whom it should (under a `PATH` holding
only stubs and links to harmless utilities, so a command it looks up there
cannot act on the machine; absolute paths, redirections and builtins are not
covered by that, and the check's own comment says what limits them).

One script is the whole point. You run it by hand, `githooks/pre-commit` runs it
before every commit, and CI runs that same file rather than reimplementing
anything — checks written twice drift, and the moment CI and local disagree you
stop trusting both. To bypass the hook once: `git commit --no-verify`.

### Tiers: what runs when

This section is the one place that says how much runs when; a rule written in
two places ends by contradicting itself.

| when | what runs | command |
|---|---|---|
| commit (the hook) | the sections the staged paths select, plus every section that declares nothing | `./check.sh --strict --staged` |
| pull request (CI, and the merge gate) | every section | `./check.sh` |
| by hand | every section, or `--staged` for what the hook would run | `./check.sh` |

A section declares what it exercises in lines of its own,
`# covers: <pattern> [<pattern>...]`, bash patterns over a repository path in
which `*` also crosses `/`. A section with none runs for every commit. Under
`--staged` a section is selected when a staged path matches one of its
patterns, and on any doubt every section runs: a staged `check.sh`,
`githooks/`, `checks/lib/`, a section that is added or deleted, a `# covers:`
line that changed, or a path under `checks/` that no section declares. A rename
counts as its old path and its new one. The run says which sections it did not
select. What the hook skips, CI catches before the merge: the tier trades
latency for a later catch, never coverage.

A declaration nobody checks rots into a hole, so the suite fails on a pattern
that matches no tracked file (`checks/05-runner.sh`).

There is no pre-push tier: the hook is already cheap and CI runs everything, so
a third level would repeat one of them.

### How a run executes

Sections run at the same time, at most one per CPU (`sysctl -n hw.ncpu`), each
in a subshell of its own that sees the runner's helpers and `checks/lib/` and
nothing another section defines; before this, three sections leaned on
functions defined by an earlier one and passed only in file order. Each
section's output is held and printed whole, in file order, once it and every
section before it have finished, so the output and the verdict are a sequential
run's. A section that stops before its last line — an `exit`, an unset
variable — fails the run. The run takes about as long as its slowest section
rather than the sum, so one slow section sets the floor: measure it before
splitting anything else (`specs/004-fast-checks/research.md` has the numbers).

A check either runs (`ok` / `FAIL`) or is skipped because its tool is missing.
A skip is a hole in coverage, not a neutral third outcome, so both gates —
CI and the pre-commit hook — turn it into a failure; `./check.sh --strict`
reproduces that by hand. Without it a missing tool turns into a green run that
verified less than you think, which is not hypothetical: CI passed for a while
without ever validating the Ghostty config.

The split is between a gate and a report. Run by hand, an amber skip is a nudge
to install the tool. In the hook it would be a lie: exiting 0 having linted
nothing reads as "this commit passed" when nothing checked it, and the commit
lands regardless. Take shellcheck off `PATH` and change nothing else — without
the flag the run ends `All checks passed` and exits 0, with it `FAIL shellcheck
(not installed)` and exits 1.

This is why CI installs pinned, checksummed copies of shellcheck, shfmt,
actionlint, zizmor, gitleaks, Ghostty and taplo instead of trusting the runner image: strict mode
means anything it fails to install stops the build rather than quietly shrinking
it.

## Configs are validated against schemas, not just parsed

Parsing is the easy half and not the one that bites. `add_newlines` for
`add_newline` is valid TOML; starship prints a warning to stderr, exits 0, and
drops the option, so the prompt simply lacks it and nothing ever says why. Two
of the configs here now have real cover against that, and one always did:

| config | validated by | catches |
|---|---|---|
| `ghostty/config` | ghostty itself, pinned | unknown or renamed keys, unresolvable themes |
| `starship.toml` | taplo + `schemas/starship.json` | unknown keys, wrong types |
| `mise/config.toml` | taplo + `schemas/mise.json` | unknown keys, wrong types |

`.taplo.toml` maps file to schema, and both the CLI and the *Even Better TOML*
editor extension read it — the check and the autocomplete cannot disagree about
what a valid key is. `taplo lint` takes no file list: it discovers every `.toml`
in the repo, so a config added later is covered by existing rather than by
somebody remembering to extend an argument list.

The schemas are **vendored** rather than fetched from
`starship.rs`/`mise.jdx.dev` at check time. A gate must not need the network: a
check that goes red because DNS blinked is a check you learn to ignore.
Vendoring also puts a schema change in a diff somebody reads, the same
reasoning as the pinned hashes in `tool-checksums.txt`.

The cost is that a vendored copy goes stale, and stale has a specific shape:
adopt a key upstream added after the copy was taken, and the check calls your
correct config invalid. `drift.sh` is what notices — it already asks the network
the questions the commit path must not.

Formatting is a separate check, the same split as `shellcheck` and `shfmt`: one
says the file is wrong, the other that it is untidy, and merging them makes a
whitespace diff look like a broken config. **`.editorconfig` does not govern
TOML** — taplo does not read it, verified rather than assumed: set `indent_size`
to 8 there and it still emits two spaces. Its defaults agree with the `[*]`
section today, so nothing visibly disagrees, but changing `indent_size` would
move the editor and leave the check where it was.

`.taplo.toml` restates exactly one formatter default and deliberately not the
others. `indent_string`, `column_width` and `align_entries` are preferences: a
better upstream default would be welcome, and pinning them would refuse it.
`reorder_keys = false` is a different kind of thing — alphabetising these keys
is not a preference this project might come round to, it is permanently wrong,
and the command you would reach for after a failed format check (`taplo fmt`,
which unlike `--check` writes) is exactly what would apply it.

Those pins only mean something while your machine agrees with them, and the
Brewfile installs whatever is current — Ghostty updates itself outright. So the
versions you have are checked against the ones `ci.yml` pins, and a drift fails
here rather than turning into a CI failure nobody can explain later. When it
does fail, either upgrade the pin and its hash in `.github/tool-checksums.txt`,
or pin your local tool back.
