"""Writes the schema cases checks/91-sdd-routing.sh validates.

For every schema in claude/speckit/schemas/: one valid sample, and three
variants of it that must be refused — a required field dropped, a field the
schema does not know added, an enum field given a value outside its enum.
Each case is written as <schema>.<case>.json into the directory given; the
samples live here rather than as files so each bad variant is visibly one edit
away from a sample that passes.
"""

import copy
import json
import sys

AT = "2026-10-21T14:00:00Z"


def outcome(step, **fields):
    return {"schema": f"urn:dotfiles:sdd:{step}:1", "step": step, "at": AT, **fields}


FINDINGS = [
    {"severity": "HIGH", "text": "the parser drops the last line", "path": "src/parse.py"},
    {"severity": "LOW", "text": "a name could be clearer"},
]

ROW = {
    "agent": "claude",
    "model": "claude-opus-5-5",
    "effort": "medium",
    "profile": "author",
    "prompt": "/speckit-plan",
    "writes": ["<f>/plan.md"],
    "timeout": 3600,
    "max_timeout": 7200,
}
PI_ROW = {
    "agent": "pi",
    "model": "deepseek-flash",
    "effort": "high",
    "prompt": "/speckit-implement",
    "writes": ["**"],
    "timeout": 1800,
    "max_timeout": 3600,
}
PHASES = [
    "specify", "clarify-ask", "clarify-apply", "plan", "checklist", "checklist-review", "analyze",
    "tasks", "implement-deepseek", "implement-sonnet", "review", "converge",
]
TABLE = {"phases": {p: copy.deepcopy(PI_ROW if p == "implement-deepseek" else ROW) for p in PHASES}}

# name: (valid sample, path of a required field, path of an enum field)
CASES = {
    "routing-table": (TABLE, ["phases", "plan", "model"], ["phases", "plan", "effort"]),
    "routing-layer": (
        {"phases": {"plan": {"model": "claude-sonnet-5-5", "effort": "high", "timeout": 900}}},
        ["phases"],
        ["phases", "plan", "effort"],
    ),
    "route": (outcome("route", agent="deepseek"), ["agent"], ["agent"]),
    "routing": (
        outcome(
            "routing",
            versions={"speckit": "1.2.2", "claude_code": "2.1.306", "container": "1.6.0", "pi": "1.3.0"},
            served={"deepseek-flash": "DeepSeek-V4.1-Flash"},
            phases={"plan": {"model": {"value": "claude-opus-5-5", "layer": "defaults"},
                             "effort": {"value": "high", "layer": "set"}}},
        ),
        ["versions"],
        ["phases", "plan", "effort", "layer"],
    ),
    "phases": (outcome("phases", done=[{"phase": "specify", "at": AT}]), ["done"], ["done", 0, "phase"]),
    "clarify": (outcome("clarify", questions=3), ["questions"], ["step"]),
    "implement": (
        outcome(
            "implement", agent="deepseek", model="deepseek-flash", pi_version="1.3.0",
            commit="4e52f7c0000000000000000000000000000000aa", files=["src/parse.py"],
            usage={"input": 1200, "cached": 800, "output": 300}, seconds=42.5,
        ),
        ["model"],
        ["agent"],
    ),
    "verify": (
        outcome("verify", command="./check.sh", exit=1, tail="FAIL parse", check_changes=[],
                automation_changes=[".github/workflows/ci.yml"]),
        ["exit"],
        ["step"],
    ),
    "review": (outcome("review", findings=FINDINGS, done=["T012", "T013"]), ["findings"], ["findings", 0, "severity"]),
    "converge": (outcome("converge", outcome="converged", findings=FINDINGS[1:]), ["outcome"], ["outcome"]),
}


def at(doc, path):
    for key in path[:-1]:
        doc = doc[key]
    return doc, path[-1]


def main(out):
    for name, (sample, required, enum) in CASES.items():
        variants = {"valid": sample}
        missing = copy.deepcopy(sample)
        parent, key = at(missing, required)
        del parent[key]
        variants["missing"] = missing
        extra = copy.deepcopy(sample)
        # Added beside the required field, so a schema that closes only its
        # top level is caught one level down too.
        parent, _ = at(extra, required)
        parent["unexpected"] = 1
        variants["extra"] = extra
        wrong = copy.deepcopy(sample)
        parent, key = at(wrong, enum)
        parent[key] = "not-in-the-enum"
        variants["enum"] = wrong
        for case, doc in variants.items():
            with open(f"{out}/{name}.{case}.json", "w") as f:
                json.dump(doc, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
