# Contract: how dotfiles installs `sdd-routing`

Between the new repository (producer) and dotfiles (consumer). Anything the
consumer relies on is here; anything else may change in a release.

## The declaration (dotfiles)

One line in `uv-tools.txt`, same two fields as every other tool:

```
sdd-routing  git+https://github.com/camilopiedra92/sdd-routing.git@v0.1.0
```

`install.sh` applies it with `uv tool install --from <ref> sdd-routing` (its
existing loop). `drift.sh` already compares the receipt's reference, reports a
dead interpreter (`uv_tools_drift`) and a tag behind the latest GitHub
Release (`stale_uv_pins`).

## What the release provides (new repository)

1. A git tag `vX.Y.Z` and a GitHub Release of the same name. `stale_uv_pins`
   reads `releases/latest`, so a tag without a Release is invisible to it.
2. A buildable wheel from that tag with build backend pinned exactly
   (`hatchling==<x>`), whose files are:
   - `sdd_routing/__init__.py`: two launchers only.
   - `sdd_routing/{bin,claude,containers}/...`: the tracked runtime files, byte
     for byte, modes kept (`force-include`). Not `checks/`, `specs/`, `docs/`.
3. Two console scripts, installed by uv into `~/.local/bin`:
   - `sdd-run`: `os.execv(<package>/bin/sdd-run.sh, ["sdd-run.sh", *argv])`.
   - `sdd-step`: `os.execv(<package>/bin/sdd-step.sh, ["sdd-step.sh", *argv])`.
   A launcher does nothing else: no environment, no path computation beyond
   `dirname(realpath(__file__))`.
4. The harness's own resolution is unchanged: every script computes its root
   from `realpath` of itself and finds `claude/speckit/...`,
   `claude/config-guard.sh`, `containers/worker/` and `bin/...` below it.

## Observable behaviour (what dotfiles' report and the scratch-HOME proof assert)

| Command | Result |
|---|---|
| `sdd-run` (no arguments) | exit 2; first stderr line starts `usage: sdd-run ` |
| `sdd-run routing` outside a git repository | exit non-zero; `sdd-run: run sdd-run from the root of a git repository` |
| `sdd-step` outside a run | exit 1; `sdd-step: SDD_RUN_DIR names no run bundle; run through sdd-run` (static, `bin/sdd-step.sh`; re-observed in T-wheel) |
| installed tree vs tag | `diff -r` of `bin/`, `claude/`, `containers/` against the tag's tracked files is empty |

(The first two rows were observed 2026-10-23 on a scratch package built from
the branch tip; the third is read from the script and is to be observed by
T-wheel before it is relied on.)

## Failure modes and who reports them

| Failure | Reported by |
|---|---|
| tag missing | `install.sh` fails at `uv tool install` naming the tag (observed: `failed to fetch branch or tag`) |
| declared, not installed | `drift.sh` `uv_tools_drift` |
| installed reference differs from the declared | `drift.sh` `uv_tools_drift` |
| interpreter gone | `drift.sh` `uv_tools_drift`, and the new "sdd-run answers" report |
| tag moved after install | new `drift.sh` report: receipt's commit vs `git ls-remote <url> <tag>` |
| tag behind latest Release | `drift.sh` `stale_uv_pins` |
| host prerequisite missing (`container`, `check-jsonschema`, `specify`, kernel) | `sdd-run` at start (its `TOOL_HINTS`), `drift.sh` for the kernel |

## Upgrade path

Edit the tag in `uv-tools.txt`, `./install.sh` (re-runs with the new reference),
commit. A run in progress keeps its frozen `code/` (R28 of 003) and is not
affected.

## Rollback

Edit the tag back and `./install.sh`; or revert the wiring PR and
`uv tool uninstall sdd-routing`.
