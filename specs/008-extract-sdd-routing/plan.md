# Implementation Plan: Extract the SDD routing harness

**Branch**: `008-extract-sdd-routing` | **Date**: 2026-10-23 | **Spec**: [spec.md](spec.md)

**Input**: `specs/008-extract-sdd-routing/spec.md`; decisions and evidence in
[research.md](research.md); paths in [inventory.md](inventory.md); the install
interface in [contracts/install.md](contracts/install.md).

## Summary

Import the harness's 61 files and their 117-commit history unchanged in layout
into a new public repository `camilopiedra92/sdd-routing` (R1, R2, R4), make it
self-sufficient with the runner and the judge vendored byte-for-byte from
dotfiles and checked by hash (R5, R6), package it as a wheel whose only code is
two `execv` launchers so `uv tool` installs it from a tag (R3), run its suite
on a macOS runner (R7). dotfiles then gains one `uv-tools.txt` line and the
machine-level pieces it already owns by constitution I (Brewfile `container`,
the kernel step, drift reports) (R8). Branch 003 and PR #155 close with a
pointer after the first routed run from the installed command (R10).

## Technical Context

**Languages**: bash 3.2 (runner, sections, steps), Python 3.9 stdlib (the
harness, on `/usr/bin/python3 -I`), Python >=3.9 for the launcher (runs on
uv's interpreter, 3.13 observed), YAML, JSON Schema.
**Dependencies added to the new repository**: `hatchling==1.27.0` (build only,
observed to build the probe wheel), `uv` and `mise` (CI), the lint tools.
**Dependencies added to dotfiles**: none new. One `uv-tools.txt` line,
`check-jsonschema` and `container` carried over from 003's hunks.
**Testing**: the new repository's sections (existing 91-96 move unchanged;
new: vendor hash, wheel). dotfiles: a section for the kernel step and the two
drift reports' logic, against stubs.
**Target**: macOS on Apple Silicon only, both repositories.
**Scale**: 61 files moved; about 12 K lines of code, checks and spec.

## Constitution Check (dotfiles, v2.0.0)

- **I Declared, never hand-installed**: the harness arrives through
  `uv-tools.txt`; `container` through the Brewfile; the kernel by install.sh
  step already named by 003. No new manifest, so no amendment. PASS.
- **II One owner per layer**: uv owns the Python application; no `pip`; no
  runtime from Homebrew; no identity versioned. PASS.
- **III One gate, seen red**: logic added to dotfiles = the kernel step's
  branch, two drift reports' tests. Each ships with a check that was seen red
  (tasks T016-T019). The new repository's launcher and vendor check likewise
  (T006, T008). The launchers are wrappers whose only branch is which script
  to exec: the constitution's exemption would cover them; they get a check
  anyway because the install path depends on them (cheap, seen red).
- **IV Apply and report are twins**: install.sh kernel step <-> drift report;
  uv-tools line <-> `uv_tools_drift`, `stale_uv_pins`, plus the two new
  reports. Idempotence: the existing "install.sh is idempotent" section covers
  the uv loop; the kernel step gets its own second-run case.
- **V Upstream's files stay upstream's**: dotfiles vendors nothing from the new
  repository (installed, not copied). The new repository vendors from dotfiles;
  its constitution carries the principle (R12.1).
- **VI The why beside the subject**: every comment added states the observation
  and its date (R-numbers cited).
- **Governance**: two pull requests, squash, `check` required; the new
  repository gets the same ruleset (`github/repos.json`).

## Project Structure

### Documentation (this feature)

```
specs/008-extract-sdd-routing/
  spec.md  plan.md  research.md  inventory.md  tasks.md
  contracts/install.md
```

No `quickstart.md` or checklist: the verification sequence is the tasks; domain
checklists are not required (the owner's instruction). Open questions are in
research.md.

### New repository (`~/Development/sdd-routing`)

```
bin/ claude/ containers/ docs/ specs/003-sdd-model-routing/   moved, layout unchanged
checks/{91..96}-*.sh  checks/sdd/                              moved
check.sh checks/lib/ githooks/pre-commit checks/07-declarations.sh   vendored
claude/config-guard.sh                                         vendored (and used)
vendor/{SOURCES,sync.sh}   checks/00-vendor.sh   checks/05-lint.sh  checks/10-wheel.sh
sdd_routing/__init__.py  pyproject.toml  drift.sh  mise.toml  mise.lock
.github/{workflows/ci.yml,dependabot.yml}   .specify/  .claude/skills/speckit-*  CLAUDE.md README.md
```

### dotfiles (changed by the wiring PR)

`uv-tools.txt`, `Brewfile`, `install.sh` (kernel step), `drift.sh`, `checks/`
(one section, `# covers:` its files), `github/repos.json`, `README.md`,
`docs/maintenance.md`, `docs/decisions/0001-...md`.

## Design notes

### Import, then change (two commits' worth of history, not one)

`main` of the new repository is the import alone: `fast-export | fast-import` of
the moved paths. Every change (vendoring, packaging, messages, CI) is on a
branch and reaches `main` through PR 1, so a reviewer reads the edits against an
untouched import, and the import can be re-run and compared byte-for-byte
(blob ids at the tip equal the source's, observed). The owner pushes `main` as the
one allowed first push to an empty repository (the ruleset is applied after).

### The launchers

```python
ROOT = dirname(realpath(__file__))
def sdd_run():  os.execv(join(ROOT, "bin", "sdd-run.sh"),  ["sdd-run.sh",  *sys.argv[1:]])
def sdd_step(): os.execv(join(ROOT, "bin", "sdd-step.sh"), ["sdd-step.sh", *sys.argv[1:]])
```

Nothing else. The wheel check proves the installed tree equals the tracked
files and both commands answer from a directory with no dotfiles.

### Vendoring

`vendor/SOURCES` lines: `<path> <source repo> <commit> <sha256>`.
`vendor/sync.sh <ref>` fetches each listed file with `git show <ref>:<path>`
from a dotfiles clone (or `gh api` for a public ref), writes it, rewrites its
line. `checks/00-vendor.sh` recomputes each sha256 and fails on a mismatch, a
file without a line, or a line without a file. `drift.sh` (report only, needs
network) compares the recorded commit's blob to dotfiles `main`'s.

### Cut-over (R10) and catch-up

1. T001 freezes the 003 tip. If the 003 agent committed after the import ran,
   catch-up = re-run the same command into a new scratch repository, compare
   its first N commits' tree ids to the import's (identical when nothing before
   changed), and `git fetch` + fast-forward `main` before the repository is
   published. After publication, a catch-up is a PR with the later commits
   cherry-picked from the 003 branch limited to the moved paths. The plan avoids
   it by sequencing: the owner publishes only after 003 is stopped.
2. Order: new-repo PR 1 -> tag/Release -> scratch-HOME proof -> dotfiles PR 2 ->
   first routed run -> close 003. Each arrow waits for the previous to be green.
3. Rollback: R10.

### Constitution of the new repository

At T004, `/speckit-constitution` is run with R12's seven candidates as input;
each principle that cannot name its check or reviewer step is dropped. That
document is the authority for the new repository from then on.

### Risks

- **uv venv death / interpreter bump**: reported by `uv_tools_drift`; fix is
  `./install.sh`. A live run is unaffected (frozen code).
- **Wheel differs from the tree** (a forgotten force-include): the wheel check.
- **Vendored runner behind**: unaffected behaviour, reported by `drift.sh`.
- **macOS runner minutes**: assumed free for a public repository; if not, the
  suite still runs locally and CI is the only thing lost (OQ7).
- **Public repository content**: the harness, its spec and research are
  published. gitleaks over the whole history runs in the new repository's CI
  and once locally before the first push (T003); research.md/spec text was not
  audited for personal data beyond the owner's name and the session URL lines
  in commit trailers.
