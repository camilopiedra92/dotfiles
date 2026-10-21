"""The contained pass of the sdd-routed workflow (contracts/pass.md).

Run by `sdd-step` as `/usr/bin/python3 -I sdd-pass.py <subcommand> [ARG] REPO`, for
`agent PHASE`, `implement`, `verify`, and the machinery around them:
`prepare-worker`, `egress-proxy` and `cleanup [RUN_ID]`,
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
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
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
    # Paths go to git as data: no pathspec magic in a name an agent chose.
    "GIT_LITERAL_PATHSPECS": "1",
}
# The no-index diffs cannot read the repository's own core.precomposeUnicode
# (its discovery stops at the pass), so they set it as git on macOS does: a
# decomposed name an agent writes reaches the index precomposed, as the
# owner's own git would add it (review of Phase 2, second round).
PRECOMPOSE = ["-c", "core.precomposeUnicode=true"]
GIT_OFF = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "commit.gpgsign=false"]
# Paths whose members govern the run or instruct a later agent; no implement
# pass may touch them, at any depth (contracts/pass.md, Judge).
# Compared folded (fold() below), since APFS is case-insensitive and folds
# more than case: .Claude/ is .claude/ there, and so is a long s (review of
# Phase 2, proved).
PROTECTED_DIRS = {".git", ".claude", ".specify", ".sdd"}
PROTECTED_FILES = {"claude.md", "claude.local.md", "agents.md", ".mcp.json"}
AUTOMATION = re.compile(r"^(\.github/|\.husky/|\.vscode/tasks\.json$|\.zed/tasks\.json$)")
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


def fold(name):
    """A name as a case- and normalization-insensitive filesystem sees it."""
    return unicodedata.normalize("NFKC", unicodedata.normalize("NFKC", name).casefold())


def protected(path):
    parts = [fold(p) for p in path.split("/")]
    if any(p in PROTECTED_DIRS for p in parts[:-1]):
        return True
    name = parts[-1]
    # .gitattributes, .gitignore, .gitmodules and the like govern git itself;
    # .gitkeep is only a placeholder that keeps a directory.
    return (name.startswith(".git") and name != ".gitkeep") or name in PROTECTED_DIRS or name in PROTECTED_FILES


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
        # The authority the egress proxy inspects registry traffic with: the
        # worker trusts it, or no registry is reachable (FR-031). Checked
        # before anything is committed or started.
        ca = os.path.join(self.run.dir, "proxy-ca.pem")
        if not os.path.isfile(ca):
            raise PassFailed("the bundle has no proxy-ca.pem: the run's egress proxy is not running")
        os.makedirs(self.inputs)
        shutil.copy(ca, os.path.join(self.inputs, "proxy-ca.pem"))
        os.makedirs(os.path.join(self.run.dir, "admissions"), exist_ok=True)
        if feature:
            # Only the feature directory: whatever else the owner has staged
            # stays staged and out of the run's commits.
            self.run.git("add", "--", feature)
            if self.run.git("diff", "--cached", "--quiet", "--", feature, check=False).returncode != 0:
                self.run.git("commit", "-q", "-m", f"sdd: {os.path.basename(feature)} before {self.phase or self.kind}",
                             "--", feature)
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
        r = subprocess.run([GIT, *GIT_OFF, *PRECOMPOSE, "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--raw", "-z",
                            "--no-renames", "--no-abbrev", "baseline", "export"], env=self.isolated_env(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.dir)
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
            # One prefix only: a tracked export/x is reported as
            # baseline/export/x and is export/x (review of Phase 2, proved).
            for prefix in ("baseline/", "export/"):
                if path.startswith(prefix):
                    path = path[len(prefix):]
                    break
            out.append((status, new_mode, path))
        for root, dirs, files in os.walk(self.export):
            for name in dirs + files:
                full = os.path.join(root, name)
                if not (os.path.isdir(full) or os.path.isfile(full) or os.path.islink(full)):
                    raise PassFailed(f"judge: {os.path.relpath(full, self.export)} is not a regular file")
        return out

    def isolated_env(self):
        # The bundle lives in the repository's .git, so a no-index diff run
        # here would find that repository and its diff configuration (review
        # of Phase 2, proved with diff.external): no discovery above the pass.
        return dict(HOST_ENV, GIT_CEILING_DIRECTORIES=os.path.dirname(self.dir))

    def patch(self):
        r = subprocess.run([GIT, *GIT_OFF, *PRECOMPOSE, "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--binary",
                            "--no-prefix", "--no-renames", "baseline", "export"], env=self.isolated_env(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.dir)
        if r.returncode not in (0, 1):
            raise PassFailed("making the patch failed: " + r.stderr.decode(errors="replace").strip())
        return r.stdout

    def judge(self, changes, writes, feature, implement):
        refused = []
        # A judgment row may name a protected file exactly (specify's
        # .specify/feature.json); a pattern never opens the protected set.
        exact = {w.replace("<f>", feature) for w in writes if not any(c in w for c in "*?[")}
        for status, mode, path in changes:
            if protected(path) and (implement or path not in exact):
                refused.append(f"{path}: in the protected set")
                continue
            if not implement and not allowed(path, writes, feature):
                refused.append(f"{path}: outside this step's writes")
                continue
            if status != "D" and mode not in ("100644", "100755"):
                refused.append(f"{path}: mode {mode} (a symlink, submodule or unusual mode)")
                continue
            landing = self.landing(path)
            if landing:
                refused.append(f"{path}: {landing}")
        if refused:
            raise PassFailed("judge refused the patch:\n  " + "\n  ".join(refused))
        flagged = {"check_changes": [], "automation_changes": []}
        # Every path the frozen check command names; only those, and its
        # callees are not followed (research R20, accepted: the review reads
        # the whole diff).
        command = load(os.path.join(self.run.dir, "check.json"))["command"]
        check_paths = {os.path.normpath(t) for t in command.split() if not t.startswith("-")}
        hooks = self.run.git("config", "--local", "--get", "core.hooksPath", check=False).stdout.decode().strip()
        hooks = os.path.normpath(hooks) + "/" if hooks and not os.path.isabs(hooks) else ""
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
                if path in check_paths:
                    flagged["check_changes"].append(path)
                if AUTOMATION.match(path) or (hooks and (path + "/").startswith(hooks)) or mode == "100755":
                    flagged["automation_changes"].append(path)
        return flagged

    def landing(self, path):
        """Why writing path into the owner's worktree would land somewhere
        else than the repository's tracked tree, or None. git apply follows
        an untracked symlink in the worktree, and writes into ignored
        directories (.venv/, node_modules/) as readily (review of Phase 2,
        proved)."""
        here = self.run.repo
        parts = path.split("/")
        for part in parts[:-1]:
            here = os.path.join(here, part)
            if os.path.islink(here):
                return "the worktree has a symlink on its way"
        # The path itself may be a symlink only if the repository tracks it:
        # git then replaces or deletes the link, and never writes through it.
        if os.path.islink(os.path.join(self.run.repo, path)) and self.run.git(
                "ls-files", "--error-unmatch", "--", path, check=False).returncode != 0:
            return "an untracked symlink in the worktree"
        # check-ignore refuses literal pathspecs (exit 128), so it runs without
        # them; any answer but "ignored" (0) or "not ignored" (1) fails closed.
        env = {k: v for k, v in HOST_ENV.items() if k != "GIT_LITERAL_PATHSPECS"}
        # Without --no-index, a tracked file an ignore rule matches is not
        # ignored, as it is not to git; "./" keeps a name like ":(exclude)x"
        # a name rather than pathspec magic.
        r = subprocess.run([GIT, "-C", self.run.repo, *GIT_OFF, "check-ignore", "-q", "--", "./" + path],
                           env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.run.dir)
        if r.returncode == 0:
            return "an ignored path in the worktree"
        if r.returncode != 1:
            raise PassFailed("judge: git check-ignore failed: " + r.stderr.decode(errors="replace").strip())
        return None

    def scan(self, changes, blobs, agent):
        """The exact value of every credential of the run, in each changed
        file's bytes as the agent left them (a patch encodes binaries) and in
        what the agent returned. Fails closed: a credential that cannot be
        read cannot be looked for."""
        services = {"claude-oauth"}
        if agent == "pi" or load(os.path.join(self.run.dir, "optin.json")).get("implement") == "deepseek":
            services.add("deepseek-api")
        files = []
        for status, _, path in changes:
            if status != "D":
                with open(os.path.join(self.export, path), "rb") as f:
                    files.append(f.read())
        for service in sorted(services):
            value = self.run.secret(service).encode()
            if any(value in blob for blob in files + blobs):
                raise PassFailed(f"the output holds the exact value of the credential {service}; nothing applied")

    # 7. Apply
    def apply(self, patch, paths, message):
        self.run.git("apply", "-p1", "--index", "--whitespace=nowarn", input=patch)
        # Only the patch's paths: the owner's own staged work stays staged.
        self.run.git("commit", "-q", "-m", message, "--pathspec-from-file=-", "--pathspec-file-nul",
                     input="\0".join(paths).encode())
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


def stage_outcome(run, feature, step, fields):
    """Validates an outcome against its schema into a file beside its place,
    and returns the move that puts it there: a pass validates before it
    applies anything, so an invalid outcome leaves no commit behind."""
    path = os.path.join(run.repo, feature, ".sdd", f"{step}.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    doc = {"schema": f"urn:dotfiles:sdd:{step}:1", "step": step, "at": now(), **fields}
    tmp = os.path.join(run.dir, f"{step}.outcome.json")
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1)
    schema = os.path.join(DOTFILES, "claude", "speckit", "schemas", f"{step}.schema.json")
    r = subprocess.run([run.tool("check-jsonschema"), "--schemafile", schema, tmp], env=HOST_ENV,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=run.dir)
    if r.returncode != 0:
        os.remove(tmp)
        raise PassFailed(f"the {step} outcome does not match its schema: {r.stdout.decode(errors='replace')[-400:]}")
    def place(**fields_known_later):
        # Fields only the apply can give (implement's commit, a git object
        # id); everything the agent supplied was validated above.
        if fields_known_later:
            doc.update(fields_known_later)
            with open(tmp, "w") as f:
                json.dump(doc, f, indent=1)
        shutil.move(tmp, path)

    return place


def write_outcome(run, feature, step, fields):
    stage_outcome(run, feature, step, fields)()


def run_agent(run, phase, implement=None):
    """One agent pass. For an implement pass, `implement` holds the fields
    of implement.json the caller knows (agent, pi_version): the record is
    validated, and the check and automation flags kept, before anything is
    applied, so no failure after the commit can lose either (review of
    Phase 2, second round)."""
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
                f.write(run.git("diff", "--no-ext-diff", "--no-textconv", "--binary", run.lock["base"], "HEAD").stdout)
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
        p.scan(changes, [text.encode(), json.dumps(structured).encode()], row["agent"])
        place_outcome = None
        if structured is not None and row.get("schema"):
            place_outcome = stage_outcome(run, feature, row["schema"], structured)
        if implement:
            place_outcome = stage_outcome(run, feature, "implement", dict(
                implement, model=served, commit=None, files=[c[2] for c in changes], usage=usage,
                seconds=round(time.time() - started, 1)))
            keep_flags(run, flagged)
        commit = None
        if changes:
            step = "implement" if implement else phase
            commit = p.apply(patch, [c[2] for c in changes], f"{step}: {os.path.basename(feature)} ({served})")
        if place_outcome:
            place_outcome(**({"commit": commit} if implement else {}))
        if row.get("result_to"):
            with open(os.path.join(run.repo, feature, row["result_to"]), "w") as f:
                f.write(text)
        return {"changes": changes, "commit": commit, "usage": usage, "served": served, "flagged": flagged,
                "seconds": round(time.time() - started, 1), "row": row}
    finally:
        p.cleanup()


def keep_flags(run, flagged):
    """Adds a pass's check and automation changes to those the next verify
    reports (FR-029, FR-030)."""
    flags = os.path.join(run.dir, "flags.json")
    acc = load(flags) if os.path.exists(flags) else {"check_changes": [], "automation_changes": []}
    for k in acc:
        acc[k] = sorted(set(acc[k]) | set(flagged[k]))
    with open(flags, "w") as f:
        json.dump(acc, f)


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
    pi_version = load(os.path.join(run.dir, "routing.json"))["versions"].get("pi") if agent == "deepseek" else None
    r = run_agent(run, phase, implement={"agent": agent, "pi_version": pi_version})
    print(f"{phase}: {len(r['changes'])} files changed" + (f", commit {r['commit'][:12]}" if r["commit"] else ", no change"))


def verify(run):
    feature = feature_dir(run.repo)
    command = load(os.path.join(run.dir, "check.json"))["command"]
    p = Pass(run, "verify")
    try:
        p.prepare(feature)
        p.admit(["registries"])
        code, out, err = p.container(["sh", "-c", command], {}, [f"{p.inputs}:/bundle:ro", p.cache("verify")], 3300)
    finally:
        p.cleanup()
    flags = os.path.join(run.dir, "flags.json")
    acc = load(flags) if os.path.exists(flags) else {"check_changes": [], "automation_changes": []}
    tail = "\n".join((out + err).splitlines()[-200:])
    write_outcome(run, feature, "verify", {"command": command, "exit": code, "tail": tail, **acc})
    if os.path.exists(flags):
        os.remove(flags)
    print("pass" if code == 0 else "fail")


def prepare_worker(run):
    """Builds the worker image once per content of containers/worker/, so no
    pass's limit pays for a build, and records its tag in the bundle."""
    ctx = os.path.join(DOTFILES, "containers", "worker")
    h = hashlib.sha256()
    for root, dirs, files in os.walk(ctx):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            h.update(os.path.relpath(full, ctx).encode() + b"\0")
            with open(full, "rb") as f:
                h.update(f.read() + b"\0")
    tag = f"sdd-worker:{h.hexdigest()[:12]}"
    rt = run.tool("container")
    present = subprocess.run([rt, "image", "inspect", tag], env=HOST_ENV, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, cwd=run.dir).returncode == 0
    if not present:
        r = subprocess.run([rt, "build", "-t", tag, "-f", os.path.join(ctx, "Containerfile"), ctx], env=HOST_ENV,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=run.dir)
        if r.returncode != 0:
            raise PassFailed("building the worker image failed:\n" + r.stdout.decode(errors="replace")[-1500:])
        verify_inventory(run, rt, tag, ctx)
    with open(os.path.join(run.dir, "worker.json"), "w") as f:
        json.dump({"image": tag}, f)
    prune_workers(run, rt, tag)
    print(tag)


def verify_inventory(run, rt, tag, ctx):
    """Refuses a fresh build whose installed packages differ from the
    inventory committed beside its recipe (FR-032, research R26): every
    input is pinned, so a difference means an input moved. The refused image
    is deleted, because an image present under its tag is one this check
    accepted, and the next prepare-worker would otherwise use it unchecked."""
    r = subprocess.run([rt, "run", "--rm", "--entrypoint", "/usr/local/lib/sdd/inventory.sh", tag], env=HOST_ENV,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=run.dir)
    built = r.stdout.decode(errors="replace").splitlines() if r.returncode == 0 else None
    with open(os.path.join(ctx, "inventory.txt")) as f:
        committed = f.read().splitlines()
    if built == committed:
        return
    subprocess.run([rt, "image", "delete", tag], env=HOST_ENV, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, cwd=run.dir)
    if built is None:
        raise PassFailed("reading the built image's inventory failed: " + r.stderr.decode(errors="replace").strip()[-500:])
    added = sorted(set(built) - set(committed))
    missing = sorted(set(committed) - set(built))
    raise PassFailed("the built worker image differs from containers/worker/inventory.txt; refused and deleted:\n"
                     + "".join(f"  + {line}\n" for line in added) + "".join(f"  - {line}\n" for line in missing)
                     + "  An input moved: pin it, or regenerate the inventory on purpose (containers/worker/inventory.sh).")


def prune_workers(run, rt, current):
    """Deletes the worker images a change of containers/worker/ superseded.
    Kept: the current one, and the one every unfinished run uses — paused
    runs included, whose process is gone but which resume on their image —
    in this repository's .git/sdd/ and in every run `sdd-run start`
    registered in ~/.local/state/sdd/runs/, so a run in another repository
    keeps its image too (review of Phase 2, second round). A run is finished
    once sdd-run writes finished.json into its bundle."""
    registry = os.path.join(HOST_ENV["HOME"], ".local", "state", "sdd", "runs")
    root = os.path.dirname(run.dir)
    bundles = [os.path.join(root, rid) for rid in os.listdir(root)]
    if os.path.isdir(registry):
        bundles += [os.path.realpath(os.path.join(registry, rid)) for rid in os.listdir(registry)]
    keep = {current}
    for bundle in bundles:
        if os.path.exists(os.path.join(bundle, "finished.json")):
            continue
        try:
            keep.add(load(os.path.join(bundle, "worker.json"))["image"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
    r = subprocess.run([rt, "image", "list", "--format", "json"], env=HOST_ENV, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, cwd=run.dir)
    try:
        names = [i["configuration"]["name"] for i in json.loads(r.stdout or "[]")]
    except (ValueError, KeyError, TypeError):
        return
    for name in names:
        short = name.split("/")[-1]
        if re.fullmatch(r"sdd-worker:[0-9a-f]{12}", short) and short not in keep:
            subprocess.run([rt, "image", "delete", name], env=HOST_ENV, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, cwd=run.dir)


# Registries a pass may read only part of (FR-031, research R25): on
# github.com, release assets and source archives -- what mise and pinned
# downloads fetch -- and nothing else, no repository page, API or push.
REGISTRY_PATHS = {"github.com": r"^/[^/]+/[^/]+/(releases/download|archive)/"}


def egress_proxy(run):
    """Runs the run's egress proxy until it stops (contracts/pass.md): its own
    container on a network made for the run, the credentials written to its
    stdin and nowhere else, the admissions directory mounted read-only. Records
    where agents reach it, and the model behind each DeepSeek id, in the
    bundle; removes the network when the proxy is gone."""
    rt = run.tool("container")
    net, name = f"sdd-{run.id}", f"sdd-{run.id}-proxy"
    admissions = os.path.join(run.dir, "admissions")
    os.makedirs(admissions, exist_ok=True)
    # sdd-run touches this while it lives; the proxy exits a minute after it stops.
    with open(os.path.join(admissions, "heartbeat"), "w") as f:
        f.write(now())
    # The proxy runs from the bundle's copy, like everything else that governs a run.
    code_dir = os.path.join(run.dir, "proxy")
    os.makedirs(code_dir, exist_ok=True)
    shutil.copy(os.path.join(DOTFILES, "bin", "sdd-egress-proxy.py"), code_dir)
    image = load(os.path.join(run.dir, "worker.json"))["image"]
    host = lambda *a: subprocess.run([rt, *a], env=HOST_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=run.dir)
    r = host("network", "create", net)
    if r.returncode != 0 and net not in host("network", "list", "-q").stdout.decode().split():
        raise PassFailed("creating the run's network failed: " + r.stderr.decode(errors="replace").strip())
    deepseek = load(os.path.join(run.dir, "optin.json")).get("implement") == "deepseek"
    providers = {"anthropic": {"upstream": "https://api.anthropic.com", "credential": run.secret("claude-oauth")}}
    if deepseek:
        providers["deepseek"] = {"upstream": "https://api.deepseek.com", "credential": run.secret("deepseek-api"),
                                 "models": "/models"}
    with open(os.path.join(DOTFILES, "containers", "worker", "egress-registries.txt")) as f:
        registries = [l.split("#")[0].strip() for l in f if l.split("#")[0].strip()]
    start = json.dumps({"listen": "0.0.0.0:8080", "admissions": "/admissions", "heartbeat_seconds": 60,
                        "providers": providers, "registries": registries, "paths": REGISTRY_PATHS})
    del providers
    proc = subprocess.Popen([rt, "run", "--rm", "-i", "--name", name, "--label", f"sdd.run={run.id}",
                             "--network", net, "-v", f"{admissions}:/admissions:ro", "-v", f"{code_dir}:/proxy:ro",
                             "--entrypoint", "python3", image, "-I", "/proxy/sdd-egress-proxy.py"],
                            env=HOST_ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=run.dir)

    def stop(*_):
        subprocess.run([rt, "stop", name], env=HOST_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       cwd=run.dir)

    signal.signal(signal.SIGTERM, lambda *_: (stop(), sys.exit(0)))
    try:
        proc.stdin.write(start.encode() + b"\n")
        proc.stdin.close()
        del start
        ready = json.loads(proc.stdout.readline() or "null") or {}
        if "api_port" not in ready:
            raise PassFailed("the egress proxy did not start")
        info = json.loads(host("inspect", name).stdout or "[]")
        address = info[0]["status"]["networks"][0]["ipv4Address"].split("/")[0]
        routing_path = os.path.join(run.dir, "routing.json")
        routing = load(routing_path)
        listed = (ready.get("models") or {}).get("deepseek") or {}
        names = {m.get("id"): m.get("name", m.get("id")) for m in listed.get("data", [])} if isinstance(listed, dict) else {}
        for row in run.rows.values():
            if row["agent"] == "pi" and row["model"] in names:
                routing["served"][row["model"]] = names[row["model"]]
        with open(routing_path, "w") as f:
            json.dump(routing, f, indent=1)
        if not str(ready.get("ca", "")).startswith("-----BEGIN CERTIFICATE-----"):
            raise PassFailed("the egress proxy printed no certificate authority")
        with open(os.path.join(run.dir, "proxy-ca.pem"), "w") as f:
            f.write(ready["ca"])
        with open(os.path.join(run.dir, "proxy.json"), "w") as f:
            json.dump({"address": address, "port": ready["api_port"]}, f)
        proc.wait()
    finally:
        stop()
        proc.wait()
        for leftover in ("proxy.json", "proxy-ca.pem"):
            try:
                os.remove(os.path.join(run.dir, leftover))
            except OSError:
                pass
        host("network", "delete", net)


def process_alive(lock):
    """The lock's process exists and is the one that wrote it: same pid, same
    start time as `ps` prints it, so a reused pid does not keep a dead run."""
    try:
        os.kill(int(lock["pid"]), 0)
    except (OSError, ValueError, KeyError):
        return False
    r = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(lock["pid"])], env=HOST_ENV,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return r.stdout.decode().strip() == str(lock.get("started", "")).strip()


def cleanup(run, only=None):
    """Removes what a run left behind — its containers, cache volumes, network,
    exports and admissions — for the run named, or for every run whose lock
    names a process that is gone."""
    root = os.path.dirname(run.dir)
    rt = run.tool("container")
    host = lambda *a: subprocess.run([rt, *a], env=HOST_ENV, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=run.dir)
    dead = []
    for rid in sorted(os.listdir(root)):
        lock_path = os.path.join(root, rid, "lock.json")
        if only and rid != only:
            continue
        try:
            lock = load(lock_path)
        except (OSError, ValueError):
            lock = {}
        if only or not process_alive(lock):
            dead.append(rid)
    try:
        containers = json.loads(host("list", "--all", "--format", "json").stdout or "[]")
    except ValueError:
        containers = []
    volumes = host("volume", "list", "-q").stdout.decode().split()
    for rid in dead:
        for c in containers:
            conf = c.get("configuration", {})
            if (conf.get("labels") or {}).get("sdd.run") == rid:
                host("stop", conf["id"])
                host("delete", "--force", conf["id"])
                print(f"container {conf['id']}")
        for v in volumes:
            if v in (f"sdd-cache-implement-{rid}", f"sdd-cache-verify-{rid}"):
                host("volume", "delete", v)
                print(f"volume {v}")
        host("network", "delete", f"sdd-{rid}")
        d = os.path.join(root, rid)
        if os.path.isdir(os.path.join(d, "passes")) and os.listdir(os.path.join(d, "passes")):
            shutil.rmtree(os.path.join(d, "passes"))
            print(f"exports of {rid}")
        adm = os.path.join(d, "admissions")
        for name in os.listdir(adm) if os.path.isdir(adm) else []:
            if name.endswith(".json"):
                os.remove(os.path.join(adm, name))


def main():
    if len(sys.argv) < 3:
        print("usage: sdd-pass.py <agent PHASE|implement|verify|prepare-worker|egress-proxy|cleanup [RUN]> REPO",
              file=sys.stderr)
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
        elif what == "prepare-worker":
            prepare_worker(run)
        elif what == "egress-proxy":
            egress_proxy(run)
        elif what == "cleanup":
            cleanup(run, sys.argv[2] if len(sys.argv) > 3 else None)
        else:
            raise PassFailed(f"unknown pass {what}")
    except PassFailed as e:
        print(f"sdd-step: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
