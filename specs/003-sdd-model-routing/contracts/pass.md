# Contract: the contained pass

Every agent step — each judgment phase, both implementers — and every verify
runs as one contained pass, the same way (research R21). It enforces the threat
model of research R20 by construction rather than by naming files. Every host step of a pass —
this contract's and every `sdd-step` and `sdd-run` subcommand's — starts in
the run bundle's directory with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and calls
its tools by the absolute paths `sdd-run start` resolved once, from the
bundle's directory with the owner's `PATH`, and froze in `tools.json`, so no file in any worktree or export (a
`mise.toml`, an `.envrc`, a `.tool-versions`, whatever a future tool reads)
ever configures a host tool: an agent's
output is data until judged, it runs only inside the container, it never
governs the run, and no host tool reads it as configuration.

## The egress proxy

A container `sdd-run start` and `resume` start (`sdd-step egress-proxy`) on a
network created for the run (`container network create sdd-<run_id>`), which
the run's other containers join and nothing else does; networks are isolated
from one another (research R5). It runs the worker image's Python with
`sdd-egress-proxy.py`, its credentials written to its stdin at start.
`sdd-run` runs `specify` as its child rather than replacing itself with it,
and stops the proxy whenever that child exits — the run paused, completed or
failed — and on its own interruption; the proxy also exits by itself when it
hears nothing from `sdd-run` for a minute, and the network is removed with it,
so no credential outlives the run's process. It:

- holds the run's credentials, read from the Keychain at start and written to
  its container's stdin, kept in its own memory only: the Claude token always, the DeepSeek key
  only when the bundle's opt-in says `deepseek`;
- serves each provider's API as a plain-HTTP gateway inside the container's
  network — `ANTHROPIC_BASE_URL` for Claude, the pi provider's `baseUrl` for
  DeepSeek — and forwards each request over TLS to the real host, replacing
  the authorization the agent sent (a placeholder) with the real credential;
  this is the gateway arrangement Claude Code documents for subscription
  traffic (code.claude.com, llm-gateway: a gateway passing such traffic to
  Anthropic forwards the OAuth capability in `anthropic-beta`);
- tunnels `CONNECT` to the package registries for implement and verify
  passes, and refuses every other destination, logging each refusal;
- admits each pass only to the hosts its pass type allows (Steps, 3), keyed
  by the pass's own token on the proxy, so a judgment pass cannot reach the
  registries and a Claude pass cannot reach DeepSeek.

Each agent container's firewall allows the proxy's address and port and
nothing else, DNS included: names are resolved by the proxy. No agent, container or check
command ever holds a credential (FR-009). **Pending**: that Claude Code's
`-p` runs on the subscription through such a gateway with a placeholder token,
and that pi does through its `baseUrl` (T003, T006); if Claude Code cannot,
the work stops for the owner.

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
3. **Container**: the worker image (built by `prepare-worker`, the
   workflow's first step), the export mounted alone at `/work`, the inputs
   above, a cache volume of the pass's own kind — `sdd-cache-implement-<run_id>`
   for implement passes, `sdd-cache-verify-<run_id>` for verify, never shared
   between the two, so nothing an implementer leaves in a cache is run by
   verify — and `NET_ADMIN`/`NET_RAW` only for the firewall script, which runs
   first and allows the egress proxy's address and nothing else. The proxy
   admits, per pass: its own provider's API for a judgment or review row;
   that API plus the registries for an implement row; the registries alone
   for verify. Then the agent, or the check command, runs as the non-root user
   `node`, with a placeholder where a credential would be; Claude with
   `--setting-sources project`, which loads the export's skills and CLAUDE.md
   (research R24); the export's tracked `.claude/settings.json` applies inside
   the container, bounded by it and by the writes list. For the specify row no feature
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
     `.sdd` and everything under them, `CLAUDE.md`,
     `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, at any depth — whose members
     govern the run or instruct a later agent;
   - every entry is a regular file whose mode is 644 or 755: a symlink, a
     submodule or any other mode change stops the pass;
   - for the implement rows, each path goes to the bundle's copy of
     `config-guard.sh`, run by absolute interpreter path, and an `ask` stops
     the pass (FR-008); the frozen check command's own script, when the
     command names one, and every path config-guard covers, are recorded as
     check changes (FR-029); git hooks (the repository's `core.hooksPath` and
     `.husky/`), CI workflows (`.github/`), editor tasks and every file whose
     mode becomes 755 are recorded as automation changes (FR-030);
   - the patch, the result's text and `structured_output` are scanned for the
     exact value of every credential of the run — a second line behind the
     proxy, since no agent holds one — read from the Keychain into the scanner
     through a pipe and never written; a match stops the pass, naming the
     credential, not showing it (FR-009).
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
verify cache volume, the container admitted by the proxy to the registries only, the check command run
as `node`, no patch, no apply; its exit status, the tail of its output, and
the check changes the implement passes recorded since the last verify go to
`.sdd/verify.json` (FR-020, FR-028, FR-029).

## Never

- A credential in a command-line argument, the environment of any host
  process, any file on the host, an image layer, a container's stored
  configuration, the container runtime's logs, the run's state or logs, an
  agent's session files, or anything an agent returns (FR-009).
- A mount but the export, the inputs of step 2 (read-only) and, for implement
  rows and verify, that pass kind's own cache volume.
- A route out of a container but through the egress proxy.
- A host tool run with its working directory, `PATH` or configuration taken
  from a worktree or an export.
