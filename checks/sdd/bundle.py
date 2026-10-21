"""Writes the run bundle and repository the contained-pass checks run against.

Usage: bundle.py <scratch dir> <dotfiles root> [<rows.json>]

With <rows.json> — routing.yml's phases as JSON — the bundle carries those
rows, every value from the defaults layer, and the real profiles; without
it, the synthetic rows below.

The bundle is what `sdd-run start` would leave in $SDD_RUN_DIR: the frozen
routing table, profiles, the config-guard copy, the check command, the opt-in,
the lock with the run's base commit, the worker image tag, and tools.json
pointing the container runtime and the Keychain at the stand-ins in
<scratch>/standins. Values are synthetic; the rows mirror contracts/routing.md.
"""

import json
import os
import shutil
import sys

tmp, dotfiles = sys.argv[1], sys.argv[2]
run = os.path.join(tmp, "repo", ".git", "sdd", "run1")
os.makedirs(os.path.join(run, "profiles"))
os.makedirs(os.path.join(run, "hooks"))


def row(agent, model, profile, writes, timeout=30, schema=None, result_to=None, prompt="/speckit-plan"):
    r = {"agent": agent, "model": model, "effort": "medium" if agent == "claude" else "high",
         "prompt": prompt, "writes": writes, "timeout": timeout, "max_timeout": 7200}
    if profile:
        r["profile"] = profile
    if schema:
        r["schema"] = schema
    if result_to:
        r["result_to"] = result_to
    return r


EVERYTHING = ["**"]
rows = {
    "plan": row("claude", "claude-opus-5-5", "author", ["<f>/plan.md", "<f>/contracts/**"]),
    "analyze": row("claude", "claude-opus-5-5", "reader", [], result_to="analysis.md", prompt="/speckit-analyze"),
    "review": row("claude", "claude-opus-5-5", "reader", [], schema="review", prompt="/speckit-review"),
    "implement-sonnet": row("claude", "claude-sonnet-5-5", "implementer", EVERYTHING, prompt="/speckit-implement"),
    "implement-deepseek": row("pi", "deepseek-flash", None, EVERYTHING, prompt="/speckit-implement"),
}
if len(sys.argv) > 3:
    with open(sys.argv[3]) as f:
        rows = json.load(f)["phases"]
routing = {
    "schema": "urn:dotfiles:sdd:routing:1", "step": "routing", "at": "2026-10-21T14:00:00Z",
    "versions": {"speckit": "1.2.2", "claude_code": "2.1.306", "container": "1.6.0", "pi": "1.3.0"},
    "served": {"deepseek-flash": "DeepSeek-V4.1-Flash"},
    "phases": {p: {k: {"value": v, "layer": "defaults"} for k, v in r.items()} for p, r in rows.items()},
}
standins = os.path.join(tmp, "standins")
files = {
    "routing.json": routing,
    "tools.json": {
        "container": os.path.join(standins, "container"),
        "security": os.path.join(standins, "security"),
        "check-jsonschema": shutil.which("check-jsonschema"),
    },
    "check.json": {"command": "./check-app.sh"},
    "optin.json": {"implement": "deepseek"},
    "worker.json": {"image": "sdd-worker:0123456789ab"},
    "proxy.json": {"address": "192.0.2.10", "port": 8080},
}
for name, doc in files.items():
    with open(os.path.join(run, name), "w") as f:
        json.dump(doc, f, indent=1)
for profile in ("author", "reader", "implementer"):
    if len(sys.argv) > 3:
        shutil.copy(os.path.join(dotfiles, "claude", "speckit", "profiles", profile + ".json"),
                    os.path.join(run, "profiles", profile + ".json"))
        continue
    with open(os.path.join(run, "profiles", profile + ".json"), "w") as f:
        json.dump({"permissions": {"allow": ["Read"]}, "_profile": profile}, f)
shutil.copy(os.path.join(dotfiles, "claude", "config-guard.sh"), os.path.join(run, "hooks", "config-guard.sh"))
for name in ("brief.md", "pi-models.json", "egress-registries.txt"):
    shutil.copy(os.path.join(dotfiles, "claude", "speckit", name), os.path.join(run, name))
# The authority the egress proxy printed, as egress-proxy writes it.
with open(os.path.join(run, "proxy-ca.pem"), "w") as f:
    f.write("-----BEGIN CERTIFICATE-----\nfixture run authority\n-----END CERTIFICATE-----\n")
print(run)
