# Research: Extract the SDD routing harness

Probes ran 2026-10-22/23 on this machine (macOS 27.0.1, arm64, git 2.55, uv
0.13, mise 2026.10.7), in scratch clones under the session scratchpad
(`.../scratchpad/extract/`), never in either worktree. Nothing here ran
`./check.sh` or a suite. "Observed" means a command was run and its output
read; "static" means read from code; "not tested" is said where it applies.

## R1 — What moves, derived from the code

**Finding (static + `git diff origin/main...003`).** The branch adds or edits 62
non-spec files outside `specs/` and `.claude/`. Sorted by who reads them
(`inventory.md` has the per-path table):

- Used only by the harness: 5 files in `bin/`, 6 check sections, 11 files in
  `checks/sdd/`, 18 in `claude/speckit/`, 7 in `containers/worker/`,
  `docs/sdd-routing.md`, 13 in `specs/003-sdd-model-routing/`. 61 tracked files
  at the branch tip, 4,951 lines of code and recipe (without the lockfile).
- Used by both: `claude/config-guard.sh` (the harness's judge, R5; also the
  interactive Claude PreToolUse hook through `claude/settings.json`) and the
  runner (`check.sh`, `checks/lib/*`, `githooks/pre-commit`, R6).
- Hunks of shared dotfiles files that exist only because of the harness:
  `Brewfile` (`container`), `uv-tools.txt` (`check-jsonschema`), `install.sh`
  (two links, the kernel step), `drift.sh` (+120 lines: worker pins, kernel),
  `bump-tools.sh` and `ci.yml` and `tool-checksums.txt` (uv for CI),
  `dependabot.yml` (npm in `containers/worker`), `checks/10-lint.sh` (globs and a
  bytecode check), `checks/20-tool-versions.sh`, `checks/50-install.sh` (link
  asserts), `README.md` (one link). These never reached `main`; they are
  not "moved", they are re-decided in `inventory.md` "Hunks".
- Three hunks that are not the harness's at all (`grep -q .` to `[ -n "$(...)" ]`
  in `checks/50-install.sh`, the same family in `55-dev-nuke.sh` and
  `90-spec-kit.sh`): they were fixes made on the way, probably under load.
  Out of scope here (global rule: mention, do not fix); they stay on the old
  branch and are offered as an open question.

**Layout assumptions that decide R3 and R4 (static, grep).**

- `bin/sdd-step.sh`, `bin/sdd-run.py`, `bin/sdd-pass.py`: root =
  `dirname(dirname(realpath(self)))`, then `claude/speckit/...`,
  `containers/worker`, `claude/config-guard.sh`, `bin/sdd-egress-proxy.py` under
  that root. 41 mentions of `claude/speckit`, 27 of `config-guard`, 32 of
  `DOTFILES`/`dotfiles` in code (the variable name is cosmetic).
- `sdd-run.py` `FROZEN` copies `bin/sdd-step.sh`, `bin/sdd-pass.py`,
  `bin/sdd-egress-proxy.py`, `claude/config-guard.sh`, `claude/speckit/schemas`,
  `containers/worker` into the run's `code/` "in dotfiles' layout" (R28 of 003).
- Sections 91-96 take `$PWD` (the repository root, set by `check.sh`'s `cd`) as the
  tree under test and build scratch trees "in dotfiles' layout" for 95 and 96.
  None sources a dotfiles helper beyond `check`, `skip`, `STRICT`, `DIM`, `OFF`
  from the runner. 92 extracts `worker_pin_report` from `drift.sh` with `sed`.
- The harness runs on `/usr/bin/python3 -I` (the macOS 3.9) and the system
  `git`, `tar`, `ps`; it reads YAML with the `ruamel.yaml` beside the
  `check-jsonschema` it finds on `PATH`. Host prerequisites it checks by name
  (`TOOL_HINTS`): `specify`, `sdd-step`, `check-jsonschema`, `git`, `container`,
  `security`.

**Decision.** Keep the layout byte-for-byte (R4). Everything above then holds
unchanged and the extraction adds no path-resolution logic.

## R2 — History

**Question.** Can the harness files' history be kept, and at what cost?

**Observed (dry run, scratch clone of the branch tip `42f05e1`, 295 commits).**

`git filter-repo` is installed (`git-filter-repo` 2.47.0 from the Brewfile, so
the premise "not installed" was wrong) but the sandbox this plan was written in
refused every `git filter-repo` command, and `claude/git-guard.sh` names it as
having no safe form. It was not used and not worked around. The dry run is
native git: `git fast-export <branch> -- <paths> | git fast-import` into a new
repository (`paths.txt` is the "Moves" list of `inventory.md`, directories with
a trailing slash):

```
git -C full fast-export 003-sdd-model-routing -- $(cat paths.txt) | git -C fe2 fast-import --quiet
```

| | result |
|---|---|
| commits kept | 117: 110 non-merge (a `rev-list --no-merges` over the same paths counted 109) and 7 merges of the branch's own topic branches (`Merge branch '003-...'`, `t047-probes`); no merge from `main` survives. The 109/110 difference was not chased |
| source commits dropped | 178 (everything from `main`'s history and the branch's commits that only touched dotfiles files) |
| files at tip | 61 (expected 61: 5 + 6 + 11 + 18 + 7 + 1 + 13) |
| authors | 117 by the owner |
| first, last | f4af18d 2026-10-21 (spec), a3c2ae3 2026-10-22 |
| pack after `git gc` | 4.3 MiB (an estimate by `rev-list --objects | pack-objects` of the same paths gave 532 KB; the two differ and the reason was not investigated) |
| tip identical | the 61 blob ids at the result's tip equal the source tip's for the same paths (`ls-tree -r` diff empty) |
| rename kept | `git log --follow claude/speckit/brief.md`: 4 commits in the source, 4 in the result; the three renames of `containers/worker/{brief.md,egress-registries.txt,models.json}` into `claude/speckit/` are covered because the old directory is in the path list |
| `bin/__pycache__/*.pyc` | tracked once, deleted later (`D` in the log); not in the list, so it never reaches the new repository |

The path pattern `containers/worker/` as a whole directory is what makes the
renames follow: naming only the three new paths would lose the commits that
made them. A path that exists at no revision's tip (the old names) cannot be
named on its own: `git fast-export` stops with `no such path in the working
tree`, and with `:(top)` it is accepted and changes nothing.

**Not tested / residual.**

- Commit hashes change (fast-import rewrites them); the dry run keeps no
  mapping from old to new. `git filter-repo` writes `commit-map` and can rewrite
  "commit-ish" mentions in messages; with fast-export a message that quotes
  an old hash (PR text, spec/research.md) keeps the old one. Measured: not
  counted; the spec text refers to commits by subject, not hash in the places read
  (not exhaustive). Open question 1 asks whether the owner prefers to run
  `git filter-repo` himself for the real extraction (it is installed).
- `fast-export` without `--signed-tags=strip` keeps signed-tag data; the branch has
  no tags, and commits are not GPG-signed in the export (SSH-signed commits lose
  their signature on rewrite either way; the new repository's own commits are
  signed afresh).
- The merge commits keep two parents inside the moved paths' history only;
  `git log --graph` in the result was not inspected.

**Decision.** Extract with `fast-export | fast-import` from the final tip of
`003-sdd-model-routing` into a fresh repository, then push as `main`
(squash-merge rule applies to later changes, not the import). Re-run is
idempotent (observed: two runs gave the same tip commit id,
`14fbb19`). Alternative kept open: `git filter-repo` run
by the owner (OQ1). Rejected: `git subtree split` (one prefix only, the harness
is eight prefixes); `git filter-branch` (named by the guard as unsafe and
deprecated by git itself); copying files without history (the 003 research
and 119 commits are the record of why each line is the way it is; R28 and the
reviews cite them).

## R3 — How dotfiles installs the harness

Candidates, with what was observed.

**(a) A Python package through `uv-tools.txt`.** Observed on a scratch package
holding the real tip files:

- `pyproject.toml` with `hatchling==1.27.0` and `[tool.hatch.build.targets.wheel.force-include]`
  mapping `bin`, `claude`, `containers` to `sdd_routing/bin|claude|containers`.
- `uv tool install --from "git+file://<repo>@v0.0.0" sdd-routing`: built and
  installed in 1.35 s; uv printed the commit the tag resolved to
  (`@7a55610...`) and `Installed 1 executable: sdd-run`.
- The installed tree under `.../site-packages/sdd_routing/{bin,claude,containers}`
  is `diff -r`-identical to the source dirs (exec bits kept: `sdd-run.sh`,
  `sdd-step.sh`, `sdd-egress-proxy.py` are 755; `sdd-pass.py` and `sdd-run.py`
  644, as in git).
- A 10-line launcher (`sdd_routing.sdd_run`, `os.execv` of
  `<package>/bin/sdd-run.sh`) is the console script. Run unchanged, the
  harness resolved its root as the package directory and printed
  `usage: sdd-run <start|resume|abort|routing|usage> ...`, exit 2 (the exit
  `drift.sh`-style smoke can assert). `sdd-run routing` outside a repository
  answered `sdd-run: run sdd-run from the root of a git repository`: the real
  code, not the launcher.
- `~/.local/bin/sdd-run` is uv's symlink to the venv's shim, which runs the
  launcher on uv's interpreter, which then execs the harness on
  `/usr/bin/python3 -I` as before. The harness itself never runs on the venv's
  Python.
- The launcher module is the only logic added. `sdd-step` needs a second
  console script because `sdd-run` looks `sdd-step` up on `PATH` (`TOOL_HINTS`);
  `freeze_code` then overwrites `tools["sdd-step"]` with the bundle's copy, so
  the shim's path is only used for the prerequisite check.

For dotfiles this is one line in `uv-tools.txt`. Everything else is already
there: `install.sh` applies the file, `drift.sh` compares the receipt's
reference (`uv_tools_drift`), reports a dead interpreter, and reports a tag
behind upstream's latest release (`stale_uv_pins`, which needs a GitHub
*Release*, not only a tag), and constitution I, II and V are met by existing
machinery.

Costs: the repository carries a packaging file and a launcher, and its CI must
build the wheel and run the installed command (a check of its own). A venv is
one more thing that dies with its interpreter (the incident the global
instructions record); `drift.sh` already reports it. `uv tool upgrade` cannot
move a git pin; moving it is an edit of the tag, as for `specify-cli`.

**(b) A pinned clone into an XDG data dir with `bin/` symlinks**, like the
presets. Not probed beyond reading `bin/sdd-init.sh` and the preset repos:
those presets are installed into a *project's* `.specify/` through `specify
preset add --from <archive URL>`; no preset installs into the machine. (b)
would be new machinery in dotfiles: a manifest (constitution I lists the
manifests; this is a new one, so a MINOR amendment), an `install.sh` step to
fetch and verify, a drift report, and a check for each (constitution III,
IV). Its advantage: the files are a plain checkout, so `realpath` resolves to a
git clone and the layout is trivially the repository's. Its price is exactly the
code (a fetch, a verify, an idempotent replace, a stale/missing report) that
(a) gets from uv.

**(c) Others considered.** Homebrew formula in `camilopiedra92/homebrew-tap`
(it exists): a formula installing `libexec` plus symlinks fits the layout, is
pinned by `url` + `sha256`, and `brew bundle` is already the Brewfile's
verb; but the tap needs a release workflow per tag, its CI is `test-bot
(macos-26)`, and a formula update is a second repository PR per release.
Rejected for now, kept as the fallback if (a) fails (R3 exit criteria below).
A git submodule in dotfiles: pins by commit, but makes `git clone dotfiles`
fetch a 4 MiB product repository, drags the harness's checks into dotfiles'
globs, and nothing installs it. Rejected. `pipx`/`uvx` without a pin:
rejected, the pin is the point.

**Decision.** (a). The deciding facts: one line in dotfiles against a new
subsystem; the probe showed the unchanged harness resolving its root and
answering from the installed tree (R28's bundle layout needs nothing); the
declared-manifest, one-owner and pinned-reference rules are met by what
exists.

**Exit criteria (when to switch to (c)/(b)).** If T-wheel shows the built wheel
differing from the repository's runtime files in any byte, or the installed
`sdd-run` failing a section 95/96 case that passes in the repository, or the
launcher needing more than `execv`, switch to (b) and amend the constitution.

**Pin strength.** `uv-tools.txt` pins a tag, as `specify-cli` does; the harness
holds credentials (the egress proxy) so a moved tag matters more. uv resolves
the tag to a commit and records it in the receipt (printed at install). The new
repository gets a tag-protection ruleset, and `drift.sh` gains one report:
the receipt's commit equals `git ls-remote <url> <tag>`. Open question 2 asks
whether that is enough or the pin should be a commit.

## R4 — Layout of the new repository

Decision: unchanged. `bin/`, `claude/speckit/`, `claude/config-guard.sh`,
`containers/worker/`, `checks/` (section file names kept: 91-96 and
`checks/sdd/`), `docs/sdd-routing.md`, `specs/003-sdd-model-routing/`. Plus new:
`pyproject.toml`, `sdd_routing/__init__.py`, `check.sh` and `checks/lib/`
(vendored), `checks/00-vendor.sh`, `vendor/SOURCES`, `drift.sh`, `.github/`,
`mise.toml`, `CLAUDE.md`, `README.md`, `.specify/` (own Spec Kit install).

**Alternatives lost.**

- Flatten `claude/speckit/` to `speckit/` and rename sections to 10-60: 41 + 27
  textual references in code, hundreds in a 3,000-line spec, `urn:dotfiles:sdd:*`
  schema ids inside every outcome file, and R28's frozen layout, all for a
  cosmetic gain. It is path-resolution logic changing in a move that otherwise
  changes none. A later feature can do it with its own tests, with `git mv`
  preserving history.
- Keep the `urn:dotfiles:sdd:<name>:1` schema identifiers: they are contract
  values (`const` in the outcome files), not locations. Changing them is a
  schema version bump, not part of a move.
- Keep the spec's number (`003-sdd-model-routing`): 16 references in code and 27
  in the checks and docs name it; Spec Kit numbers new features from the highest
  existing directory, so the new repository's next feature is 004 and the
  numbers 001-002 are simply not there. A gap is harmless; renumbering breaks
  every citation.

**Edited on the way** (the only content changes, each with a check, `inventory.md`):
user-facing strings that say "dotfiles" where the fix is now another command
(`TOOL_HINTS` x3, `sdd-run.py` "dotfiles lacks ... update ~/dotfiles" and
"dotfiles has"), `docs/sdd-routing.md` install section, and a drift/vendor
check. No path computation changes.

## R5 — `claude/config-guard.sh`: the cross-repo dependency

**Finding (static).** 151 lines, standard library Python inside bash, a stdin
JSON (`tool_name`, `tool_input.file_path`, `content`) to stdout JSON
contract. The harness calls it two ways: it copies it into each run's bundle
(`hooks/config-guard.sh`, plus `code/claude/config-guard.sh`) and
`sdd-pass.py` pipes every changed file to it as a synthetic `Write` to judge
whether a patch touches lint/format/test configuration. Interactive Claude uses
the same file through `claude/settings.json` (`~/.claude/config-guard.sh`).
Section 91 drives it (`config-guard ask`, `judge missing`), `checks/81-config-guard.sh`
in dotfiles tests it for the interactive case.

**Options.**

1. *Vendored pinned copy in the new repository* at the same path
   (`claude/config-guard.sh`), byte-for-byte from a recorded dotfiles commit
   (`vendor/SOURCES`: path, source repo, commit, sha256), a section that fails
   when the copy's sha256 differs from the recorded one, and a report in the
   new repository's `drift.sh` when dotfiles' file at `main` differs from the
   recorded commit.
2. *A third tiny repository* both consume. Two consumers, 151 lines: a release
   process, a CI and a pin in each of two repos for one file. Over-built until
   a third consumer or a diverging need exists.
3. *The harness's own judge*, written afresh or forked. Two judges of "what is a
   check configuration" would diverge silently; the list in this file
   (`WHOLE_FILE`, `CHECKER_TABLES`) is one decision of the owner's, and
   `docs/claude-settings.md` already documents it.
4. *The harness reads `~/.claude/config-guard.sh`*: runtime coupling to
   dotfiles' install; the guard is part of the run's frozen governance (R28)
   and a user-editable file outside the bundle breaks that.

**Decision.** 1. It keeps the harness self-contained (R28), has the same
relative path in both repositories (no edit anywhere), reuses constitution V's
rule that a file another project publishes is vendored byte-for-byte and moves
only through its upgrade path (`vendor/sync.sh <dotfiles ref>`; a person reads
the diff), and the cost of a stale copy is bounded: the judge refuses more or
less than the interactive guard until the sync, nothing breaks. Who is
"upstream": dotfiles, because the guard is born there and serves its
interactive use first.

**Reconsider** when a third consumer appears or the two diverge on purpose.

## R6 — The new repository's runner

**Finding (static).** `check.sh` is 446 lines, generic except one string
(`dotfiles-check.lock` in the lock path); it needs macOS (`lockf`,
`getconf DARWIN_USER_TEMP_DIR`, `sysctl -n hw.ncpu`). Sections source nothing
else but `checks/lib/{runner,declarations,fixtures}.sh`; `githooks/pre-commit`
calls `check.sh --strict --staged`. Its own checks are `05-runner.sh` (770
lines) and `06-lock.sh` (830) plus `07-declarations.sh`.

The runner matters more here than anywhere: the harness sections are the heavy
ones that 004 (tiers, parallel) and 006 (one suite at a time per machine)
exist for.

**Options.**

1. *Vendor `check.sh`, `checks/lib/*`, `githooks/pre-commit`, and
   `checks/07-declarations.sh` byte-for-byte* from a recorded dotfiles commit
   (same `vendor/SOURCES`, same section, same sync script as R5). The
   runner's own tests (`05`, `06`) stay in dotfiles: they test upstream's file
   where it is edited; a vendored copy is unedited by rule, so the check on
   the copy is the hash, not the behaviour.
2. *Convert to the preset repos' `tests/check.sh`* (a flat list of `step`
   commands, stop at first failure). Observed: that file is 21 lines and
   sequential. The harness suite sequentially would take at least the sum of
   its sections (the parallel runner exists because it took 105-201 s with
   them and 12-17 s without), and without the lock several worktrees run at
   once, which 006 recorded ran this laptop hot for hours (2026-10-22).
3. *A third repository for the runner.* Three repos for a 446-line file with two
   consumers; plus a release process. Over-built now; reconsider if a third
   repository wants the runner (the preset repos do not: they run `tests/check.sh`).
4. *Copy the runner and let it diverge.* The thing this feature exists to avoid.

**Decision.** 1. One consequence worth a line: the lock file is
`$(getconf DARWIN_USER_TEMP_DIR)dotfiles-check.lock`, so a suite in the new
repository and one in dotfiles queue behind each other on this machine. That is
the behaviour 006 wants (the machine, not the repository, is what gets hot);
it is not edited.

**Cost accepted.** The new repository's `check.sh` mentions `dotfiles` in a
comment and a lock name. Constitution V's wording applies to it.

## R7 — CI of the new repository

**What needs macOS (static, then observed where stated).**

- The vendored runner (R6): `lockf`, `getconf DARWIN_USER_TEMP_DIR`, `sysctl hw.ncpu`.
  Linux has none of the three in that form.
- Section 95: `stat -f %m` (BSD syntax; on Linux `stat -f` means filesystem
  status). Section 93: `shasum -a 256` (present on Linux runners too).
- The harness hard-codes `/usr/bin/python3 -I`, `/usr/bin/git`, `/usr/bin/tar`
  and `/bin/ps -o lstart=`, and names `/usr/bin/security` in `TOOL_HINTS`
  (the macOS Keychain CLI). On Linux the first three exist, `security` does
  not.
- The container runtime is Apple's `container` (a macOS VM-per-container
  tool). The checks use stand-ins (`checks/sdd/standins/container`), so
  CI needs no real runtime; GitHub's macOS runners do not offer nested
  virtualization for arm64 (not tested here; the stand-ins make it moot).
  The one thing no CI run proves is a real container run: that stays a local,
  manual step recorded in the quickstart (the 003 reviews already did it by hand).

Not probed: running any section on Linux. Static evidence is enough to decide:
the runner is macOS-only by construction, and the product targets macOS.

**Decision.** `runs-on: macos-latest`, one job named `check`, `./check.sh`
(strict through `CI`), as dotfiles does. Free minutes on a public repository
are assumed (spec, Assumptions) and confirmed or refuted by the first run
(T-ci). Tool installation: shellcheck, shfmt, actionlint, zizmor, gitleaks
(the lint sections' tools) and `uv` (for `specify` and `check-jsonschema`) at
pinned versions.

**How to pin the CI tools.** dotfiles does it with `bump-tools.sh`, workflow
env vars and `tool-checksums.txt`; copying that is the drift this feature
avoids, and vendoring `bump-tools.sh` is another 150 lines for 6 tools.
Observed: `mise registry` lists all six (shellcheck, shfmt, actionlint,
zizmor, gitleaks, uv) with `aqua:` backends, so a `mise.toml` plus `mise.lock`
(checksums) pins them for CI (`jdx/mise-action` at a pinned SHA) and for a
laptop alike. `check-jsonschema` is not in the registry: `uv tool install` at a
tag, as dotfiles does. **Decision**: `mise.toml` + `mise.lock`; Dependabot for
action SHAs only. Not tested: that `mise lock` records darwin-arm64
checksums for all five (T-ci's first step); if it does not, fall back to
dotfiles' pattern and say so.

**Required check.** `github/repos.json` gains `"camilopiedra92/sdd-routing":
{"checks": ["check"]}` and `bin/repo-rules.sh` applies the ruleset, as for
dotfiles. Done in dotfiles' wiring PR (it is dotfiles' file).

## R8 — What dotfiles keeps

Machine state the harness needs and dotfiles owns by constitution I:
`brew "container"` (Brewfile), the container kernel step in `install.sh`
(`container system start --enable-kernel-install`, 003's step 6b), its drift
report, `check-jsonschema` and the new `sdd-routing` line in `uv-tools.txt`,
`specify-cli` (already there). Docs: the README's link, `docs/maintenance.md`
mention of how to move the pin. A thin report in `drift.sh`: "sdd-run answers"
(exit 2 and a line starting `usage: sdd-run`) and "the installed commit is the
tag's" (R3). No section in `check.sh`: dotfiles' CI does not install uv tools
(003 added that step for the harness; it is not carried over), so a smoke
check there would be a skip, and strict mode turns a skip into a failure. The
smoke's *logic* (the output test) is driven by a check against a stub command
(constitution III); its *machine* run is `drift.sh`'s.

The three unrelated fixes in `50-install`, `55-dev-nuke`, `90-spec-kit` stay on
the old branch (OQ3).

## R9 — Tag moved, tag missing

A tag that does not exist: `uv tool install` fails with
`failed to fetch branch or tag` (observed in the first probe, which had not
created the tag), and `install.sh` fails there (set -e). A tag that moves: see
R3 "Pin strength".

## R10 — Order, safety, rollback

Because the harness is not on `main`, nothing is deleted from `main`; the old
home is a branch and a draft PR.

1. Freeze: the 003 agent stops; the tip sha is recorded (T-freeze).
2. New repository, PR 1 (inside the new repository; its first commits are the
   import, then the edits): import with history, own `.specify/`, constitution,
   vendored runner and judge, packaging, CI. Green on this machine and in CI.
   Tag `v0.1.0`, GitHub Release.
3. Prove the dotfiles side on a scratch `HOME` from the tag (T-wiring tests).
4. dotfiles PR 2 (`008`): pin, Brewfile, kernel step, drift reports, repos.json,
   docs. Merged only on green CI.
5. First routed run from the installed command by the owner (the evidence that
   closes the move).
6. Only then: close PR #155 and branch 003 with a pointer; keep the branch
   a further 30 days (a tag `archive/003-sdd-model-routing` on its tip).

Rollback: before step 4 merges, nothing to undo (the new repository can be
deleted). After: revert PR 2 (the machine keeps the installed tool until
`uv tool uninstall sdd-routing`), and 003 is still open as a branch until step 6.
The history in the new repository never depends on the dotfiles branch once
imported.

## R11 — 003's open work and 007/009

003's remaining tasks (T049-T051 US3, T052-T055) are tasks.md lines in the
moved spec; they continue there. T050 changes `bin/sdd-init.sh`, a dotfiles
file: after the move the harness owns its workflow installation (a command in
its own repo; `sdd-run` already prints `specify workflow add <source>`), and
dotfiles' `sdd-init.sh` stays presets only (OQ4). T052-T053 (the SC-001/SC-002
measurement) are in `~/Development/spec-kit-preset-story-workers` and run
against a tagged `sdd-routing` release. 007 (`bounded-checks`) and 009 concern
dotfiles' runner and stay; the vendored runner picks up their result only
through R6's sync.

## R12 — The new repository's constitution (candidates, for `/speckit-constitution`)

Only principles with a check or a named reviewer step:

1. *Vendored files stay upstream's*: the runner and the judge equal the recorded
   dotfiles commit (hash check; sync script is the only way to move them).
2. *The installed tree is the repository's*: the built wheel's runtime files
   equal the tracked ones (check builds and diffs); the installed command
   answers.
3. *One gate, seen red* (same wording as dotfiles III, scoped to scripts with
   logic).
4. *Contained pass, frozen run* (the 003 invariants that are checkable today:
   R28's bundle equality, the stand-in-driven containment cases).
5. *The why beside the subject* (as dotfiles VI).
6. *macOS on Apple Silicon only*, as the premise.
7. *Pins move through their upgrade path*: Containerfile digests and snapshot,
   npm lockfile with the inventory, action SHAs, mise lock, `vendor/SOURCES`.

## Measurements

Before (recorded, from the owner's brief): suite 12-17 s without the harness,
105-201 s with; CI 36-51 s on `main`, 355-567 s per push on the branch.
After: pending (SC-001, T-close).

## Open questions (also in the report)

1. Real extraction with `git filter-repo` (installed; commit-map, message
   rewriting) run by the owner, or native `fast-export | fast-import` as
   dry-run here? Differences observed: none in commit count, files or rename
   following; hashes in message text are not rewritten by the native route.
2. Pin the install by tag (precedent, moves with a force-push) or by commit
   (immune; `stale_uv_pins` would then need a mapping)?
3. Keep the three incidental `grep -q .` fixes (50-install, 55-dev-nuke,
   90-spec-kit) as a small direct change in dotfiles, or drop them with the
   branch?
4. Does 003's T050 (workflow install into a repo) belong to the harness's own
   command, leaving `sdd-init.sh` presets-only?
5. Release visibility: GitHub Releases on the new repository (needed by
   `stale_uv_pins`) with immutable releases on?
6. The new repository's default branch name and whether it takes the
   `bin/repo-rules.sh` ruleset (`check` required) from the first commit.
7. CI minutes: macOS runners on a public repository are assumed free; confirm
   on the first run.
8. The imported commit messages end with `Claude-Session: https://claude.ai/code/session_...` trailers and the spec text names local paths and the owner's machine: acceptable in a public repository, or scrubbed (a message rewrite, which only `git filter-repo --message-callback` does cleanly)?

## Decisions on the open questions (2026-10-23)

Taken by the orchestrating session on the owner's delegation ("haz lo mas recomendado"), each with its reason; the owner can overrule any.

1. **History: the native route.** `git fast-export <ref> -- <paths> | git fast-import`. The owner's own `git-guard.sh` names `git filter-repo` as having no safe form, and the dry run needs nothing it would add: 117 commits, 61 files, the 61 blobs at the tip identical to the source's, renames followed by `git log --follow`, the same tip commit id on a rerun. Residual accepted: hashes quoted inside commit messages are not rewritten.
2. **The pin is a tag, protected.** It is the precedent (presets, `uv-tools.txt`) and constitution V's upgrade path is built on it; a tag moves on a force-push, so the new repository carries a ruleset that forbids deleting or moving tags, and dotfiles' drift report names a tag behind the latest release. A commit pin was rejected: it hides the version a person reads in the diff.
3. **The three `grep -q .` rewrites are rescued as a small direct change** to dotfiles' `main` (they are bug fixes of the SIGPIPE class found on 2026-10-22, unrelated to the harness); dropping them with the branch would lose them.
4. **The harness owns installing its workflow into a repository** (003's T050): `sdd-init.sh` stays presets-only, and the harness gets the verb that copies its workflow in. The workflow, the routing and the installer then version together.
5. **GitHub Releases are cut for each tag**, immutable where the account offers it; without Releases dotfiles' stale-pin report cannot see a newer version.
6. **Default branch `main`, and the `check`-required ruleset from the first commit**, declared in `github/repos.json` and applied by `bin/repo-rules.sh` like every repository dotfiles governs.
7. **macOS runners are free on a public repository** (GitHub's published terms for standard runners); the first CI run records duration and whether minutes were billed (T015).
8. **Imported trailers and local paths stay.** Dotfiles' public `main` already carries `Claude-Session:` trailers and the same kind of local paths; no credential is in them (the leak scans of check 91 and gitleaks run on the import); rewriting messages would break the hash parity this extraction proves.
