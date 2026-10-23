# Routed Spec Kit runs

`sdd-run` takes a feature from a description to marked tasks through Spec Kit's
own phases, each on the model, effort and permissions a routing table gives it,
each agent contained, and the owner answering at three checkpoints. The design
and its evidence are in `specs/003-sdd-model-routing/` (research R1–R27); this
page is how to use it. Every claim below was observed on 2026-10-21 unless it
says otherwise.

## What runs where

| Phase | Agent | Why |
|---|---|---|
| specify, clarify, plan, checklist, checklist review, analyze, review, converge | Claude Opus | judgment |
| tasks | Claude Sonnet | mechanical decomposition |
| implement | Claude Sonnet, or DeepSeek through pi when the repository opts in | the bulk of the tokens |
| verify | no model | the repository's own check command |

`sdd-run routing` prints the effective table, each value with the layer it came
from. Every agent runs inside the worker container (Apple `container`), whose
only route out is the run's egress proxy: the proxy holds the credentials,
forwards only the endpoints the agents call, and lets passes read — never write
to — the package registries. Nothing an agent writes reaches the repository
until the judge has checked it against the phase's allowed paths, the
protected set (`.git*`, `.claude/`, `.pi/`, `.specify/`, `.sdd/`, `CLAUDE.md`,
`AGENTS.md`, `.mcp.json`…) and the credentials' exact values; then it is one
commit, named after the phase and the model.

## Once per machine

`./install.sh` installs the container runtime and its kernel, `check-jsonschema`
and Spec Kit, and links `sdd-run` and `sdd-step` into `~/.local/bin`. The two
credentials live in the Keychain and nowhere else; create them in a terminal of
their own (each command prompts for the secret, so it never lands in history):

```sh
claude setup-token        # prints the long-lived subscription token
security add-generic-password -U -a "$USER" -s claude-oauth -w
security add-generic-password -U -a "$USER" -s deepseek-api -w   # only for DeepSeek
```

## Once per repository

`sdd-init`, run from the root of a new repository, installs Spec Kit with both
presets, Spec Kit's pi integration (`.pi/`) and the routed workflow, in one
commit. In a repository that already has `.specify/` it changes nothing and
prints the commands that add or update each of them (checked against a stand-in
`specify`; the real `specify workflow add` and `integration install pi` were
run in a scratch repository on 2026-10-22: both succeeded, and a second
`workflow add` over the installed workflow succeeded too).

```sh
sdd-init
git config --local sdd.check './check.sh'      # what verify runs, in the worker
```

Nothing is opted in to DeepSeek by that. To implement on DeepSeek instead of
Sonnet, which `sdd-init` prints at its end — DeepSeek's terms of service and
privacy policy then apply to the code it reads:

```sh
git config --local sdd.implement deepseek
```

`sdd-run` refuses a DeepSeek opt-in whose pi integration is not committed: pi
runs Spec Kit's `/speckit.implement` from it, as Claude runs its skill.

## A run

```sh
sdd-run start "a description of the feature"
```

It stops at each checkpoint and prints the command that answers it:

- `answer_clarify`, only when clarify has questions: each question in
  `specs/<feature>/clarify-questions.md` carries a recommendation; write
  `**Answer:** <option>` under each, then `sdd-run resume <id> approve`.
- `review_spec`: read `spec.md`; `approve` or `reject` (reject ends the run,
  recorded as rejected).
- `review_plan`, after tasks and analyze: read `plan.md`, `tasks.md`,
  `analysis.md` and the checklist items the fresh checklist review left
  unchecked. Approving is your answer to implement's question whether to go on
  with unchecked items.
- `review_done`: read `.sdd/review.json`, and the check and automation
  changes `.sdd/verify.json` lists; approving marks the tasks review found
  done.

Other stops say what answers them:

- `fix_stuck` or `converge_stuck`, after three rounds without a passing check
  or a converged review: `sdd-run resume <id> retry` buys exactly one more
  round; `sdd-run abort <id>` ends the run.
- A failed step prints the step's own message; once the cause is fixed,
  `sdd-run resume <id>` runs it again.
- A run whose process died cannot be resumed (Spec Kit refuses a run it still
  reads as running): `sdd-run start --from specs/<feature>` starts a new run
  on that feature, skipping the phases already finished; one that died before
  any phase finished is started anew from its description, and the feature
  directory its specify may have made is named, left behind to remove.

One run at a time in a worktree: `start` refuses while another run there is
paused, stopped or running — still starting included — and names the commands
that end it. A run is answered from the worktree it started in, and works on
the feature its own specify made or `--from` named, never on one a pointer
left by an earlier run names (`.specify/feature.json` is the worktree's).

The run's own files are in its bundle, `$(git rev-parse --git-common-dir)/sdd/<id>/`:
the frozen routing table, profiles and brief, the code the run executes
(`code/`: a change to dotfiles mid-run does not reach it), `usage.jsonl`, and
`results/`,
every agent's final answer — the first place to look when a pass did something
unexpected. A credential's value an agent put in its answer shows there, as in
every message and usage line, as `<the credential claude-oauth>` (or
`deepseek-api`): no log or file keeps one (observed 2026-10-22 against
stand-ins, check 91).

## Cost

```sh
sdd-run usage <id>
```

prints every attempt per model at list price, failed and resumed ones
included, and names attempts that reported nothing. The first complete real
run — a small Python function with five tests, Opus for judgment, Sonnet for
tasks and implementation — reported $0.54 for its last run of the build.

## Changing the routing

A layer may change only a phase's `model` (within its agent's family),
`effort` and `timeout` (up to the phase's ceiling): it cannot send code to
another provider, widen permissions or drop a rule.

| Layer | Where | Versioned |
|---|---|---|
| defaults | `claude/speckit/routing.yml` in dotfiles | yes |
| repository | `.claude/sdd-routing.yml` | yes |
| local | `.claude/sdd-routing.local.yml` (`sdd-run routing --init-local` creates it, git-excluded) | no |
| one run | `sdd-run start --set plan.effort=high` | no |

## Containment and credential probes (T047)

Run on 2026-10-22 on this machine (macOS 27.0.1, Apple `container` 1.6.0),
quickstart 11 and FR-009, through the repository's own code at 052c94b: a
scratch repository and a bundle in `checks/sdd/bundle.py`'s layout whose
`tools.json` named the real `container` and, for the Keychain, check 91's
stand-in `security` answering with **sentinel** credentials (one per item,
sharing a marker string). `sdd-step prepare-worker` built and checked
`sdd-worker:52f0ca0e7920`; `sdd-step egress-proxy` started the proxy with
the sentinels on its stdin (opted in to DeepSeek, so it held both). That
setup ran twice: round 1 for attempts 1–4, and round 2 for attempts 5–6,
with a fresh proxy and the image rebuilt the same way. The real credentials
were never read. The providers saw only sentinels, and every call got 401:
- DeepSeek's `/models`, once at each proxy start;
- Anthropic's `/v1/messages`, twice each in attempts 4 and 5;
- DeepSeek's `/chat/completions`, once in attempt 6.

**Containment.** The probe, a script run as `node`, tried every route below
and printed one line per attempt.

| Attempt | How | Result |
|---|---|---|
| 1, 19:38Z | `sdd-step verify` with the probe as the check command (the registries alone admitted) | Every attempt failed but the registry reads, which verify may make. Three probes were faulty, so it proves nothing for them: `iptables` not on node's `PATH`, a `HEAD` sent with `-X` timed out, and the absolute-URL request bypassed the proxy |
| 2, 19:40Z | the same, probe fixed | As 1, and now `iptables` and `ip6tables` were refused as node ("Permission denied (you must be root)"). The search of the filesystem for a sentinel was killed (`grep -a` exited 137, out of memory), so that one probe is void |
| 3, 19:41Z | the same, the filesystem searched by a chunked reader that first found a marker planted in `/tmp` | All 59 attempts failed except the two registry reads verify may make, a `GET` and a `HEAD`: 39 were blocked inside the container and 18 refused by the proxy (403/407) |
| 4, 19:41Z | `sdd-step agent plan`, on a probe image (`FROM` the worker, `claude` replaced by the probe; Anthropic's API alone admitted) | All 59 attempts failed except the two `POST /v1/messages` this pass may make: 39 were blocked inside the container and 18 refused by the proxy. Those two went through the proxy, which swapped the placeholder for the sentinel, and Anthropic answered 401 "OAuth access token is invalid". The probe's writes to `CLAUDE.md` and outside `plan`'s writes were refused by the judge: nothing applied, and no commit |
| 5, 19:50Z | `sdd-step implement`, the feature's `.sdd/route.json` saying `sonnet`. The probe image now replaces both `claude` and `pi`; Anthropic's API and the registries are admitted, with the volume `sdd-cache-implement-t047probe` at `/cache` | All 60 attempts failed except the four this pass may make. The two `POST /v1/messages` got 401 from Anthropic, as in 4, and the registry `GET` and `HEAD` went through. 39 were blocked in the container and 17 refused by the proxy, among them `/chat/completions` and a `CONNECT` to api.deepseek.com. `/cache` was writable, as this pass kind's own cache. The judge refused `CLAUDE.md`: nothing applied |
| 6, 19:51Z | `sdd-step implement` with `route.json` saying `deepseek`, `git config sdd.implement deepseek`, and the bundle opted in at start, so the `implement-deepseek` row ran `pi` (the probe). DeepSeek's API and the registries are admitted | All 60 attempts failed except the three this pass may make. `POST /chat/completions` went through the proxy and DeepSeek answered 401 "Your api key: \*\*\*\*d5be is invalid". Those four characters are the DeepSeek sentinel's last four, so the proxy put the sentinel in place of the placeholder. The registry `GET` and `HEAD` went through. 39 were blocked in the container and 18 refused by the proxy, among them every Anthropic endpoint (403) and a `CONNECT` to api.anthropic.com. pi's `models.json` held the proxy as its `baseUrl` and the placeholder as its key. The judge refused `CLAUDE.md`: nothing applied |

Seen blocked in 3–6, each named in the pass's own answer (attempt 3 in
`.sdd/verify.json`'s tail, attempts 4–6 in `results/`):

- Reading the host: there is no `/Users` or `/Volumes`, so no `~/.ssh`, no
  Keychain directory and no other repository. There is no `security`
  command, and no `*.keychain*` file on any mounted filesystem. The mounts
  were `/work` and the read-only `/bundle`, plus `/cache` for verify and
  implement.
- Writing the host: `/Users/...` (permission denied), `/bundle` (read-only),
  `/etc` and `/usr/local/lib/sdd` (permission denied). Writes to the
  container's own `/home/node` and to `/work` (the export) succeeded, as
  designed: the first is discarded with the container, and the second
  reaches the worktree only as a judged patch.
- Credentials: none in the environment (an allow list of names, the
  placeholder the only token), none in `/proc/*/environ` or `cmdline`, and
  none in any file on the container's filesystem (22,635 files, 1.19 GB; 557
  were unreadable to node).
- Privilege: `CapPrm`, `CapEff` and `CapBnd` all zero, `NoNewPrivs` 1. Every
  `iptables`/`ip6tables` change was refused, there is no `sudo`, and `su`
  failed.
- Direct network: 1.1.1.1 and 8.8.8.8, the network gateway, the host
  (192.168.64.1), and the proxy on ports 22 and 80 were all refused at once.
  No name resolved (`getent`), and DNS over UDP and TCP to 1.1.1.1, 8.8.8.8
  and the gateway was refused.
- Through the proxy, beyond the pass's admission:
  - Verify: the Anthropic and DeepSeek API endpoints got 403.
  - Judgment pass: `GET /v1/models`, `POST /v1/messages/batches`,
    `POST /v1/files` and `/chat/completions` got 403, and every `CONNECT`
    got 403.
  - Claude implement pass: DeepSeek's `/chat/completions` and Anthropic's
    other endpoints got 403.
  - pi implement pass: every Anthropic endpoint got 403.
  - Every pass: a forged or missing token got 407, an absolute-URL request
    403, and `CONNECT` to example.com, upload.pypi.org or api.anthropic.com
    403; from attempt 5 on, `CONNECT` to api.deepseek.com 403 too.
  - Inside an admitted registry tunnel: `PUT`, `POST`, a git-receive-pack
    `POST` and a non-download github.com path got 403.

On the host, a snapshot before and after each pass (`ls -la ~` and `~/.ssh`,
a second scratch repository's `HEAD` and status, the feature repository's
log and status) changed in two ways only. The feature repository gained the
run's own `sdd: … before <phase>` commits. `~/.claude.json` changed too:
that is the host's own Claude Code session writing its configuration, and
it did not change during attempts 4–6. No `t047-probe` file appeared in `~`
or `~/dotfiles`.

A finding, fixed after the probes: DeepSeek's 401 body quotes the last four
characters of the key it was sent. With the real key, those four characters
would have reached the agent through the proxy's relayed answer, and the
judge and the withholding of what a pass keeps look for the exact value of
the key, not for a fragment of it. The proxy now answers a provider's 401 or
403 with the status and a body of its own, none of the provider's body or
headers, and logs the refusal without its body (research R31). The review of
the story found that block-list too narrow: a provider can quote the key in
any non-2xx answer or header, so the proxy relays only a 2xx and answers every
other status in its own words, keeping a numeric `Retry-After` (research R33;
check 93 "a provider answering anything but 2xx…", against a stand-in
provider, not re-run against DeepSeek). What is lost: the provider's own error
text, kept out on purpose; the owner reads the status and the proxy's log.

**Leak search.** Every search looked for the two sentinel values and their
marker, printed only counts, and was first seen to find a marker planted on
purpose. The planted markers were in a 50 GB sparse file, in a gzip layer,
and in a throwaway container given the marker in its environment and its
output (`container inspect`, its `config.json`, `runtime-configuration.json`,
`stdio.log` and `container logs` each found it), plus a host process given
the marker as an argument (`ps -axww` found it). Every planted marker was
found again in round 2. In each round the search ran three times: with the
proxy holding the sentinels, after that round's passes, and after the proxy
stopped. It found nothing every time:

- Image layers: `container image save` of the worker and of each probe
  image, every blob decompressed and read (about 924 MB per image), and
  every blob in the runtime's content store (78 in round 1, 70 in round 2,
  1.65 GB decompressed).
- The containers' stored configuration: `container inspect` of the proxy and
  of each pass container while it ran. The pass's environment is stored
  there and held only the placeholder. Also every file of the runtime's
  on-disk state under `~/Library/Application Support/com.apple.container/`
  (`containers/` with each container's `config.json`,
  `runtime-configuration.json`, `stdio.log`, `vminitd.log` and its sparse
  `rootfs.ext4`; `snapshots/`, `volumes/`, `networks/`, `apiserver/`,
  `plugin-state/`, `state.json`). That is 12.4 GB of data extents in
  `containers/` and 7.1 GB in `snapshots/`. The
  proxy got its credentials on stdin, and its `stdio.log` did not hold them.
- The runtime's logs: `container logs` and `container logs --boot` of each
  container, and `container system logs --last 2h` (65 to 146 lines per
  search).
- The pass containers of attempts 1–6 were searched while each ran:
  `container inspect` and every file of its on-disk directory. The implement
  cache volume was searched with the rest of `volumes/`.
- The host: `ps -axww`, every process's arguments, and every file of the
  scratch run (bundle, `results/`, `usage.jsonl`, the repository and the
  proxy's log). The host processes' environments were **not tested**: on
  this macOS, `ps -E` does not show a process's environment. A variable set
  on a `sleep` did not appear in its `ps -Eww` line (2026-10-22), so the
  `ps -axeww` search in the script proves nothing. Check 91 covers the
  environments through the stand-ins (T044).

One limit: `container system logs` never showed the planted marker, even
while a container's environment held it. That search was never seen red. It
shows the log does not record a container's environment or arguments; it
does not show the search would catch a credential there.

## Story-workers inside a pass (T050b)

story-workers' fragment tells the implementing session to start a worker per
phase with the Agent tool, and to fall back to core's own behaviour with no
Agent tool, a worker error, or a project that is not a git repository. An
interactive session follows that; a routed pass follows `routing.yml`. They do
not meet inside a pass, by two guarantees of different strength:

- **By construction (status: built, T048b; probed 2026-10-23, research R35).**
  Every pass profile denies `Agent` and `Task`, so the subagent tool is not
  offered to the model even when the repository's own settings allow it, and
  story-workers' fragment cannot launch a worker in a pass.
- **Observed here (2026-10-22, below).** In one Sonnet implement pass and one
  Opus implement pass, with story-workers installed by `sdd-init`, the fragment
  fell back to core and the pass was the only worker.

**What was run**, on 2026-10-22, Apple `container` 1.6.0 running, real
`claude-oauth` credential, DeepSeek not used (the repository was not opted in):

```sh
git init -b main rt && cd rt            # seed commit with check.sh (python3 -m unittest) and tests/
sdd-init                                # this branch's bin/sdd-init.sh: both presets, pi, sdd-routed; one commit
# a three-line constitution, committed; git config --local sdd.check ./check.sh
sdd-run start "A slugify module with two functions: slugify(text) ... unique_slug(text, taken) ..."
sdd-run resume bd7f158e2612 approve     # after answering the one clarify question "A"; again at review_spec, review_plan
```

then, on the same feature reset to the commit before implement, a second run
that puts the implement pass on the strongest model (the shape of SC-001's
baseline arm):

```sh
sdd-run start --from specs/001-slugify-module --set implement-sonnet.model=claude-opus-5-5
sdd-run resume 83261390f272 approve
```

**Observed.**

- (a) Both implement passes (`results/implement-sonnet-*.md`, runs `bd7f158e2612`
  on `claude-sonnet-5-5` and `83261390f272` on `claude-opus-5-5`) went to core.
  The Sonnet answer: "The project isn't a git repository, so I didn't use
  workers and did every task myself ... Carried out in this session:
  T001-T015." The Opus answer: "The workspace isn't a git repository (`git`
  isn't installed), so the Fallback rule applied: no phases went to separate
  workers ... Carried out in this session: T001-T015." Both pass runs wrote
  the code and tests themselves, and `./check.sh` passed (6 and 12 tests). Neither
  answer names the missing Agent tool as the reason: the pass has two reasons
  to fall back (no `.git`, no Agent tool) and these answers cannot separate
  them. That the pass is the only worker holds for both.
- (b) No pass failed with a permission denial (a denied tool fails the pass
  naming it), and each implement pass's `modelUsage` lists only its own model
  (`claude-sonnet-5-5`; `claude-opus-5-5`), so no worker on another model ran.
  Not observed: whether the model tried the Agent tool. The result line has
  no list of tool calls, and under `deny` the tool is not offered.
- (c) The baseline arm as a contained pass, run once on Opus with story-workers
  installed: no workers launched (answer and `modelUsage` above). So the answer
  to SC-001's open question is no, on one sample, for a reason that holds in
  every pass, with or without the `.git`: the profile denies the tool. T052
  needs no third arm.

**Found, then fixed** (outside T050b; research R36): in both runs the `review`
pass failed after the implement pass applied cleanly: "judge refused the patch:
`__pycache__/slugify.cpython-311.pyc`: outside this step's writes". The
read-only review agent ran the tests with its shell, and the task list told it
to run `python3 -I`, which ignores `PYTHONDONTWRITEBYTECODE`. Now a row that may
write nothing (analyze, review) has `/work` mounted read-only, so no tool can
leave a cache; a test that needs a scratch file must use `/tmp`. Observed
2026-10-23: in the worker image with a read-only mount, `python3 -I` imports a
module and writes nothing, `mkdir .pytest_cache` and `touch x` fail with
"Read-only file system"; and `sdd-step agent review` on the failed run's bundle
(`83261390f272`, same repository) now passes (60 s, $0.25). Whether that
agent ran Python in that pass is not known. Check 91 covers the rest.

## Why some things are the way they are

- **Agents use the shell inside the container.** Allowing commands one by one
  broke Spec Kit's own agents three times in three phases of the first real
  run; the container, the proxy and the judge are the boundary, as in
  Anthropic's devcontainer (research R27).
- **The brief goes to the system prompt, not a Spec Kit preset.** Its rules hold
  only inside a contained run; a preset would change implement for every
  interactive use too (research R27).
- **The worker image is reproducible in its packages, not its bits.** Apple's
  builder gives one recipe different digests; every input is pinned by hash
  and `prepare-worker` refuses an image whose package inventory differs from
  the committed one (research R26).
- **Registries are read-only.** The proxy inspects their TLS with an authority
  made for the run, name-constrained to the registries, and forwards only
  `GET` and `HEAD` (research R25).
