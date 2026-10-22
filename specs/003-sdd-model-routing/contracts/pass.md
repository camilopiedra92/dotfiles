# Contract: the contained pass

Every agent step — each judgment phase, both implementers — and every verify
runs as one contained pass, the same way (research R21). It enforces the threat
model of research R20 by construction rather than by naming files. Every host step of a pass —
this contract's and every `sdd-step` and `sdd-run` subcommand's — starts in
the run bundle's directory with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and calls
its tools by the absolute paths `sdd-run start` resolved once, from the
bundle's directory with the owner's `PATH`, and froze in `tools.json` —
real binaries, never a version manager's shim, which reads its configuration
from the directory it runs in (T005) — with git, Python and tar at their
fixed system paths, so no file in any worktree or export (a
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
- forwards only the endpoints the agents call — `POST /v1/messages` and
  `/v1/messages/count_tokens` to Anthropic, `POST /chat/completions` to
  DeepSeek — so a pass cannot reach the provider's other endpoints (keys,
  batches, files) with the owner's credential;
- answers `CONNECT` to a package registry, for implement and verify passes,
  with a certificate signed by an authority it makes at its start — in a
  directory of its own, deleted once every registry host's certificate is
  signed and loaded, so the authority's key is in no file — and forwards the
  requests inside to the real registry over verified TLS: `GET` and `HEAD`
  only, with no body, and on a registry with a path rule only the paths it
  matches (`github.com`: release and archive downloads); every other method,
  path or registry is refused with 403 and logged, so no pass can publish,
  push or upload (FR-031, research R25);
- admits each pass only to the hosts its pass type allows (Steps, 3). Each
  pass has its own random placeholder, `sdd-pass-<token>`, which its agent
  sends where a credential would go (`Authorization`/`x-api-key` to an API,
  the proxy user on `CONNECT`); before the pass `sdd-pass.py` writes
  `$SDD_RUN_DIR/admissions/<token>.json`, `{"admit": [...]}` of `anthropic`,
  `deepseek`, `registries`, and deletes it after. The directory is mounted
  read-only into the proxy's container, which looks each request's token up
  there, so a judgment pass cannot reach the registries and a Claude pass
  cannot reach DeepSeek;
- exits by itself when `admissions/heartbeat`, which `sdd-run` touches, has
  not changed for its `heartbeat_seconds` (a change, not a timestamp, since
  the host's and the container's clocks may differ).

Its start configuration is one JSON line on its stdin — `listen`,
`admissions`, `heartbeat_seconds`, `providers` (each `upstream` and
`credential`, DeepSeek's only when the run is opted in), `registries`, and
`paths` (a regular expression per registry entry; `github.com`'s comes from
`sdd-pass.py`, which owns the policy as it owns the list) — and its first
stdout line is `{"api_port", "models", "ca"}`, from which `sdd-step
egress-proxy` writes `proxy.json` (address and port), `proxy-ca.pem` (the
authority's certificate, removed with `proxy.json` when the proxy stops) and
the `/models` name behind each DeepSeek id into `routing.json`.

Each agent container's firewall allows the proxy's address and port and
nothing else, DNS included: names are resolved by the proxy. No agent, container or check
command ever holds a credential (FR-009). The worker's entrypoint refuses a
placeholder of any other shape, a Claude token or pi key that is not the
pass's placeholder, and a base URL that is not the proxy. **Observed**
(2026-10-21): T003 and T006 with a gateway, and the first real pass through
this proxy (research R21).

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
2. **Inputs**: read-only mounts beside the export — `/bundle/proxy-ca.pem`
   (every pass, verify included: the authority the worker trusts for the
   registries; a pass refuses to start without it), `/bundle/profile.json` (the
   row's profile), `/bundle/check.json` (the implementer only) and,
   for the review row, `/input/diff.patch`: the feature's own change, the
   commits the run made for it (`<phase>: <feature> (`, `sdd: <feature> before `,
   `mark: <feature> (`) as a patch series, oldest first, without
   `<f>/.sdd/` — unrelated commits and other features stay out, and an
   earlier run's implementation (`sdd-run start --from`) is in — made on the
   host (Host git), which the export, having no history, cannot show
   (FR-019).
3. **Container**: the worker image (built and checked by `prepare-worker`,
   which `sdd-run start` runs before the workflow), the export mounted alone
   at `/work`, the inputs
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
   the feature, so Spec Kit's scripts need no git. Those rows also run with
   `SPECIFY_FEATURE_NO_PERSIST=1`, Spec Kit's switch for orchestrators
   (issue #4128): its scripts then leave `.specify/feature.json`, the
   worktree's own state, alone; only specify records the feature there.
4. **Limit**: the row's `timeout` bounds the agent's container (step 3); at
   the limit the container is stopped and the pass fails with nothing
   applied. The host steps around it, which run no agent, are bounded by the
   workflow step's own `timeout`, the row's `max_timeout` plus 300 seconds.
5. **Patch**: `git diff --no-index --binary --no-prefix` between the baseline
   and the agent's export (Host git), the working directory in the bundle; its
   paths carry the `baseline/` and `export/` directory names, which
   `git apply -p1` strips (observed 2026-10-21: `-p0` fails). The judge reads
   the changes from `git diff --no-index --raw -z` over the same two trees.
6. **Judge**, failing closed — a judge that cannot run fails the pass:
   - no created, changed or deleted path is in the protected set — `.git`
     and `.git*` files but `.gitkeep`, `.claude`, `.pi`, `.specify`, `.sdd` and
     everything under them, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`,
     `.mcp.json`, at any depth, compared NFKC-casefolded — a superset of
     what APFS treats as the same name (a fuzz over every code point found
     none it misses), so it may over-refuse and never under-refuses — whose members govern the run or instruct a later agent; this
     holds for every row, and a judgment row may name a protected file only
     exactly in its `writes` (specify's `.specify/feature.json`), never
     through a pattern;
   - every path matches the row's `writes` (contracts/routing.md); for the
     implement rows, `writes` is everything;
   - a path the repository ignores (a cache a test run left, a `.venv`) is
     dropped from the patch, named, and never written: what git ignores is
     not the repository's content (research R27); Spec Kit's
     `.specify/feature.json` has its own handling;
   - no path lands, in the owner's worktree, through a symlink on its way or
     on an untracked symlink (`git apply` follows them); a tracked symlink may be replaced or
     deleted, and a tracked file an ignore rule matches changed, as git does.
     The no-index diffs set `core.precomposeUnicode`, so a decomposed name
     reaches the index as the owner's git would write it;
   - every entry is a regular file whose mode is 644 or 755: a symlink, a
     submodule or any other mode change stops the pass;
   - for the implement rows, each path goes to the bundle's copy of
     `config-guard.sh`, run by absolute interpreter path, and an `ask` stops
     the pass (FR-008); the frozen check command's own script, when the
     command names one — every path among the command's words, normalized —
     and every path config-guard covers, are recorded as check changes
     (FR-029); what those scripts call is not followed, and the review reads
     the whole diff; git hooks (the repository's `core.hooksPath` and
     `.husky/`), CI workflows (`.github/`), editor tasks and every file whose
     mode becomes 755 are recorded as automation changes (FR-030);
   - every changed file's bytes, the result's text and `structured_output`
     are scanned for the exact value of every credential of the run, failing
     closed when a credential cannot be read — a second line behind the
     proxy, since no agent holds one — read from the Keychain into the scanner
     through a pipe and never written; a match stops the pass, naming the
     credential, not showing it (FR-009).
   A path or entry the judge refuses is named; nothing is applied.
7. **Apply**: the outcome file — `implement.json` included, its commit
   filled in after — is validated first, and an implement pass's check and
   automation changes kept, so an invalid outcome leaves no commit and no
   later failure loses a flag; then `git apply -p1 --index` of the judged patch on the feature's
   worktree, which no agent ever wrote, and one commit of the patch's paths
   only, `<phase>: <feature> (<model>)` (Host git), so whatever the owner has
   staged stays staged. Every diff runs with `--no-ext-diff --no-textconv`,
   and the no-index ones with `GIT_CEILING_DIRECTORIES` at the pass, since the
   bundle lies inside the repository's `.git`.
8. **Results**: the agent's JSON result is read from the container's stdout:
   `structured_output` to the row's outcome file, the result's text to
   `result_to`, usage to the run's `usage.jsonl`.
9. **Clean up**: both exports and the container removed, whatever happened.
   A pass whose own process was killed cannot clean up; `sdd-run start` and
   `resume` call `sdd-step cleanup` first.

## Verify

The same pass with no agent: the export of `HEAD`, `/bundle/proxy-ca.pem`,
the verify cache volume, the container admitted by the proxy to the registries only, the check command run
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
