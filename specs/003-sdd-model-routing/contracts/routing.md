# Contract: the routing table and `sdd-step agent`

## The run bundle

`sdd-run start` resolves the run directory once,
`SDD_RUN_DIR=$(git rev-parse --git-common-dir)/sdd/<run_id>` — git's own
directory, shared by every worktree of the repository and never committed —
exports it to every step, and writes into it before any step runs:

| File | What |
|---|---|
| `lock.json` | run id, `sdd-run`'s process id, its start time as `ps -o lstart=` prints it (FR-022), and `base`, the commit the run started from (the review's diff) |
| `optin.json` | the repository's opt-in as read at start (`sdd.implement`) |
| `check.json` | the repository's check command as read at start (`sdd.check`) |
| `routing.json` | the merged effective table, each value with its layer |
| `profiles/*.json` | copies of the profiles |
| `brief.md` | a copy of the implementing agent's brief (FR-017), `claude/speckit/brief.md`: run governance, not part of the worker image |
| `hooks/` | a copy of `config-guard.sh`, run by the judge (contracts/pass.md) |
| `tools.json` | the absolute paths of `container`, `check-jsonschema` and `security`, resolved once at start |
| `worker.json` | the worker image's tag, written by `prepare-worker` |
| `proxy.json` | the egress proxy's address and port, written by `egress-proxy` while it runs |
| `proxy-ca.pem` | the certificate authority the egress proxy made at its start, written by `egress-proxy` while it runs; every pass mounts it at `/bundle/proxy-ca.pem` |
| `admissions/` | one `<token>.json` per running pass, and the `heartbeat` file `sdd-run` touches |
| `finished.json` | written by `sdd-run` when the run completes or is aborted; until then the run holds its worker image |
| `usage.jsonl` | appended by every agent attempt |

`sdd-run start` also links the bundle as `~/.local/state/sdd/runs/<run_id>`,
so `prepare-worker` in any repository knows which worker images a run
elsewhere still needs.

Every step reads its routing, profile, hooks and opt-in only from the bundle,
never from the repository or dotfiles, and `resume` reuses the bundle as it
is: what governs a run is fixed from its first step to its last. An opt-out
recorded after start is honoured as a downgrade — implementation runs on
Sonnet — and nothing can upgrade a run to the external provider mid-run
(FR-010). No profile can write the bundle (below).

## Layers (FR-027)

| Precedence | File or source | Versioned | Holds |
|---|---|---|---|
| 1, lowest | `~/dotfiles/claude/speckit/routing.yml` | in dotfiles | every phase's full row: the defaults |
| 2 | `<repo>/.claude/sdd-routing.yml` | in the routed repository | only the fields that repository changes |
| 3 | `<repo>/.claude/sdd-routing.local.yml` | no — `sdd-run routing --init-local` creates it and adds it to `$(git rev-parse --git-common-dir)/info/exclude` | only the owner's local changes |
| 4, highest | `sdd-run start --set <phase>.<field>=<value>` (repeatable) | no | one run's changes |

Overridable fields: a layer may set only `model` — within the row's agent's
family, a Claude id for `claude` rows and a DeepSeek id for `pi` rows —
`effort`, and `timeout`, up or down within the row's `max_timeout`. `agent`,
`profile`, `prompt`, `schema`, `result_to`, `writes` and `max_timeout` belong
to the defaults alone, and
`routing-layer.schema.json` refuses them in a layer: a layer cannot send code
to another provider, widen a step's permissions, or drop a rule from a prompt.

Merge: per phase, per field; a higher layer replaces a field, never a whole
row, and adds no phase the defaults do not have. `--set` values are typed by
the schema (`timeout=900` is an integer). Validation: each layer
against `claude/speckit/schemas/routing-layer.schema.json`, the merged table
against `routing-table.schema.json`; any failure stops `sdd-run` naming the
layer, phase and field. The merged table is frozen in the run bundle (above);
a copy goes to `.sdd/routing.json` once the feature directory exists, as a
record. `sdd-run routing [--set …]` prints that table from
the repository root without starting a run. A row with `agent: pi` applies
only when `sdd.implement` opts the repository in; otherwise the run uses
`implement-sonnet` and says so, whatever the layers say.

## The defaults, `claude/speckit/routing.yml`

Validated by `./check.sh` against `routing-table.schema.json` (FR-001,
research R2). A row's fields:

| Field | Values | Meaning |
|---|---|---|
| `agent` | `claude` or `pi` | the harness, run inside the worker container (contracts/pass.md) |
| `model` | a full model id (`claude-opus-5-5`, `claude-sonnet-5-5`, `deepseek-flash`) | never an alias (spec, Assumptions) |
| `effort` | `low`, `medium`, `high`, `xhigh`, `max` | `--effort` for Claude, `--thinking` for pi (FR-021) |
| `profile` | a file name in `claude/speckit/profiles/` | the permissions the agent runs with inside the container (defence in depth) |
| `prompt` | `/speckit-<command>` plus fixed arguments, or, where Spec Kit has no command (review), the whole instruction | what the agent is asked; the feature's paths and, for `specify`, the run's `spec` input are appended by the dispatcher, and for the implement rows the brief (`claude/speckit/brief.md`) |
| `writes` | path patterns relative to the repository root; defaults only | the only paths the step's patch may create, change or delete (contracts/pass.md); empty for a step that writes nothing |
| `schema` | a file name in `claude/speckit/schemas/`, or absent | passed as `--json-schema`; the result's `structured_output` is written to the step's outcome file (research R10) |
| `result_to` | a path relative to the feature directory, or absent | where the result's text is written (`analyze` → `analysis.md`) |
| `timeout` | seconds, 1 to `max_timeout` | the dispatcher's limit for the whole pass |
| `max_timeout` | seconds; defaults only | the phase's ceiling; the workflow step's `timeout:` is this plus 300, so the dispatcher's limit always fires first (research R11) |

Timeouts: `timeout` 3600 and `max_timeout` 7200 for every judgment row and for
review and converge; `timeout` 1800 and `max_timeout` 3600 for `tasks` and for
both implement rows. Each workflow step's `timeout:` in `sdd-routed.yml` is its
row's `max_timeout` plus 300, and `./check.sh` asserts the two files agree. A
layer may set `timeout` anywhere from 1 to `max_timeout`; a value beyond it is
refused by `sdd-run`, naming the ceiling (FR-018, research R11). The implement
rows carry no schema: `sdd-step implement` alone writes `implement.json`.

The rows on 2026-10-21 (`<f>` is the feature directory; `specify` may create
exactly one new directory under `specs/`):

| Phase | agent | model | effort | profile | writes | schema |
|---|---|---|---|---|---|---|
| `specify` | claude | claude-opus-5-5 | medium | author | `specs/<new>/spec.md`, `specs/<new>/checklists/requirements.md`, `.specify/feature.json` | — |
| `clarify-ask` | claude | claude-opus-5-5 | medium | author | `<f>/clarify-questions.md` | clarify |
| `clarify-apply` | claude | claude-opus-5-5 | medium | author | `<f>/spec.md`, `<f>/clarify-questions.md` | — |
| `plan` | claude | claude-opus-5-5 | medium | author | `<f>/plan.md`, `<f>/research.md`, `<f>/data-model.md`, `<f>/quickstart.md`, `<f>/contracts/**` | — |
| `checklist` | claude | claude-opus-5-5 | medium | author | `<f>/checklists/**` | — |
| `analyze` | claude | claude-opus-5-5 | medium | reader | — | — |
| `tasks` | claude | claude-sonnet-5-5 | medium | author | `<f>/tasks.md` | — |
| `implement-deepseek` (prompt `/speckit.implement`, pi's spelling of Spec Kit's command) | pi | deepseek-flash | high | — | everything but the protected set (contracts/pass.md) | — |
| `implement-sonnet` | claude | claude-sonnet-5-5 | medium | implementer | everything but the protected set | — |
| `review` | claude | claude-opus-5-5 | medium | reader | — (reads `/input/diff.patch`) | review |
| `converge` | claude | claude-opus-5-5 | medium | author | `<f>/tasks.md` | converge |

`.specify/feature.json` is accepted only as the JSON Spec Kit writes, naming
the new feature directory; anything else in it fails the pass.

## `sdd-step agent <phase>`

Runs the phase's row through the contained pass (contracts/pass.md). Inside
the worker container a Claude row runs:

```
claude -p "<row.prompt> <feature paths>" \
  --model <row.model> --effort <row.effort> \
  --permission-mode dontAsk --permission-prompts none \
  --setting-sources project --settings /bundle/profile.json \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --output-format json [--json-schema <schema>]
```

as the non-root user, with `ANTHROPIC_BASE_URL` pointing at the egress proxy
and `CLAUDE_CODE_OAUTH_TOKEN` set to a placeholder the proxy replaces with the
owner's token (`claude setup-token`, Keychain item `claude-oauth`), which
never enters the container (contracts/pass.md); the container's home holds no settings, no MCP
server and no CLAUDE.md of the owner's, so a step loads only the export's
tracked files — its skills and CLAUDE.md, through `--setting-sources project`
(research R24) — and its profile (FR-026). A pi row runs `pi -p --mode json
--no-session --model deepseek/<row.model> --thinking <row.effort>`, its provider's `baseUrl` the
proxy and its key a placeholder, the same way. Then, on the host:

- a result with `is_error` true, a `permission_denials` entry, or no result
  fails the step, naming the cause (spec, Edge Cases);
- the patch is judged against the row's `writes` (contracts/pass.md) and
  applied;
- `structured_output` goes to `.sdd/<phase>.json` when the row has a schema;
- the result's text goes to `row.result_to` when the row names one;
- a start line before the pass and an end line after it — run id, phase,
  model, effort given, reported usage and effort — are appended to
  `$SDD_RUN_DIR/usage.jsonl`, the one source `sdd-run usage <run_id>` reads; a
  start with no end is an attempt that reported nothing (FR-021, SC-001).

## Profiles

Inside the container the boundary is the container and the write allow list;
profiles add least privilege on top. Every profile is `dontAsk`.

| Profile | Allows |
|---|---|
| `author` | Read, Glob, Grep; Edit and Write; `Bash` for the named Spec Kit scripts (`check-prerequisites.sh`, `setup-plan.sh`, `setup-tasks.sh`, `create-new-feature.sh`) and read-only git |
| `reader` | Read, Glob, Grep; read-only git |
| `implementer` | Read, Glob, Grep; Edit and Write; `Bash(<the check command frozen in the bundle>)` and read-only git |

"Read-only git" is exactly `Bash(git status:*)`, `Bash(git diff:*)`,
`Bash(git log:*)`, `Bash(git show:*)`, `Bash(git rev-parse:*)` and
`Bash(git branch --show-current)`. The export has no `.git` (contracts/pass.md),
so these see an empty history; they are allowed so a skill that calls them
does not fail. Profiles differ in permission rules only, never in the tools
offered, so the tool definitions — part of the cached prefix — stay the same
across a same-model group (research R16). A patch touching the check
command's own files is allowed but flagged (FR-029): the review counts it as a
finding and the owner's last checkpoint shows it.
