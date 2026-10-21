# Contract: the contained pass

Every agent step — each judgment phase, both implementers — and every verify
runs as one contained pass, the same way (research R21). It enforces the threat
model of research R20 by construction rather than by naming files. Every host step of a pass —
this contract's and every `sdd-step` and `sdd-run` subcommand's — starts in
the run bundle's directory with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and calls
its tools by absolute path, so no file in any worktree or export (a
`mise.toml`, an `.envrc`, a `.tool-versions`, whatever a future tool reads)
ever configures a host tool: an agent's
output is data until judged, it runs only inside the container, it never
governs the run, and no host tool reads it as configuration.

## Host git

Every git command the run executes on the host — the commit before a pass,
the apply and its commit, `mark`'s commit, the diff review reads — runs as
the system `git` by absolute path with `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL=/dev/null`, `-c core.hooksPath=/dev/null`,
`-c core.fsmonitor=false` and `-c commit.gpgsign=false`, and the repository
named with `-C`: no repository hook (dotfiles' own `core.hooksPath` included)
and no configuration an agent could have written runs during a run.

## Steps

1. **Export**: the feature directory is committed first (`sdd: <feature>
   before <phase>`, Host git), so every earlier phase's output is in `HEAD`;
   then `git archive HEAD` of the feature's worktree is extracted into a
   temporary directory labelled with the run id — tracked files only, no
   `.git`, no untracked or ignored file. A second export of the same commit is
   kept untouched as the baseline.
2. **Inputs**: read-only mounts beside the export — `/bundle/profile.json` (the
   row's profile), `/bundle/check.json` (verify and the implementer only) and,
   for the review row, `/input/diff.patch`: the diff from the run's base
   commit to `HEAD`, made on the host (Host git), which the export, having no
   history, cannot show (FR-019).
3. **Container**: the worker image (built by `prepare-worker`), the export
   mounted alone at `/work`, the inputs above, the run's cache volume for the
   implement rows and verify only, `NET_ADMIN`/`NET_RAW` only for the firewall
   script, which runs first and denies all egress but the pass's allow list:
   its own provider's API host for a judgment or review row
   (`api.anthropic.com`); that host plus the registries in
   `egress-registries.txt` for an implement row (`api.anthropic.com` or
   `api.deepseek.com`); the registries alone for verify. Then the agent, or
   the check command, runs as the non-root user `node`; Claude with
   `--setting-sources ""` so a tracked `.claude/settings.json` in the export
   adds nothing to its profile (pending T003; the container and the writes list
   bound it either way); the credential, when there is one, is written to
   stdin and read once by the entrypoint. For the specify row no feature
   directory exists yet: Spec Kit's `create-new-feature.sh` numbers one in the
   export, and the judge accepts exactly one new directory under `specs/`
   (contracts/routing.md); for the other rows `SPECIFY_FEATURE_DIRECTORY` names
   the feature, so Spec Kit's scripts need no git.
4. **Limit**: the row's `timeout` bounds steps 1–9; at the limit the container
   is stopped and the pass fails with nothing applied.
5. **Patch**: `git diff --no-index --binary --no-prefix` between the baseline
   and the agent's export (Host git), the working directory in the bundle; its
   paths are relative to the export root, as `git apply -p0` reads them.
6. **Judge**, failing closed — a judge that cannot run fails the pass:
   - every created, changed or deleted path matches the row's `writes`
     (contracts/routing.md); for the implement rows, `writes` is everything
     but the protected set — `.git` and `.git*` files, `.claude`, `.specify`,
     `.sdd`, `.github` and everything under them, `CLAUDE.md`,
     `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, at any depth — whose members
     govern the run, instruct a later agent, or run in CI;
   - every entry is a regular file whose mode is 644 or 755: a symlink, a
     submodule or any other mode change stops the pass;
   - for the implement rows, each path goes to the bundle's copy of
     `config-guard.sh`, run by absolute interpreter path, and an `ask` stops
     the pass (FR-008); a path the frozen check command runs (its script, or
     under its directory) is recorded as a check change (FR-029);
   - the patch, the result's text and `structured_output` are scanned for the
     exact value of every credential of the run, read from the Keychain into
     the scanner through a pipe and never written; a match stops the pass,
     naming the credential, not showing it (FR-009).
   A path or entry the judge refuses is named; nothing is applied.
7. **Apply**: `git apply -p0 --index` of the judged patch on the feature's
   worktree, which no agent ever wrote, and one commit, `<phase>: <feature>
   (<model>)` (Host git).
8. **Results**: the agent's JSON result is read from the container's stdout:
   `structured_output` to the row's outcome file, the result's text to
   `result_to`, usage to the run's `usage.jsonl`.
9. **Clean up**: both exports and the container removed, whatever happened.
   A pass whose own process was killed cannot clean up; `sdd-run start` and
   `resume` call `sdd-step cleanup` first.

## Verify

The same pass with no agent: the export of `HEAD`, `/bundle/check.json`, the
cache volume, the container with the registries only, the check command run
as `node`, no patch, no apply; its exit status, the tail of its output, and
the check changes the implement passes recorded since the last verify go to
`.sdd/verify.json` (FR-020, FR-028, FR-029).

## Never

- A credential in a command-line argument, the environment of any host
  process, any file on the host, an image layer, a container's stored
  configuration, the container runtime's logs, the run's state or logs, an
  agent's session files, or anything an agent returns (FR-009).
- A mount but the export, the inputs of step 2 (read-only) and, for implement
  rows and verify, the run's cache volume.
- A host tool run with its working directory, `PATH` or configuration taken
  from a worktree or an export.
