# Inventory: what moves, what stays, what is vendored

Derived 2026-10-23 from branch `003-sdd-model-routing` at `42f05e1` and `main` at
`4f3bb6d` (`git diff origin/main...003`, `git ls-tree`, grep for `DOTFILES`,
`realpath`, `claude/`, `config-guard`, `checks/lib`). `paths.txt` in research R2
is the "Moves" column below. Counts are tracked files at the branch tip.

## Moves (61 files) — same relative path in the new repository

| Group | Paths | Files | Why it moves (who reads it) |
|---|---|---|---|
| CLI and steps | `bin/sdd-run.sh`, `bin/sdd-run.py`, `bin/sdd-step.sh`, `bin/sdd-pass.py`, `bin/sdd-egress-proxy.py` | 5 | the harness |
| Workflow and routing data | `claude/speckit/` (`sdd-routed.yml`, `routing.yml`, `brief.md`, `pi-models.json`, `egress-registries.txt`, `profiles/*.json` x3, `schemas/*.schema.json` x10) | 18 | read by `sdd-run`/`sdd-step`/`sdd-pass` through their root |
| Worker image recipe | `containers/worker/` (`Containerfile`, `entrypoint.sh`, `init-firewall.sh`, `inventory.sh`, `inventory.txt`, `package.json`, `package-lock.json`) | 7 | build context of `prepare-worker`; frozen per run |
| Checks | `checks/91-sdd-routing.sh` ... `checks/96-sdd-end-to-end.sh` | 6 | drive the above against scratch fixtures |
| Check fixtures | `checks/sdd/` (`bundle.py`, `schema-cases.py`, `run-fixture/` x5, `standins/` x4) | 11 | only 91-96 |
| Docs | `docs/sdd-routing.md` | 1 | the harness's guide |
| Spec | `specs/003-sdd-model-routing/` (spec, plan, research, tasks, contracts x4, checklist, ...) | 13 | the harness's own record; keeps its number (R4) |

History also carries `bin/__pycache__/sdd-egress-proxy.cpython-314.pyc` (added
and later deleted): excluded, it is not in the list.

## Created in the new repository (not moved)

| Path | What | Source |
|---|---|---|
| `check.sh`, `checks/lib/runner.sh`, `checks/lib/declarations.sh`, `checks/lib/fixtures.sh`, `githooks/pre-commit`, `checks/07-declarations.sh` | the runner | vendored from dotfiles `main` at a recorded commit (R6) |
| `claude/config-guard.sh` | the judge | vendored (R5) |
| `vendor/SOURCES`, `vendor/sync.sh`, `checks/00-vendor.sh` | commit + sha256 of each vendored file; the only way to move them; the hash check | new, with tests |
| `pyproject.toml`, `sdd_routing/__init__.py` | wheel recipe; two launchers (`sdd-run`, `sdd-step`) that `execv` the scripts beside them | new, with tests |
| `checks/10-wheel.sh` | builds the wheel, installs it into a scratch tool dir, diffs the runtime files, runs the installed command | new |
| `drift.sh` | the worker-image pin report (`worker_pins_latest`, `worker_pin_report`, moved verbatim from 003's `drift.sh`), vendored files behind dotfiles | new, partly moved text |
| `.github/workflows/ci.yml`, `.github/dependabot.yml` (actions + npm in `containers/worker`), `mise.toml`, `mise.lock` | CI | new (R7) |
| `.specify/`, `.claude/skills/speckit-*` | Spec Kit for this repo | `sdd-init` |
| `.specify/memory/constitution.md`, `CLAUDE.md`, `README.md`, `LICENSE` | project files | new (`/speckit-constitution`) |
| `.gitattributes` | marks vendored files `linguist-vendored` | new |

## Edited on the way (the only content changes to moved files)

| File | Change | Check |
|---|---|---|
| `bin/sdd-run.py` | `TOOL_HINTS` (3 strings) and the two messages that say "dotfiles lacks ... update ~/dotfiles" / "dotfiles has ...": name `sdd-routing` and its install instead | 95 (message cases) |
| `checks/92-sdd-worker.sh` | `sed -n '/^worker_pin_report() {$/,/^}$/p' drift.sh` already reads `drift.sh` at the root: unchanged, because the new `drift.sh` has the function at the same spot | 92 itself |
| `docs/sdd-routing.md` | install section: `uv-tools.txt` line, not `install.sh` links | review |
| `checks/91-sdd-routing.sh`, `checks/95`, `checks/96` | `covers:` lines unchanged; none edited unless a first run in the new repository shows a path assumption this inventory missed (then listed here) | the sections |

Variables named `DOTFILES`/`dotfiles` in code and checks keep their names
(cosmetic; renaming is churn with no behaviour).

## Dependency graph (what reads what, from the code)

```
sdd-run (launcher, uv shim) -> bin/sdd-run.sh -> /usr/bin/python3 -I bin/sdd-run.py
   root = dirname(dirname(realpath(sdd-run.py)))
   reads   claude/speckit/{routing.yml,sdd-routed.yml,brief.md,pi-models.json,egress-registries.txt,profiles/,schemas/}
           containers/worker/package.json   (pins check)
   copies  claude/config-guard.sh -> bundle/hooks/ ; FROZEN -> bundle/code/ (same layout)
   needs on PATH: specify, sdd-step, check-jsonschema (+ its ruamel python), git, container, security
sdd-step (launcher) -> bin/sdd-step.sh   [live: PATH check only; in a run: bundle/code/bin/sdd-step.sh]
   root = dirname(dirname(realpath(self)))  -> claude/speckit/schemas, bin/sdd-pass.py
sdd-pass.py   root as above -> schemas, containers/worker (prepare-worker), bin/sdd-egress-proxy.py,
              bundle/hooks/config-guard.sh (judge)
sdd-egress-proxy.py   standalone (stdlib)
checks 91-96  $PWD = repo root -> everything above; 92 -> drift.sh (worker_pin_report);
              94 -> `specify` and check-jsonschema installed; 95/96 build "dotfiles layout" trees under scratch
check.sh      -> checks/*.sh (sourced) + checks/lib/*  [vendored]
```

Cross-repo edges after the move: config-guard (vendored, R5), the runner
(vendored, R6), host tools `container`, `check-jsonschema`, `specify` (declared
by dotfiles, R8), and the uv receipt (dotfiles reads it, R3).

## Stays in dotfiles / wiring (decisions for the hunks of shared files)

| File | 003's hunk | Decision |
|---|---|---|
| `uv-tools.txt` | `check-jsonschema` pin | **kept**: machine prerequisite of the harness, declared by the machine's repo (re-added in the wiring PR); **plus** the new `sdd-routing` line |
| `Brewfile` | `brew "container"` | **kept** (wiring PR) |
| `install.sh` | links for `sdd-run`/`sdd-step`; step 6b kernel | links **dropped** (uv-tools installs them); kernel step **kept** with a check it lacked (T-kernel) |
| `drift.sh` | worker-pin reports; kernel report | worker-pin reports **move** to the new repo's `drift.sh`; kernel report **kept**; two **new** reports: install answers, installed commit equals tag |
| `docs/sdd-routing.md` | the guide | moved; dotfiles' README link now points at the new repository |
| `README.md` | one link | **kept**, retargeted |
| `.github/dependabot.yml` | npm in `containers/worker` | moves (the directory moves) |
| `.github/workflows/ci.yml`, `tool-checksums.txt`, `bump-tools.sh`, `checks/20-tool-versions.sh` | uv for CI | **dropped**: dotfiles' CI needs no uv without the harness |
| `checks/10-lint.sh` | `containers/worker` globs; `no compiled Python` check | globs moved with the dir; the bytecode check is generic, not carried (no Python tracked in dotfiles; stays an option) |
| `checks/50-install.sh` link asserts | `sdd-run`/`sdd-step` links | dropped with the links |
| `checks/50-install.sh`, `55-dev-nuke.sh`, `90-spec-kit.sh` | `grep -q .` rewrites | **not the harness**: out of scope, OQ3 |
| `github/repos.json` | none on 003 | **added** in the wiring PR for the new repo |
| `bin/sdd-init.sh` | T050 pending (not on the branch) | unchanged here, OQ4 |

## What is deliberately not in either repository's tracked files

Run bundles (R28), the worker image (in the container
store), tokens (Keychain).
