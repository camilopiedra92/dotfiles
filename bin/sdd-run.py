"""sdd-run: starts, resumes, aborts and reports routed Spec Kit runs
(specs/003-sdd-model-routing, contracts/sdd-run.md).

Run by bin/sdd-run.sh on the system Python. It checks the prerequisites,
merges the routing layers, writes the run bundle every later step reads its
governance from (contracts/routing.md), starts the run's egress proxy, runs
Spec Kit as its child and stops the proxy when that child exits. Host tools
are found once, on the owner's PATH, and frozen as absolute paths in the
bundle's tools.json; nothing after that finds a tool by name.
"""

import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

DOTFILES = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SPECKIT = os.path.join(DOTFILES, "claude", "speckit")
SPECKIT_MIN = (1, 2, 2)
WORKFLOW_ID = "sdd-routed"
# The phases .sdd/phases.json records, in the order a run finishes them.
PHASES = ["specify", "plan", "tasks", "build"]
# The workflow's two stops for the owner inside its loops (contracts/workflow.md).
# Step ids use "_": the engine reads "-" in an id as a minus.
STUCK_STEPS = ("fix_stuck", "converge_stuck")
HEARTBEAT_SECONDS = 2  # the proxy exits after 60 without one
GIT = "/usr/bin/git"
HOST_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": os.environ.get("HOME", "/var/empty"),
    "LC_ALL": "C",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
}
# The hint each missing host tool gets.
TOOL_HINTS = {
    "specify": "Spec Kit: ./install.sh in ~/dotfiles (uv-tools.txt)",
    "sdd-step": "./install.sh in ~/dotfiles links it into ~/.local/bin",
    "check-jsonschema": "./install.sh in ~/dotfiles (uv-tools.txt)",
    "git": "the Command Line Tools: xcode-select --install",
    "container": "Apple's container runtime: brew bundle in ~/dotfiles, then container system start",
    "security": "macOS's /usr/bin/security",
}


class Stop(Exception):
    """A refusal: one line naming what is missing and how to provide it."""


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, doc):
    """Written whole or not at all: a reader never sees half a file."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(tmp, path)


def host(*cmd, cwd=None, env=None, input=None):
    return subprocess.run(list(cmd), cwd=cwd, env=env or HOST_ENV, input=input,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def git(repo, *args):
    return host(GIT, "-C", repo, *args)


def repo_root():
    here = os.path.realpath(os.getcwd())
    r = git(here, "rev-parse", "--show-toplevel")
    if r.returncode != 0 or os.path.realpath(r.stdout.decode().strip()) != here:
        raise Stop("run sdd-run from the root of a git repository")
    return here


def common_dir(repo):
    return git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.decode().strip()


def local_config(repo, key):
    return git(repo, "config", "--local", "--get", key).stdout.decode().strip() or None


# ── Host tools ───────────────────────────────────────────────────────────────

def shim(path):
    """A version manager's shim reads its configuration from the directory it
    runs in (research T005), so it is never frozen as a tool."""
    real = os.path.realpath(path)
    parts = path.split(os.sep) + real.split(os.sep)
    return "shims" in parts or os.path.basename(real) in ("mise", "asdf", "rtx")


def resolve_tools():
    """Each host tool on the owner's PATH, once, as the real file it is."""
    owner_path = ":".join(p for p in os.environ.get("PATH", "").split(":") if os.path.isabs(p))
    tools = {}
    for name, hint in TOOL_HINTS.items():
        found = shutil.which(name, path=owner_path)
        if not found:
            raise Stop(f"{name} is not on PATH: {hint}")
        if shim(found):
            raise Stop(f"{name} on PATH is a version manager's shim ({found}): put the real {name} first on PATH")
        tools[name] = os.path.realpath(found)
    # The interpreter that parses YAML: check-jsonschema's own, which reads
    # YAML instances with ruamel.yaml — a tool this feature already declares,
    # so the system Python needs no YAML library of its own.
    python = os.path.join(os.path.dirname(tools["check-jsonschema"]), "python")
    if not os.access(python, os.X_OK):
        raise Stop(f"check-jsonschema at {tools['check-jsonschema']} has no interpreter beside it: "
                   f"reinstall it with ./install.sh in ~/dotfiles")
    tools["yaml-python"] = python
    return tools


def load_yaml(tools, path, label):
    script = ("import json, sys\nfrom ruamel.yaml import YAML\n"
              "print(json.dumps(YAML(typ='safe').load(open(sys.argv[1]))))")
    r = host(tools["yaml-python"], "-I", "-c", script, path)
    if r.returncode != 0:
        raise Stop(f"{label} is not valid YAML: " + r.stderr.decode(errors="replace").strip().splitlines()[-1])
    return json.loads(r.stdout)


def validate(tools, schema, doc, label):
    fd, tmp = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f)
        r = host(tools["check-jsonschema"], "--schemafile", os.path.join(SPECKIT, "schemas", schema), tmp)
        if r.returncode != 0:
            errors = [l.strip().replace(tmp + "::", "") for l in r.stdout.decode(errors="replace").splitlines()
                      if "::" in l or l.strip().startswith("$")]
            raise Stop(f"{label} does not match {schema}: " + "; ".join(errors or ["see check-jsonschema"]))
    finally:
        os.remove(tmp)


# ── Prerequisites ────────────────────────────────────────────────────────────

def speckit_version(tools):
    r = host(tools["specify"], "--version")
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", r.stdout.decode())
    return tuple(int(x) for x in m.groups()) if r.returncode == 0 and m else None


def workflow_step(tools, repo, step_id):
    """The installed workflow's step with this id, searched through every
    nested block (loops, ifs), or None."""
    doc = load_yaml(tools, os.path.join(repo, ".specify", "workflows", WORKFLOW_ID, "workflow.yml"), WORKFLOW_ID)

    def walk(node):
        if isinstance(node, dict):
            if node.get("id") == step_id and "type" in node:
                return node
            nodes = node.values()
        elif isinstance(node, list):
            nodes = node
        else:
            return None
        for child in nodes:
            found = walk(child)
            if found:
                return found
        return None

    return walk(doc.get("steps", []))


def prerequisites(tools, repo):
    """contracts/sdd-run.md, "Prerequisites", each a Stop naming it."""
    version = speckit_version(tools)
    if not version or version < SPECKIT_MIN:
        raise Stop("Spec Kit %s is older than %s: move its pin in uv-tools.txt and run ./install.sh"
                   % (".".join(map(str, version)) if version else "of unknown version", ".".join(map(str, SPECKIT_MIN))))
    if not os.path.isdir(os.path.join(repo, ".specify")):
        raise Stop("this repository has no .specify/: set Spec Kit up with sdd-init first")
    source = os.path.join(SPECKIT, f"{WORKFLOW_ID}.yml")
    installed = os.path.join(repo, ".specify", "workflows", WORKFLOW_ID, "workflow.yml")
    add = f"specify workflow add {source}"
    if not os.path.isfile(installed):
        raise Stop(f"the {WORKFLOW_ID} workflow is not installed here: {add}")
    want = (load_yaml(tools, source, source).get("workflow") or {}).get("version")
    have = (load_yaml(tools, installed, installed).get("workflow") or {}).get("version")
    if want != have:
        raise Stop(f"the {WORKFLOW_ID} workflow here is at {have}, dotfiles has {want}: {add}")
    if host(tools["container"], "system", "status").returncode != 0:
        raise Stop("the container runtime does not answer: container system start")
    r = host(tools["security"], "find-generic-password", "-s", "claude-oauth", "-w")
    if r.returncode != 0 or not r.stdout.strip():
        raise Stop("the Keychain item claude-oauth is missing or blank: claude setup-token, then "
                   "security add-generic-password -U -a \"$USER\" -s claude-oauth -w")
    for need in ("routing.yml", "brief.md", "pi-models.json", "egress-registries.txt", "profiles/author.json", "profiles/reader.json", "profiles/implementer.json"):
        if not os.path.isfile(os.path.join(SPECKIT, need)):
            raise Stop(f"dotfiles lacks claude/speckit/{need}: update ~/dotfiles")
    if not local_config(repo, "sdd.check"):
        raise Stop("no check command: git config --local sdd.check '<the command that checks this repository>'")


# ── Routing layers (contracts/routing.md, FR-027) ────────────────────────────

def parse_sets(pairs):
    layer = {}
    for pair in pairs:
        m = re.fullmatch(r"([a-z-]+)\.([a-z_]+)=(.*)", pair)
        if not m:
            raise Stop(f"--set {pair}: expected <phase>.<field>=<value>")
        phase, field, value = m.groups()
        if field == "timeout":
            if not re.fullmatch(r"\d+", value):
                raise Stop(f"--set {pair}: {phase}.timeout must be a whole number of seconds")
            value = int(value)
        layer.setdefault(phase, {})[field] = value
    return {"phases": layer}


def check_layer(defaults, layer, label):
    """What routing-layer.schema.json cannot say, checked after it: a model
    stays within its row's agent's family, so a layer cannot send a phase to
    another provider. The schema alone decides which phases and fields a
    layer may name (only model, effort, timeout) and their types."""
    phases = (layer or {}).get("phases") or {}
    for phase, fields in phases.items():
        if "model" in fields:
            family = "claude-" if defaults[phase]["agent"] == "claude" else "deepseek-"
            if not fields["model"].startswith(family):
                raise Stop(f"{label}: {phase}.model {fields['model']!r} is not a {family[:-1]} model, as its "
                           f"row's agent {defaults[phase]['agent']} needs")
    return phases


def effective_table(tools, repo, sets):
    """Every phase's every field with the layer it came from: defaults,
    repository, local, set — each higher one replacing a field, never a row."""
    defaults_doc = load_yaml(tools, os.path.join(SPECKIT, "routing.yml"), "claude/speckit/routing.yml")
    validate(tools, "routing-table.schema.json", defaults_doc, "claude/speckit/routing.yml")
    defaults = defaults_doc["phases"]
    table = {p: {k: {"value": v, "layer": "defaults"} for k, v in row.items()} for p, row in defaults.items()}
    layers = []
    for name, rel in (("repository", ".claude/sdd-routing.yml"), ("local", ".claude/sdd-routing.local.yml")):
        path = os.path.join(repo, rel)
        if os.path.isfile(path):
            layers.append((name, rel, load_yaml(tools, path, rel)))
    if sets:
        layers.append(("set", "--set", parse_sets(sets)))
    for name, label, doc in layers:
        try:
            validate(tools, "routing-layer.schema.json", doc or {"phases": {}}, label)
        except Stop as e:
            # What the layer tried to set, beside why it may not.
            sets = ", ".join(f"{p}.{f}" for p, fs in ((doc or {}).get("phases") or {}).items()
                             if isinstance(fs, dict) for f in fs)
            raise Stop(f"{e} (it sets {sets or 'nothing readable'})")
        for phase, fields in check_layer(defaults, doc, label).items():
            for field, value in fields.items():
                table[phase][field] = {"value": value, "layer": name}
    for phase, row in table.items():
        timeout, ceiling = row["timeout"], row["max_timeout"]["value"]
        if timeout["value"] > ceiling:
            label = {"repository": ".claude/sdd-routing.yml", "local": ".claude/sdd-routing.local.yml",
                     "set": "--set"}.get(timeout["layer"], timeout["layer"])
            raise Stop(f"{label}: {phase}.timeout {timeout['value']} is beyond the phase's ceiling, "
                       f"max_timeout {ceiling}")
    validate(tools, "routing-table.schema.json", {"phases": {p: {k: v["value"] for k, v in row.items()}
                                                            for p, row in table.items()}}, "the merged table")
    return table


def versions(tools):
    out = {"speckit": ".".join(map(str, speckit_version(tools) or (0, 0, 0)))}
    pins = load(os.path.join(DOTFILES, "containers", "worker", "package.json")).get("dependencies", {})
    out["claude_code"] = pins.get("@anthropic-ai/claude-code", "unknown")
    out["pi"] = pins.get("@earendil-works/pi-coding-agent", "unknown")
    m = re.search(r"version (\S+)", host(tools["container"], "--version").stdout.decode())
    out["container"] = m.group(1) if m else "unknown"
    return out


def routing_doc(tools, table):
    return {"schema": "urn:dotfiles:sdd:routing:1", "step": "routing", "at": now(), "versions": versions(tools),
            "served": {}, "phases": table}


# ── The run bundle ───────────────────────────────────────────────────────────

def registry():
    return os.path.join(HOST_ENV["HOME"], ".local", "state", "sdd", "runs")


def new_run_id(root):
    """Unique across repositories: twelve random hex digits, and never one the
    registry or this repository already holds."""
    for _ in range(100):
        rid = secrets.token_hex(6)
        if not os.path.lexists(os.path.join(registry(), rid)) and not os.path.exists(os.path.join(root, rid)):
            return rid
    raise Stop("could not find an unused run id")


def lock(bundle, repo, base=None):
    pid = os.getpid()
    started = host("/bin/ps", "-o", "lstart=", "-p", str(pid)).stdout.decode().strip()
    old = load(os.path.join(bundle, "lock.json")) if os.path.exists(os.path.join(bundle, "lock.json")) else {}
    write_json(os.path.join(bundle, "lock.json"), {
        "run_id": os.path.basename(bundle), "pid": pid, "started": started,
        "base": base or old.get("base"), "repo": repo})


def write_bundle(tools, repo, table):
    root = os.path.join(common_dir(repo), "sdd")
    os.makedirs(root, exist_ok=True)
    rid = new_run_id(root)
    bundle = os.path.join(root, rid)
    os.makedirs(os.path.join(bundle, "admissions"))
    base = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
    lock(bundle, repo, base)
    write_json(os.path.join(bundle, "tools.json"), tools)
    write_json(os.path.join(bundle, "optin.json"), {"implement": local_config(repo, "sdd.implement")})
    write_json(os.path.join(bundle, "check.json"), {"command": local_config(repo, "sdd.check")})
    write_json(os.path.join(bundle, "routing.json"), routing_doc(tools, table))
    validate(tools, "routing.schema.json", load(os.path.join(bundle, "routing.json")), "the run's routing.json")
    shutil.copytree(os.path.join(SPECKIT, "profiles"), os.path.join(bundle, "profiles"))
    # Run governance, frozen at start like the routing table: the brief, pi's
    # models and their prices, and the registries the proxy lets passes read.
    for name in ("brief.md", "pi-models.json", "egress-registries.txt"):
        shutil.copy2(os.path.join(SPECKIT, name), os.path.join(bundle, name))
    os.makedirs(os.path.join(bundle, "hooks"))
    shutil.copy2(os.path.join(DOTFILES, "claude", "config-guard.sh"), os.path.join(bundle, "hooks", "config-guard.sh"))
    os.makedirs(registry(), exist_ok=True)
    os.symlink(bundle, os.path.join(registry(), rid))
    return rid, bundle


def finish(bundle, outcome):
    """The run holds its worker image no longer (prepare-worker's pruning)."""
    path = os.path.join(bundle, "finished.json")
    if not os.path.exists(path):
        write_json(path, {"at": now(), "outcome": outcome})
    link = os.path.join(registry(), os.path.basename(bundle))
    if os.path.islink(link):
        os.unlink(link)


def step(tools, bundle, repo, *args, out=subprocess.PIPE):
    env = dict(os.environ, SDD_RUN_DIR=bundle)
    return subprocess.run([tools["sdd-step"], *args], cwd=repo, env=env, stdout=out, stderr=subprocess.PIPE)


# ── The proxy and Spec Kit ───────────────────────────────────────────────────

def start_proxy(tools, bundle, repo):
    """The run's egress proxy, in a session of its own so a Ctrl-C meant for
    Spec Kit does not reach it; sdd-run stops it."""
    for leftover in ("proxy.json", "proxy-ca.pem"):
        if os.path.exists(os.path.join(bundle, leftover)):
            os.remove(os.path.join(bundle, leftover))
    beat(bundle)
    logf = open(os.path.join(bundle, "proxy.log"), "a")
    proc = subprocess.Popen([tools["sdd-step"], "egress-proxy"], cwd=repo, env=dict(os.environ, SDD_RUN_DIR=bundle),
                            stdin=subprocess.DEVNULL, stdout=logf, stderr=logf, start_new_session=True)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if os.path.exists(os.path.join(bundle, "proxy.json")) and os.path.exists(os.path.join(bundle, "proxy-ca.pem")):
            return proc
        if proc.poll() is not None:
            break
        time.sleep(0.2)
        beat(bundle)
    stop_proxy(proc)
    with open(os.path.join(bundle, "proxy.log")) as f:
        tail = " / ".join(f.read().strip().splitlines()[-3:])
    raise Stop(f"the egress proxy did not start: {tail or 'it said nothing'} (log: {bundle}/proxy.log)")


def beat(bundle):
    path = os.path.join(bundle, "admissions", "heartbeat")
    with open(path, "a"):
        os.utime(path, None)


def stop_proxy(proc):
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def run_speckit(tools, bundle, repo, args):
    """Spec Kit as a child, the proxy beating beside it, stopped when it
    exits — paused, completed, failed or interrupted."""
    proxy = start_proxy(tools, bundle, repo)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_EFFORT_LEVEL"}  # research R14
    env.update(SDD_RUN_DIR=bundle, SDD_STEP=tools["sdd-step"], SPECKIT_WORKFLOW_RUN_ID=os.path.basename(bundle))
    child = None

    def terminate(signum, _frame):
        if child and child.poll() is None:
            child.send_signal(signum)

    # A handler, not SIG_IGN: Spec Kit inherits the default disposition, so a
    # Ctrl-C reaches it and pauses the run; sdd-run only outlives it.
    signal.signal(signal.SIGINT, lambda *_: None)
    signal.signal(signal.SIGTERM, terminate)
    try:
        child = subprocess.Popen([tools["specify"], "workflow", *args], cwd=repo, env=env)
        while child.poll() is None:
            beat(bundle)
            try:
                child.wait(timeout=HEARTBEAT_SECONDS)
            except subprocess.TimeoutExpired:
                pass
    finally:
        stop_proxy(proxy)
    return child.returncode


def run_state(repo, rid):
    try:
        return load(os.path.join(repo, ".specify", "workflows", "runs", rid, "state.json"))
    except (OSError, ValueError):
        return {}


def feature_dir(repo):
    try:
        d = load(os.path.join(repo, ".specify", "feature.json"))["feature_directory"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if isinstance(d, str) and re.fullmatch(r"specs/[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*", d) and os.path.isdir(os.path.join(repo, d)):
        return d
    return None


def stuck(at):
    """The stuck stop a step id names, or None. Spec Kit names a step's first
    pass by its bare id and later passes `<loop>:<step>:<n>` (seen on 1.2.2,
    check 96)."""
    parts = (at or "").split(":")
    name = parts[1] if len(parts) == 3 else parts[0]
    return name if name in STUCK_STEPS else None


def step_message(state, at):
    """What the failed step itself said: the engine prints only "Shell
    command exited with code 1", and keeps the step's stderr in its state."""
    try:
        err = state["step_results"][at]["output"]["stderr"]
    except (KeyError, TypeError):
        return ""
    return "\n".join((err or "").strip().splitlines()[-5:])


def report(tools, bundle, repo, code):
    """What the owner sees when Spec Kit exits, and the bundle's record."""
    rid = os.path.basename(bundle)
    feature = feature_dir(repo)
    if feature:
        record = os.path.join(repo, feature, ".sdd", "routing.json")
        if not os.path.exists(record):
            os.makedirs(os.path.dirname(record), exist_ok=True)
            shutil.copy(os.path.join(bundle, "routing.json"), record)
    state = run_state(repo, rid)
    status, at = state.get("status"), state.get("current_step_id")
    if status == "completed":
        finish(bundle, "completed")
        print(f"sdd-run: run {rid} completed")
        return 0
    if status == "paused":
        gate = workflow_step(tools, repo, at) if at else None
        if gate and gate.get("type") == "gate":
            options = "|".join(gate.get("options") or ["approve", "reject"])
            print(f"sdd-run: run {rid} paused at {at}: sdd-run resume {rid} {options}")
        else:
            print(f"sdd-run: run {rid} paused at {at}: sdd-run resume {rid}")
        return 0
    message = step_message(state, at) if status == "failed" else ""
    if message:
        print(message)
    if status == "failed" and stuck(at):
        print(f"sdd-run: run {rid} stopped at {at}: sdd-run resume {rid} retry (one more round), "
              f"or sdd-run abort {rid}")
    elif status == "failed":
        print(f"sdd-run: run {rid} failed at {at}; once its cause is fixed: sdd-run resume {rid}")
    return code


# ── Commands ─────────────────────────────────────────────────────────────────

def bundle_of(repo, rid):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", rid or ""):
        raise Stop(f"{rid!r} is not a run id")
    bundle = os.path.join(common_dir(repo), "sdd", rid)
    if not os.path.isfile(os.path.join(bundle, "lock.json")):
        raise Stop(f"no run {rid} in this repository")
    return bundle


def alive(lock_doc):
    """The lock's process exists and is the one that wrote it (same start
    time), so a reused process id does not keep a dead run alive."""
    try:
        os.kill(int(lock_doc["pid"]), 0)
    except (OSError, ValueError, KeyError, TypeError):
        return False
    started = host("/bin/ps", "-o", "lstart=", "-p", str(lock_doc["pid"])).stdout.decode().strip()
    return started == str(lock_doc.get("started", "")).strip()


def start(args):
    sets, description, from_dir = [], None, None
    while args:
        a = args.pop(0)
        if a == "--set" and args:
            sets.append(args.pop(0))
        elif a == "--from" and args:
            from_dir = args.pop(0).rstrip("/")
        elif description is None and not a.startswith("--"):
            description = a
        else:
            raise Stop(f"start: unexpected {a!r}")
    if (description is None) == (from_dir is None):
        raise Stop('usage: sdd-run start [--set <phase>.<field>=<value> ...] "<description>" | --from <feature dir>')
    repo = repo_root()
    tools = resolve_tools()
    prerequisites(tools, repo)
    inputs = [f"spec={description}"] if description is not None else from_inputs(repo, from_dir)
    table = effective_table(tools, repo, sets)
    rid, bundle = write_bundle(tools, repo, table)
    try:
        r = step(tools, bundle, repo, "cleanup")
        if r.returncode != 0:
            raise Stop("cleaning up earlier runs failed: " + r.stderr.decode(errors="replace").strip()[-300:])
        r = step(tools, bundle, repo, "prepare-worker")
        if r.returncode != 0:
            raise Stop("preparing the worker image failed: " + r.stderr.decode(errors="replace").strip()[-600:])
        if local_config(repo, "sdd.implement") != "deepseek":
            print("sdd-run: implementation runs on Sonnet: this repository is not opted in to DeepSeek "
                  "(git config --local sdd.implement deepseek)")
        print(f"sdd-run: run {rid}")
        code = run_speckit(tools, bundle, repo, ["run", WORKFLOW_ID, *sum((["-i", i] for i in inputs), [])])
    except Stop:
        finish(bundle, "not started")
        raise
    return report(tools, bundle, repo, code)


def from_inputs(repo, feature):
    """start --from: the feature's spec, and the first phase .sdd/phases.json
    does not record as finished (FR-022)."""
    if not re.fullmatch(r"specs/[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*", feature or "") or \
            not os.path.isfile(os.path.join(repo, feature, "spec.md")):
        raise Stop(f"--from {feature}: not a feature directory with a spec.md (specs/<nnn>-<slug>)")
    try:
        done = {d["phase"] for d in load(os.path.join(repo, feature, ".sdd", "phases.json"))["done"]}
    except (OSError, ValueError, KeyError, TypeError):
        done = set()
    left = [p for p in PHASES if p not in done]
    if len(left) == len(PHASES):
        raise Stop(f"no phase of {feature} finished: start it anew with a description")
    if not left:
        raise Stop(f"every phase of {feature} finished: nothing to run")
    return [f"spec={feature}/spec.md", f"resume_from={left[0]}"]


def resume(args):
    if not args or len(args) > 2:
        raise Stop("usage: sdd-run resume <run_id> [<verdict>|retry]")
    rid, verdict = args[0], (args[1] if len(args) > 1 else None)
    repo = repo_root()
    bundle = bundle_of(repo, rid)
    tools = load(os.path.join(bundle, "tools.json"))
    prerequisites(tools, repo)
    if os.path.exists(os.path.join(bundle, "finished.json")):
        raise Stop(f"run {rid} is finished ({load(os.path.join(bundle, 'finished.json')).get('outcome')})")
    state = run_state(repo, rid)
    status, at = state.get("status"), state.get("current_step_id")
    if status == "running":
        if alive(load(os.path.join(bundle, "lock.json"))):
            raise Stop(f"run {rid} is running")
        feature = feature_dir(repo)
        left = ", ".join(from_inputs_left(repo, feature)) if feature else "every phase"
        raise Stop(f"run {rid} died while running (its process is gone), and Spec Kit cannot resume it: "
                   f"sdd-run start --from {feature or '<feature dir>'} (phases that run again: {left})")
    inputs = []
    if verdict == "retry":
        if not stuck(at):
            raise Stop(f"run {rid} is not stopped at {' or '.join(STUCK_STEPS)}; retry answers only those")
        os.makedirs(os.path.join(bundle, "verdicts"), exist_ok=True)
        with open(os.path.join(bundle, "verdicts", "retry"), "w") as f:
            f.write(now())
    elif verdict:
        gate = workflow_step(tools, repo, at) if at else None
        if not gate or gate.get("type") != "gate" or not gate.get("verdict_input"):
            raise Stop(f"run {rid} is not paused at a gate (it is at {at}): sdd-run resume {rid}")
        options = gate.get("options") or ["approve", "reject"]
        if verdict not in options:
            raise Stop(f"{at} takes {', '.join(options)}, not {verdict}")
        inputs = ["-i", f"{gate['verdict_input']}={verdict}"]
    image = load(os.path.join(bundle, "worker.json"))["image"]
    if host(tools["container"], "image", "inspect", image).returncode != 0:
        raise Stop(f"run {rid}'s worker image {image} is gone; start the feature again: sdd-run start --from <feature dir>")
    lock(bundle, repo)
    link = os.path.join(registry(), rid)
    if not os.path.lexists(link):
        os.makedirs(registry(), exist_ok=True)
        os.symlink(bundle, link)
    r = step(tools, bundle, repo, "cleanup")
    if r.returncode != 0:
        raise Stop("cleaning up earlier runs failed: " + r.stderr.decode(errors="replace").strip()[-300:])
    code = run_speckit(tools, bundle, repo, ["resume", rid, *inputs])
    return report(tools, bundle, repo, code)


def from_inputs_left(repo, feature):
    try:
        done = {d["phase"] for d in load(os.path.join(repo, feature, ".sdd", "phases.json"))["done"]}
    except (OSError, ValueError, KeyError, TypeError):
        done = set()
    return [p for p in PHASES if p not in done]


def abort(args):
    if len(args) != 1:
        raise Stop("usage: sdd-run abort <run_id>")
    rid = args[0]
    repo = repo_root()
    bundle = bundle_of(repo, rid)
    if alive(load(os.path.join(bundle, "lock.json"))):
        raise Stop(f"run {rid} is running; stop it first (Ctrl-C in its terminal)")
    tools = load(os.path.join(bundle, "tools.json"))
    finish(bundle, "aborted")
    r = step(tools, bundle, repo, "cleanup", rid)
    if r.returncode != 0:
        raise Stop("removing the run's containers failed: " + r.stderr.decode(errors="replace").strip()[-300:])
    print(f"sdd-run: run {rid} aborted; the feature's worktree is left as it is")
    return 0


def routing(args):
    sets, init_local = [], False
    while args:
        a = args.pop(0)
        if a == "--set" and args:
            sets.append(args.pop(0))
        elif a == "--init-local":
            init_local = True
        else:
            raise Stop(f"routing: unexpected {a!r}")
    repo = repo_root()
    tools = resolve_tools()
    if init_local:
        rel = ".claude/sdd-routing.local.yml"
        path = os.path.join(repo, rel)
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write("# This machine's routing changes for this repository, over the defaults and\n"
                        "# .claude/sdd-routing.yml: only model, effort and timeout per phase. Not\n"
                        "# versioned (excluded through git's info/exclude).\n"
                        "phases: {}\n")
        exclude = os.path.join(common_dir(repo), "info", "exclude")
        os.makedirs(os.path.dirname(exclude), exist_ok=True)
        lines = open(exclude).read().splitlines() if os.path.exists(exclude) else []
        if rel not in lines:
            with open(exclude, "a") as f:
                f.write(("" if not lines or lines[-1] == "" else "") + rel + "\n")
        print(f"sdd-run: {rel} is ready and excluded from git")
    table = effective_table(tools, repo, sets)
    for phase, row in table.items():
        for field, v in row.items():
            value = v["value"] if not isinstance(v["value"], (list, dict)) else json.dumps(v["value"])
            print(f"{phase:<20} {field:<12} {str(value):<28} {v['layer']}")
    return 0


def usage(args):
    """Per model, every attempt's reported cost, failed and resumed ones
    included; attempts that reported nothing listed; DeepSeek's tokens priced
    from the worker's models.json (per million tokens)."""
    if len(args) != 1:
        raise Stop("usage: sdd-run usage <run_id>")
    rid = args[0]
    repo = repo_root()
    bundle = os.path.join(common_dir(repo), "sdd", rid)
    path = os.path.join(bundle, "usage.jsonl")
    if not os.path.isfile(path):
        raise Stop(f"run {rid} has no usage.jsonl in this repository")
    lines = []
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("run") == rid:
                lines.append(d)
    prices = {}
    # The run's own prices, frozen with it: a later change of the table
    # does not reprice a past run.
    for p in load(os.path.join(bundle, "pi-models.json"))["providers"].values():
        for m in p.get("models", []):
            prices[m["id"]] = m.get("cost", {})
    models, unreported = {}, []
    pending = None
    for d in lines + [{"event": "start"}]:  # a sentinel closes the last attempt
        if d.get("event") == "start":
            if pending:
                unreported.append(f"{pending['phase']} (no end)")
            pending = d if d.get("phase") else None
        elif d.get("event") == "end" and pending:
            u = d.get("usage") or {}
            model = d.get("model") or pending.get("model")
            m = models.setdefault(model, {"attempts": 0, "cost": 0.0, "tokens": [0, 0, 0]})
            if "total_cost_usd" in u:
                m["attempts"] += 1
                m["cost"] += float(u["total_cost_usd"])
            elif {"input", "cached", "output"} <= set(u):
                c = prices.get(model, {})
                m["attempts"] += 1
                m["cost"] += (u["input"] * c.get("input", 0) + u["cached"] * c.get("cacheRead", 0)
                              + u["output"] * c.get("output", 0)) / 1e6
                m["tokens"] = [a + b for a, b in zip(m["tokens"], (u["input"], u["cached"], u["output"]))]
            else:
                unreported.append(f"{pending['phase']} (no usage)")
            pending = None
    total = 0.0
    for model, m in sorted(models.items()):
        if not m["attempts"]:
            continue
        total += m["cost"]
        line = f"{model:<24} {m['attempts']} attempt{'s' if m['attempts'] != 1 else ''}  ${m['cost']:.4f}"
        if any(m["tokens"]):
            line += "  (%d input, %d cached, %d output tokens)" % tuple(m["tokens"])
        print(line)
    if unreported:
        print(f"{'unreported':<24} {len(unreported)} attempt{'s' if len(unreported) != 1 else ''}  "
              + ", ".join(unreported))
    print(f"{'total':<24} ${total:.4f}")
    return 0


COMMANDS = {"start": start, "resume": resume, "abort": abort, "routing": routing, "usage": usage}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("usage: sdd-run <start|resume|abort|routing|usage> ...", file=sys.stderr)
        return 2
    try:
        return COMMANDS[sys.argv[1]](sys.argv[2:])
    except Stop as e:
        print(f"sdd-run: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
