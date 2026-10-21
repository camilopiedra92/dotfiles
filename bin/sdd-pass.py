"""The contained pass of the sdd-routed workflow (contracts/pass.md).

Run by `sdd-step` as `/usr/bin/python3 -I sdd-pass.py <agent PHASE|implement|verify> REPO`,
with its working directory in the run bundle, PATH fixed to the system's and
nothing of the repository's configuration in reach: every host tool is called
by an absolute path, git as /usr/bin/git with system and global configuration,
hooks and fsmonitor off, and the container runtime, check-jsonschema and the
Keychain through the paths `sdd-run start` froze in tools.json.

An agent's output is data until judged: the agent works on an export with no
history, inside the worker container; the patch between that export and an
untouched baseline is judged here, and only a judged patch is applied to the
repository, as one commit. Written for the system Python (3.9 on macOS), the
only interpreter whose path no repository can change.
"""

import fnmatch
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

DOTFILES = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
GIT = "/usr/bin/git"
TAR = "/usr/bin/tar"
HOST_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": os.environ.get("HOME", "/var/empty"),
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "LC_ALL": "C",
}
GIT_OFF = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "commit.gpgsign=false"]
# Paths whose members govern the run or instruct a later agent; no implement
# pass may touch them, at any depth (contracts/pass.md, Judge).
PROTECTED_DIRS = {".git", ".claude", ".specify", ".sdd"}
PROTECTED_FILES = {"CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".mcp.json"}
AUTOMATION = re.compile(r"^(\.github/|\.husky/|githooks/|\.vscode/tasks\.json$|\.zed/tasks\.json$)")
CREDENTIALS = {"claude": "claude-oauth", "pi": "deepseek-api"}
SCHEMA_STEPS = {"clarify", "review", "converge"}


class PassFailed(Exception):
    pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path):
    with open(path) as f:
        return json.load(f)


class Run:
    def __init__(self, bundle, repo):
        self.dir = bundle
        self.repo = repo
        self.tools = load(os.path.join(bundle, "tools.json"))
        self.lock = load(os.path.join(bundle, "lock.json"))
        self.id = self.lock["run_id"]
        routing = load(os.path.join(bundle, "routing.json"))
        self.rows = {p: {k: v["value"] for k, v in row.items()} for p, row in routing["phases"].items()}

    def tool(self, name):
        path = self.tools.get(name)
        if not path or not os.path.isabs(path):
            raise PassFailed(f"tools.json names no absolute path for {name}")
        return path

    def git(self, *args, check=True, stdout=subprocess.PIPE, input=None):
        ident = self.identity()
        cmd = [GIT, "-C", self.repo, *GIT_OFF, "-c", f"user.name={ident[0]}", "-c", f"user.email={ident[1]}", *args]
        r = subprocess.run(cmd, env=HOST_ENV, stdout=stdout, stderr=subprocess.PIPE, input=input, cwd=self.dir)
        if check and r.returncode != 0:
            raise PassFailed(f"git {args[0]} failed: {r.stderr.decode(errors='replace').strip()}")
        return r

    def identity(self):
        # The repository's own identity (its local config, which no agent can
        # write: agents never see .git), else the run's.
        if not hasattr(self, "_ident"):
            vals = []
            for key in ("user.name", "user.email"):
                r = subprocess.run([GIT, "-C", self.repo, "config", "--local", "--get", key],
                                   env=HOST_ENV, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=self.dir)
                vals.append(r.stdout.decode().strip() or ("sdd-run" if key == "user.name" else "sdd-run@localhost"))
            self._ident = vals
        return self._ident

    def secret(self, service):
        r = subprocess.run([self.tool("security"), "find-generic-password", "-s", service, "-w"],
                           env=HOST_ENV, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=self.dir)
        value = r.stdout.decode().strip()
        if r.returncode != 0 or not value:
            raise PassFailed(f"the Keychain item {service} is missing or blank")
        return value

    def usage(self, record):
        with open(os.path.join(self.dir, "usage.jsonl"), "a") as f:
            f.write(json.dumps({"run": self.id, "at": now(), **record}) + "\n")


def feature_dir(repo):
    try:
        d = load(os.path.join(repo, ".specify", "feature.json"))["feature_directory"]
    except (OSError, ValueError, KeyError, TypeError):
        raise PassFailed(".specify/feature.json does not name a feature_directory")
    if not isinstance(d, str) or not re.fullmatch(r"specs/[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*", d) or not os.path.isdir(os.path.join(repo, d)):
        raise PassFailed(f"feature directory '{d}' is not an existing specs/<nnn>-<slug>")
    return d


def protected(path):
    parts = path.split("/")
    if any(p in PROTECTED_DIRS for p in parts[:-1]):
        return True
    name = parts[-1]
    return name.startswith(".git") or name in PROTECTED_DIRS or name in PROTECTED_FILES


def allowed(path, writes, feature):
    for pattern in writes:
        pattern = pattern.replace("<f>", feature)
        if pattern == "**" or fnmatch.fnmatchcase(path, pattern):
            return True
        if pattern.endswith("/**") and path.startswith(pattern[:-2]):
            return True
    return False


class Pass:
    def __init__(self, run, kind, phase=None):
        self.run, self.kind, self.phase = run, kind, phase
        self.row = run.rows.get(phase) if phase else None
        if phase and not self.row:
            raise PassFailed(f"no routing row for {phase}")
        n = len(os.listdir(os.path.join(run.dir, "passes"))) if os.path.isdir(os.path.join(run.dir, "passes")) else 0
        self.id = f"{phase or kind}-{int(time.time() * 1000)}-{n}"
        self.dir = os.path.join(run.dir, "passes", self.id)
        self.export = os.path.join(self.dir, "export")
        self.baseline = os.path.join(self.dir, "baseline")
        self.inputs = os.path.join(self.dir, "inputs")
        self.name = f"sdd-{run.id}-{self.id}"
        # The pass's placeholder: what its agent sends where a credential would
        # go, and the key the egress proxy finds its admission by. The worker's
        # entrypoint accepts only this shape (containers/worker/entrypoint.sh).
        self.token = "sdd-pass-" + secrets.token_urlsafe(32)
        self.admission = os.path.join(run.dir, "admissions", self.token + ".json")

    # 1. Export
    def prepare(self, feature):
        os.makedirs(self.inputs)
        os.makedirs(os.path.join(self.run.dir, "admissions"), exist_ok=True)
        if feature:
            self.run.git("add", "--", feature)
            if self.run.git("diff", "--cached", "--quiet", check=False).returncode != 0:
                self.run.git("commit", "-q", "-m", f"sdd: {os.path.basename(feature)} before {self.phase or self.kind}")
        for target in (self.baseline, self.export):
            os.makedirs(target)
            archive = self.run.git("archive", "--format=tar", "HEAD").stdout
            r = subprocess.run([TAR, "-x", "-f", "-", "-C", target], input=archive, env=HOST_ENV,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.dir)
            if r.returncode != 0:
                raise PassFailed("extracting the export failed: " + r.stderr.decode(errors="replace").strip())

    # 3, 4. Container and limit
    def container(self, command, env, mounts, timeout):
        rt = self.run.tool("container")
        proxy = load(os.path.join(self.run.dir, "proxy.json"))
        image = load(os.path.join(self.run.dir, "worker.json"))["image"]
        cmd = [rt, "run", "--rm", "--name", self.name, "--label", f"sdd.run={self.run.id}",
               "--network", f"sdd-{self.run.id}", "--cap-add", "CAP_NET_ADMIN", "--cap-add", "CAP_NET_RAW",
               "-e", f"SDD_PROXY={proxy['address']}:{proxy['port']}", "-e", f"SDD_PASS_TOKEN={self.token}"]
        for k, v in env.items():
            cmd += ["-e", f"{k}={v}"]
        cmd += ["-v", f"{self.export}:/work"]
        for m in mounts:
            cmd += ["-v", m]
        cmd += [image, *command]
        proc = subprocess.Popen(cmd, env=HOST_ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, cwd=self.dir)
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            subprocess.run([rt, "stop", self.name], env=HOST_ENV, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, cwd=self.dir)
            proc.kill()
            proc.communicate()
            raise PassFailed(f"{self.phase or self.kind}: stopped at its {timeout}-second limit; nothing applied")
        return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace")

    def proxy_url(self):
        proxy = load(os.path.join(self.run.dir, "proxy.json"))
        return f"http://{proxy['address']}:{proxy['port']}"

    def admit(self, hosts):
        with open(self.admission, "w") as f:
            json.dump({"admit": hosts}, f)

    def cache(self, kind):
        name = f"sdd-cache-{kind}-{self.run.id}"
        subprocess.run([self.run.tool("container"), "volume", "create", name], env=HOST_ENV,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=self.dir)
        return f"{name}:/cache"

    # 5, 6. Patch and judge
    def changes(self):
        """Every created, changed or deleted path, with its new mode, read from
        the same two trees the patch is made from."""
        r = subprocess.run([GIT, *GIT_OFF, "diff", "--no-index", "--raw", "-z", "--no-renames", "--no-abbrev",
                            "baseline", "export"], env=HOST_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           cwd=self.dir)
        if r.returncode not in (0, 1):
            raise PassFailed("judge: listing the changes failed: " + r.stderr.decode(errors="replace").strip())
        fields = r.stdout.decode("utf-8", errors="surrogateescape").split("\0")
        out = []
        i = 0
        while i < len(fields) - 1:
            meta, path = fields[i], fields[i + 1]
            i += 2
            _, new_mode = meta.lstrip(":").split(" ")[0:2]
            status = meta.split(" ")[-1]
            for prefix in ("baseline/", "export/"):
                if path.startswith(prefix):
                    path = path[len(prefix):]
            out.append((status, new_mode, path))
        for root, dirs, files in os.walk(self.export):
            for name in dirs + files:
                full = os.path.join(root, name)
                if not (os.path.isdir(full) or os.path.isfile(full) or os.path.islink(full)):
                    raise PassFailed(f"judge: {os.path.relpath(full, self.export)} is not a regular file")
        return out

    def patch(self):
        r = subprocess.run([GIT, *GIT_OFF, "diff", "--no-index", "--binary", "--no-prefix", "--no-renames",
                            "baseline", "export"], env=HOST_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           cwd=self.dir)
        if r.returncode not in (0, 1):
            raise PassFailed("making the patch failed: " + r.stderr.decode(errors="replace").strip())
        return r.stdout

    def judge(self, changes, writes, feature, implement):
        refused = []
        for status, mode, path in changes:
            if implement:
                if protected(path):
                    refused.append(f"{path}: in the protected set")
                    continue
            elif not allowed(path, writes, feature):
                refused.append(f"{path}: outside this step's writes")
                continue
            if status != "D" and mode not in ("100644", "100755"):
                refused.append(f"{path}: mode {mode} (a symlink, submodule or unusual mode)")
        if refused:
            raise PassFailed("judge refused the patch:\n  " + "\n  ".join(refused))
        flagged = {"check_changes": [], "automation_changes": []}
        if implement:
            guard = os.path.join(self.run.dir, "hooks", "config-guard.sh")
            if not os.access(guard, os.X_OK):
                raise PassFailed("judge: the bundle's config-guard.sh cannot run; nothing applied")
            for status, mode, path in changes:
                full = os.path.join(self.export, path)
                content = "" if status == "D" else open(full, encoding="utf-8", errors="replace").read()
                payload = json.dumps({"tool_name": "Write", "cwd": self.run.repo,
                                      "tool_input": {"file_path": os.path.join(self.run.repo, path), "content": content}})
                r = subprocess.run(["/bin/bash", guard], input=payload.encode(), env=HOST_ENV,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.dir)
                if r.returncode != 0:
                    raise PassFailed(f"judge: config-guard failed on {path}; nothing applied")
                decision = None
                if r.stdout.strip():
                    try:
                        decision = json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"]
                    except (ValueError, KeyError, TypeError):
                        raise PassFailed(f"judge: config-guard answered unreadably on {path}")
                if decision in ("ask", "deny"):
                    raise PassFailed(f"judge: {path} changes a guarded check configuration (config-guard: {decision}); nothing applied")
                check = load(os.path.join(self.run.dir, "check.json"))["command"].split()[0]
                if path == check.lstrip("./"):
                    flagged["check_changes"].append(path)
                if AUTOMATION.match(path) or mode == "100755":
                    flagged["automation_changes"].append(path)
        return flagged

    def scan(self, blobs, agent):
        services = {"claude-oauth"}
        if agent == "pi" or load(os.path.join(self.run.dir, "optin.json")).get("implement") == "deepseek":
            services.add("deepseek-api")
        for service in sorted(services):
            try:
                value = self.run.secret(service)
            except PassFailed:
                continue
            for blob in blobs:
                if value.encode() in blob:
                    raise PassFailed(f"the output holds the exact value of the credential {service}; nothing applied")

    # 7. Apply
    def apply(self, patch, message):
        self.run.git("apply", "-p1", "--index", "--whitespace=nowarn", input=patch)
        self.run.git("commit", "-q", "-m", message)
        return self.run.git("rev-parse", "HEAD").stdout.decode().strip()

    def cleanup(self):
        try:
            os.remove(self.admission)
        except OSError:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)


def agent_command(row, prompt, schema):
    if row["agent"] == "claude":
        cmd = ["claude", "-p", prompt, "--model", row["model"], "--effort", row["effort"],
               "--permission-mode", "dontAsk", "--permission-prompts", "none",
               "--setting-sources", "project", "--settings", "/bundle/profile.json",
               "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--output-format", "json"]
        if schema:
            cmd += ["--json-schema", json.dumps(schema)]
        return cmd
    return ["pi", "-p", "--mode", "json", "--no-session", "--model", f"deepseek/{row['model']}",
            "--thinking", row["effort"], prompt]


def agent_schema(step):
    """The outcome schema without the fields the host adds."""
    s = load(os.path.join(DOTFILES, "claude", "speckit", "schemas", f"{step}.schema.json"))
    for k in ("schema", "step", "at"):
        s["properties"].pop(k, None)
    s["required"] = [r for r in s["required"] if r not in ("schema", "step", "at")]
    for k in ("$id", "$schema", "title"):
        s.pop(k, None)
    return s


def parse_result(agent, stdout):
    if agent == "claude":
        try:
            result = json.loads(stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise PassFailed("the agent returned no JSON result")
        if result.get("is_error"):
            raise PassFailed("the agent reported an error: " + str(result.get("result", ""))[:300])
        if result.get("permission_denials"):
            tools = ", ".join(sorted({d.get("tool_name", "?") for d in result["permission_denials"]}))
            raise PassFailed(f"the agent was denied a tool it tried ({tools}); its profile did not allow it")
        return result.get("result", ""), result.get("structured_output"), {
            "total_cost_usd": result.get("total_cost_usd", 0), "modelUsage": result.get("modelUsage", {})}
    last = None
    for line in stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        m = e.get("message") or {}
        if e.get("type") == "message_end" and m.get("role") == "assistant":
            last = m
    if not last:
        raise PassFailed("pi returned no assistant message")
    u = last.get("usage") or {}
    text = " ".join(c.get("text", "") for c in last.get("content", []) if c.get("type") == "text")
    return text, None, {"input": u.get("input", 0), "cached": u.get("cacheRead", 0), "output": u.get("output", 0)}, last.get("model")


def write_outcome(run, feature, step, fields):
    path = os.path.join(run.repo, feature, ".sdd", f"{step}.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    doc = {"schema": f"urn:dotfiles:sdd:{step}:1", "step": step, "at": now(), **fields}
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1)
    schema = os.path.join(DOTFILES, "claude", "speckit", "schemas", f"{step}.schema.json")
    r = subprocess.run([run.tool("check-jsonschema"), "--schemafile", schema, tmp], env=HOST_ENV,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=run.dir)
    if r.returncode != 0:
        os.remove(tmp)
        raise PassFailed(f"the {step} outcome does not match its schema: {r.stdout.decode(errors='replace')[-400:]}")
    os.replace(tmp, path)


def run_agent(run, phase, implement=False):
    row = run.rows[phase]
    feature = feature_dir(run.repo)
    p = Pass(run, "implement" if implement else "agent", phase)
    try:
        p.prepare(feature)
        prompt = f"{row['prompt']} {feature}"
        schema = agent_schema(row["schema"]) if row.get("schema") in SCHEMA_STEPS else None
        mounts = [f"{p.inputs}:/bundle:ro"]
        if row["agent"] == "claude":
            shutil.copy(os.path.join(run.dir, "profiles", row["profile"] + ".json"), os.path.join(p.inputs, "profile.json"))
            env = {"ANTHROPIC_BASE_URL": p.proxy_url(), "CLAUDE_CODE_OAUTH_TOKEN": p.token}
        else:
            # pi's provider, from the worker's template, pointed at the proxy
            # with the placeholder as its key; the entrypoint refuses any other.
            models = load(os.path.join(DOTFILES, "containers", "worker", "models.json"))
            for provider in models["providers"].values():
                provider["baseUrl"] = p.proxy_url()
                provider["apiKey"] = p.token
            with open(os.path.join(p.inputs, "models.json"), "w") as f:
                json.dump(models, f, indent=1)
            env = {}
        hosts = ["anthropic" if row["agent"] == "claude" else "deepseek"]
        if implement:
            shutil.copy(os.path.join(run.dir, "check.json"), os.path.join(p.inputs, "check.json"))
            mounts.append(p.cache("implement"))
            hosts.append("registries")
        if phase == "review":
            diff_dir = os.path.join(p.dir, "input")
            os.makedirs(diff_dir)
            with open(os.path.join(diff_dir, "diff.patch"), "wb") as f:
                f.write(run.git("diff", "--binary", run.lock["base"], "HEAD").stdout)
            mounts.append(f"{diff_dir}:/input:ro")
        p.admit(hosts)
        run.usage({"event": "start", "phase": phase, "model": row["model"], "effort": row["effort"]})
        started = time.time()
        code, out, err = p.container(agent_command(row, prompt, schema), env, mounts, row["timeout"])
        parsed = parse_result(row["agent"], out)
        text, structured, usage = parsed[0], parsed[1], parsed[2]
        served = parsed[3] if len(parsed) > 3 else row["model"]
        run.usage({"event": "end", "phase": phase, "model": served, "effort": row["effort"], "usage": usage,
                   "exit": code})
        if code != 0:
            raise PassFailed(f"the agent exited {code}: {err.strip()[-300:]}")
        if row["agent"] == "pi" and served != row["model"]:
            raise PassFailed(f"pi reported model {served}, not the configured {row['model']}; nothing applied")
        changes = p.changes()
        patch = p.patch() if changes else b""
        flagged = p.judge(changes, row["writes"], feature, implement)
        p.scan([patch, text.encode(), json.dumps(structured).encode()], row["agent"])
        commit = None
        if changes:
            step = "implement" if implement else phase
            commit = p.apply(patch, f"{step}: {os.path.basename(feature)} ({served})")
        if structured is not None and row.get("schema"):
            write_outcome(run, feature, row["schema"], structured)
        if row.get("result_to"):
            with open(os.path.join(run.repo, feature, row["result_to"]), "w") as f:
                f.write(text)
        return {"changes": changes, "commit": commit, "usage": usage, "served": served, "flagged": flagged,
                "seconds": round(time.time() - started, 1), "row": row}
    finally:
        p.cleanup()


def implement(run):
    feature = feature_dir(run.repo)
    route_file = os.path.join(run.repo, feature, ".sdd", "route.json")
    try:
        agent = load(route_file)["agent"]
    except (OSError, ValueError, KeyError):
        raise PassFailed(".sdd/route.json is missing or unreadable; the route step runs first")
    if agent == "deepseek":
        now_opt = subprocess.run([GIT, "-C", run.repo, "config", "--local", "--get", "sdd.implement"], env=HOST_ENV,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=run.dir).stdout.decode().strip()
        frozen = load(os.path.join(run.dir, "optin.json")).get("implement")
        if now_opt != "deepseek" or frozen != "deepseek":
            print("sdd-step: the repository is not opted in to DeepSeek now; implementing on Sonnet", file=sys.stderr)
            agent = "sonnet"
    phase = "implement-deepseek" if agent == "deepseek" else "implement-sonnet"
    row = run.rows[phase]
    if not 1 <= row["timeout"] <= row["max_timeout"]:
        raise PassFailed(f"{phase}: timeout {row['timeout']} is outside 1..{row['max_timeout']}")
    run.secret("deepseek-api" if agent == "deepseek" else "claude-oauth")
    r = run_agent(run, phase, implement=True)
    write_outcome(run, feature, "implement", {
        "agent": agent, "model": r["served"],
        "pi_version": load(os.path.join(run.dir, "routing.json"))["versions"].get("pi") if agent == "deepseek" else None,
        "commit": r["commit"], "files": [c[2] for c in r["changes"]], "usage": r["usage"], "seconds": r["seconds"]})
    flags = os.path.join(run.dir, "flags.json")
    acc = load(flags) if os.path.exists(flags) else {"check_changes": [], "automation_changes": []}
    for k in acc:
        acc[k] = sorted(set(acc[k]) | set(r["flagged"][k]))
    with open(flags, "w") as f:
        json.dump(acc, f)
    print(f"{phase}: {len(r['changes'])} files changed" + (f", commit {r['commit'][:12]}" if r["commit"] else ", no change"))


def verify(run):
    feature = feature_dir(run.repo)
    command = load(os.path.join(run.dir, "check.json"))["command"]
    p = Pass(run, "verify")
    try:
        p.prepare(feature)
        p.admit(["registries"])
        code, out, err = p.container(["sh", "-c", command], {}, [p.cache("verify")], 3300)
    finally:
        p.cleanup()
    flags = os.path.join(run.dir, "flags.json")
    acc = load(flags) if os.path.exists(flags) else {"check_changes": [], "automation_changes": []}
    tail = "\n".join((out + err).splitlines()[-200:])
    write_outcome(run, feature, "verify", {"command": command, "exit": code, "tail": tail, **acc})
    if os.path.exists(flags):
        os.remove(flags)
    print("pass" if code == 0 else "fail")


def main():
    if len(sys.argv) < 3:
        print("usage: sdd-pass.py <agent PHASE|implement|verify> REPO", file=sys.stderr)
        return 2
    what, repo = sys.argv[1], sys.argv[-1]
    try:
        run = Run(os.getcwd(), repo)
        if what == "agent":
            run_agent(run, sys.argv[2])
        elif what == "implement":
            implement(run)
        elif what == "verify":
            verify(run)
        else:
            raise PassFailed(f"unknown pass {what}")
    except PassFailed as e:
        print(f"sdd-step: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
