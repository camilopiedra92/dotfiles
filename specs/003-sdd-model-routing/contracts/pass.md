# Contract: the contained pass

Every agent step — each judgment phase, both implementers — and every verify
runs as one contained pass, the same way (research R21). It enforces the threat
model of research R20 by construction rather than by naming files: an agent's
output is data until judged, it runs only inside the container, it never
governs the run, and no host tool reads it as configuration.

## Steps

1. **Export**: `git archive HEAD` of the feature's worktree, extracted into a
   temporary directory labelled with the run id. Tracked files only — no
   `.git`, no untracked or ignored file (no `.env`, no `CLAUDE.local.md`). The
   feature directory is committed first (`sdd: <feature> before <phase>`), so
   every earlier phase's output is in `HEAD`. A second export of the same
   commit is kept untouched as the baseline.
2. **Container**: the worker image (built by `prepare-worker`), the export
   mounted alone at `/work`, the bundle's profiles and routing mounted read-only
   at `/bundle`, the run's cache volume, `NET_ADMIN`/`NET_RAW` only for the
   firewall script, which runs first and denies all egress but the pass's
   allow list: the registries in `egress-registries.txt` plus, for an agent
   pass, only its own provider's API host — `api.anthropic.com` for a Claude
   row, `api.deepseek.com` for a pi row — and nothing more for verify. A
   Claude pass cannot reach DeepSeek, and a verify cannot reach either. Then the agent, or the check command, runs as the
   non-root user `node`; `SPECIFY_FEATURE_DIRECTORY` names the feature so Spec
   Kit's scripts need no git; the credential, when there is one, is written to
   stdin and read once by the entrypoint.
3. **Limit**: the row's `timeout` bounds steps 1–8; at the limit the container
   is stopped and the pass fails with nothing applied.
4. **Patch**: `git diff --no-index --binary` between the baseline and the
   agent's export, run outside any repository with `GIT_CONFIG_NOSYSTEM=1` and
   `GIT_CONFIG_GLOBAL=/dev/null`, by absolute path to the system `git`, with a
   fixed `PATH` and the working directory in the bundle — so no file the agent
   wrote is read as configuration, hook or interpreter (no `mise.toml`, no
   `.envrc`, no `.gitattributes`).
5. **Judge**: every created, changed or deleted path must match the row's
   `writes` (contracts/routing.md); a path outside it stops the pass naming it.
   For the implement rows, whose `writes` is everything but the protected set
   — `.git*`, `.gitattributes`, `.gitignore`, `.claude/**`, `.specify/**`,
   `.sdd/**`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`,
   `mise.toml`, `.mise.toml`, `.envrc`, `.github/**`, at any depth — each path
   is also passed to the bundle's copy of `config-guard.sh`, run by absolute
   interpreter path from the bundle, and an `ask` stops the pass naming the
   path (FR-008). A judge that fails to run fails the pass; it never passes it.
6. **Apply**: `git apply --index` of the judged patch on the feature's
   worktree, which no agent ever wrote, with `core.hooksPath=/dev/null`,
   `core.fsmonitor=false` and the same configuration isolation as step 4, then
   one commit, `<phase>: <feature> (<model>)`.
7. **Results**: the agent's JSON result is read from the container's stdout:
   `structured_output` to the row's outcome file, the result's text to
   `result_to`, usage to the run's `usage.jsonl`.
8. **Clean up**: both exports and the container removed, whatever happened.
   A pass whose own process was killed cannot clean up; `sdd-run start` and
   `resume` call `sdd-step cleanup` first.

## Verify

The same pass with no agent: the export of `HEAD`, the container with the
registries only, the check command frozen in the bundle run as `node`, no
patch, no apply; its exit status and the tail of its output go to
`.sdd/verify.json` (FR-020, FR-028).

## Never

- A credential in a command-line argument, the environment of any host
  process, any file on the host, an image layer, a container's stored
  configuration, the container runtime's logs, the run's state or logs, or an
  agent's session files (FR-009).
- A mount of anything but the export, the bundle (read-only) and the run's
  cache volume.
- A host tool run with its working directory, `PATH` or configuration taken
  from a tree an agent wrote.
