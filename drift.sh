#!/usr/bin/env bash
# What this machine has that the Brewfile does not declare, and the reverse.
#
# Usage:  ./drift.sh
#
# Deliberately NOT part of check.sh, and not run by CI. Every check in there has
# to mean the same thing on a runner as on your laptop, which is what makes a
# green tick worth trusting. This one cannot: a GitHub runner arrives with its
# own preinstalled packages, so "installed but undeclared" is always true there
# and never interesting. Putting it in check.sh would either break CI forever or
# force an `if [ -z "$CI" ]` around it -- a check that skips itself on the only
# machine that runs it automatically.
#
# So it lives here, next to bump-tools.sh, as something you run on the machine
# the Brewfile is supposed to describe.
#
# `brew bundle check` cannot answer this on its own. It asks whether everything
# declared is installed -- a question a subset always answers yes to. The gap it
# leaves is everything installed and never written down, which is the direction
# drift actually grows in.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

FAILED=0
GREEN=$'\033[32m'
RED=$'\033[31m'
DIM=$'\033[90m'
OFF=$'\033[0m'

# Entries of one kind from the Brewfile, sorted for comm.
declared() { grep -oE "^$1 \"[^\"]+\"" Brewfile | sed "s/^$1 \"//; s/\"\$//" | sort; }

report() {
  local title=$1 hint=$2 items=$3
  if [ -z "$items" ]; then
    printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$title"
  else
    printf '  %sDRIFT%s %s\n' "$RED" "$OFF" "$title"
    printf '%s\n' "$items" | sed 's/^/         /'
    printf '         %s%s%s\n' "$DIM" "$hint" "$OFF"
    FAILED=1
  fi
}

printf '\n%sInstalled but not declared%s\n' "$DIM" "$OFF"

# Only formulae installed on request. Dependencies are noise: they are here
# because something else needed them, not because anyone chose them, and listing
# them buries the handful that a person actually has to decide about.
report "formulae" "add to the Brewfile, or: brew uninstall <name>" \
  "$(comm -23 <(brew leaves --installed-on-request | sort) <(declared brew))"

report "casks" "add to the Brewfile, or: brew uninstall --cask <name>" \
  "$(comm -23 <(brew list --cask | sort) <(declared cask))"

# VS Code extensions are the third thing `brew bundle` manages and the easiest
# to accumulate by accident: they install from inside the editor, where nothing
# suggests writing them down.
#
# Only the ones chosen directly, for the same reason the formulae above use
# `brew leaves`. An extension VS Code installed on another one's behalf is not a
# decision anybody made, and listing it is the difference between a report you
# act on and one you learn to scroll past -- ms-toolsai.jupyter alone brings
# four, and the C++ pack brings four more. The relationship is declared by the
# parent, in package.json: extensionPack for a bundle, extensionDependencies for
# a hard requirement.
vscode_leaves() {
  python3 - << 'PY'
import glob
import json
import os
import subprocess

installed = {
    line.strip().lower()
    for line in subprocess.run(
        ['code', '--list-extensions'],
        capture_output=True, text=True, check=True).stdout.splitlines()
    if line.strip()
}

manifests = glob.glob(os.path.expanduser('~/.vscode/extensions/*/package.json'))
if not manifests and installed:
    # Never degrade quietly into "no parents found, so everything is a leaf":
    # that reads exactly like a clean report with more rows.
    print('cannot read ~/.vscode/extensions, so parents are unknown')

pulled = set()
for path in manifests:
    try:
        with open(path, encoding='utf-8') as handle:
            meta = json.load(handle)
    except (OSError, ValueError):
        continue
    publisher, name = meta.get('publisher'), meta.get('name')
    if not publisher or ('%s.%s' % (publisher, name)).lower() not in installed:
        continue
    children = (meta.get('extensionPack') or []) + \
               (meta.get('extensionDependencies') or [])
    pulled.update(child.lower() for child in children)

for extension in sorted(installed - pulled):
    print(extension)
PY
}

if command -v code > /dev/null 2>&1; then
  report "vscode extensions" "add to the Brewfile, or uninstall in the editor" \
    "$(comm -23 <(vscode_leaves) <(declared vscode | tr '[:upper:]' '[:lower:]'))"
else
  printf '  %sDRIFT%s vscode extensions %s(code not on PATH)%s\n' "$RED" "$OFF" "$DIM" "$OFF"
  FAILED=1
fi

printf '\n%sDeclared but not installed%s\n' "$DIM" "$OFF"

missing=$(brew bundle check --file=Brewfile --verbose 2>&1 | sed -n 's/^→ //p')
report "Brewfile is satisfied" "brew bundle install --file=Brewfile" "$missing"

printf '\n%sClaude Code%s\n' "$DIM" "$OFF"

# settings.json is merged rather than symlinked, because Claude Code rewrites it
# on its own -- install.sh explains that choice. What the merge does not do is
# look back: the repo's values land on top, and nothing reports what Claude Code
# added underneath. That is the same one-directional blindness that lets
# `brew bundle check` pass on a subset, and it is how eight keys accumulated in
# there before anyone noticed.
claude_settings_drift() {
  python3 - << 'PY'
import json
import os

# Keys that belong to this machine, listed rather than inferred. Putting one
# here is a decision recorded in the repo -- "local on purpose" -- not a way to
# quiet the report. Anything absent from both this list and the repo's settings
# is a choice someone made in /config and never wrote down.
LOCAL_ONLY = {
    # Command strings holding absolute paths that exist on this machine only.
    'hooks',
    # One entry points at a local directory, and no enabled plugin comes from
    # the other two, so versioning them would add surface and no reproducibility.
    'extraKnownMarketplaces',
    # Split ownership: the repo owns `deny`, while `allow` accumulates per
    # project (domains, MCP tools) and does not transfer to another machine.
    'permissions',
    # Not a preference: the schema calls it "whether the user has accepted the
    # bypass permissions mode dialog", managed by the CLI. Versioning it would
    # pre-accept that dialog on every new machine, which is the one thing it
    # exists to prevent. The policy lives in permissions.disableBypassPermissionsMode
    # instead, where it is a decision rather than a record of a click.
    'skipDangerousModePermissionPrompt',
}

live_path = os.path.expanduser('~/.claude/settings.json')

try:
    with open(live_path, encoding='utf-8') as handle:
        live = json.load(handle)
except (OSError, ValueError) as err:
    print('cannot read %s (%s)' % (live_path, err))
    raise SystemExit(0)

with open('claude/settings.json', encoding='utf-8') as handle:
    repo = json.load(handle)

for key in sorted(set(live) - set(repo) - LOCAL_ONLY):
    value = json.dumps(live[key])
    print('%s = %s' % (key, value if len(value) <= 60 else value[:57] + '...'))


def enabled(plugins):
    # Only the ones switched on. A `false` entry is a plugin someone tried and
    # turned off, which is a non-decision: carrying it to another machine would
    # install it in order to disable it. Comparing the whole object instead
    # would report drift forever, because the merge keeps those entries here.
    return {name for name, on in (plugins or {}).items() if on}


for key in sorted(set(repo) & set(live)):
    if key in LOCAL_ONLY:
        continue
    if key == 'enabledPlugins':
        missing = enabled(repo[key]) - enabled(live[key])
        extra = enabled(live[key]) - enabled(repo[key])
        for name in sorted(extra):
            print('plugin enabled but not declared: %s' % name)
        for name in sorted(missing):
            print('plugin declared but not enabled: %s' % name)
    # A repo value the merge did not win means the merge silently did nothing.
    elif live[key] != repo[key]:
        print('%s: repo says %s, this machine has %s'
              % (key, json.dumps(repo[key])[:40], json.dumps(live[key])[:40]))
PY
}
report "settings.json declares every choice" \
  "add it to claude/settings.json, or drop it with /config" \
  "$(claude_settings_drift)"

printf '\n%suv tools%s\n' "$DIM" "$OFF"

# The same question the Brewfile section asks, for the package manager that has
# no `brew bundle check` of its own. uv-tools.txt is the declaration; this reads
# the receipts uv writes under `uv tool dir` and compares them.
#
# Receipts rather than `uv tool list`, for two reasons. They carry the reference a
# tool was installed from, so a pin that moved is visible and not just a version
# that happens to match; and `uv tool list` mixes warnings about broken tools into
# the same stream it lists working ones on, which is a parser waiting to be wrong
# about which is which.
#
# It also asks whether each installed tool still runs. A `uv tool` environment
# borrows its base interpreter rather than copying it, so removing that
# interpreter leaves the command on PATH and dead -- `bad interpreter` on a tool
# nothing in this repo touched. Nothing else here would report that: the tool is
# installed, declared, at the right version, and does not work.
uv_tools_drift() {
  python3 - << 'PY'
import os
import re
import subprocess

try:
    import tomllib
except ModuleNotFoundError:
    # Never fall through to "no receipts found, so nothing is installed": that
    # reads exactly like a clean report.
    print('cannot read uv receipts: tomllib needs python 3.11 or newer')
    raise SystemExit(0)

problems = []


def declared():
    """name -> (kind, url_or_none, rev_or_none) from uv-tools.txt."""
    out = {}
    with open('uv-tools.txt', encoding='utf-8') as handle:
        for line in handle:
            fields = line.split('#')[0].split()
            if not fields:
                continue
            name, ref = fields[0], fields[1] if len(fields) > 1 else ''
            out[name] = parse_ref(ref)
    return out


def parse_ref(ref):
    if ref.startswith('git+'):
        url, _, rev = ref[len('git+'):].rpartition('@')
        return ('git', url, rev)
    # A bare name resolves to PyPI. `name==1.2.3` pins it there.
    return ('pypi', None, ref.partition('==')[2] or None)


def installed(tool_dir):
    out = {}
    for name in sorted(os.listdir(tool_dir)):
        receipt = os.path.join(tool_dir, name, 'uv-receipt.toml')
        if not os.path.isfile(receipt):
            continue
        with open(receipt, 'rb') as handle:
            data = tomllib.load(handle)
        requirements = data.get('tool', {}).get('requirements', [])
        # The requirement whose name matches the directory is the tool itself;
        # anything else is a `--with` extra and not what was asked for.
        for requirement in requirements:
            if requirement.get('name') != name:
                continue
            git = requirement.get('git')
            if git:
                # uv rewrites `git+URL@REV` as `URL?rev=REV` in the receipt, so
                # the two spellings have to be normalised before comparing.
                url, _, rev = git.partition('?rev=')
                out[name] = (('git', url, rev), data)
            else:
                specifier = requirement.get('specifier') or ''
                pinned = re.sub(r'^==', '', specifier) or None
                out[name] = (('pypi', None, pinned), data)
            break
    return out


def broken_entrypoints(name, data):
    """Entrypoints that exist but cannot execute."""
    for entry in data.get('tool', {}).get('entrypoints', []):
        path = entry.get('install-path')
        if not path:
            continue
        if not os.path.exists(path):
            problems.append('%s: %s is declared as its command and is missing'
                            % (name, path))
            continue
        try:
            with open(path, 'rb') as handle:
                first = handle.readline()
        except OSError as err:
            problems.append('%s: cannot read %s (%s)' % (name, path, err))
            continue
        if not first.startswith(b'#!'):
            continue
        words = first[2:].decode('utf-8', 'replace').split()
        # `#!/usr/bin/env python` resolves through PATH, so its first word says
        # nothing about whether the interpreter is there.
        if not words or os.path.basename(words[0]) == 'env':
            continue
        if not os.path.exists(words[0]):
            problems.append('%s: its interpreter %s is gone, so the command is '
                            'dead: uv tool install %s --reinstall'
                            % (name, words[0], name))


def show(ref):
    kind, url, rev = ref
    if kind == 'git':
        return 'git+%s@%s' % (url, rev)
    return rev or 'whatever PyPI serves'


try:
    tool_dir = subprocess.run(
        ['uv', 'tool', 'dir'],
        capture_output=True, text=True, check=True).stdout.strip()
except (OSError, subprocess.CalledProcessError) as err:
    print('cannot ask uv where its tools live (%s)' % err)
    raise SystemExit(0)

want = declared()
have = installed(tool_dir) if os.path.isdir(tool_dir) else {}

for name in sorted(set(want) - set(have)):
    problems.append('%s: declared and not installed: ./install.sh' % name)

for name in sorted(set(have) - set(want)):
    problems.append('%s: installed and not declared: add it to uv-tools.txt, '
                    'or: uv tool uninstall %s' % (name, name))

for name in sorted(set(want) & set(have)):
    ref, _ = have[name]
    if ref != want[name]:
        problems.append(
            '%s: uv-tools.txt says %s, this machine has %s: ./install.sh'
            % (name, show(want[name]), show(ref)))

# Every installed tool, declared or not. Whether a command on PATH runs is not a
# question about this repo's manifest, and scoping it to the declared ones hid
# the only broken tool on the machine behind the milder complaint that it was
# undeclared.
for name in sorted(have):
    broken_entrypoints(name, have[name][1])

for problem in problems:
    print(problem)
PY
}
report "uv-tools.txt matches this machine" \
  "each line above ends in the command that closes it" \
  "$(uv_tools_drift)"

# Drift against a calendar again, the same shape as the end-of-life check below:
# a tag pinned in uv-tools.txt was the latest release the day it was written and
# stops being so without anything in this repo changing.
#
# Only the pinned git references can be asked this, and anything else is reported
# rather than skipped, for the reason the runtime map below states: a tool nobody
# checks reads exactly like a tool that is up to date.
#
# /releases/latest excludes prereleases, so a deliberately pinned alpha reads as
# behind. Reported as a difference with both values rather than as "upgrade this",
# because which of the two is right is a judgement this script does not have.
stale_uv_pins() {
  python3 - << 'PY'
import json
import re
import urllib.request

problems = []

with open('uv-tools.txt', encoding='utf-8') as handle:
    for line in handle:
        fields = line.split('#')[0].split()
        if not fields:
            continue
        name = fields[0]
        ref = fields[1] if len(fields) > 1 else ''
        match = re.fullmatch(
            r'git\+https://github\.com/([^/]+)/([^/]+?)(?:\.git)?@(.+)', ref)
        if not match:
            problems.append('%s: no upstream release source mapped for %r'
                            % (name, ref))
            continue
        owner, repo, tag = match.groups()
        url = 'https://api.github.com/repos/%s/%s/releases/latest' % (owner, repo)
        try:
            request = urllib.request.Request(
                url, headers={'Accept': 'application/vnd.github+json'})
            with urllib.request.urlopen(request, timeout=20) as response:
                latest = json.load(response)['tag_name']
        except Exception as err:
            # Unauthenticated calls are rate limited to 60 an hour, which arrives
            # here as a 403 and is worth naming rather than reading as an outage.
            problems.append('%s: could not ask GitHub for the latest release (%s)'
                            % (name, err))
            continue
        if latest != tag:
            problems.append('%s: pinned to %s, upstream now releases %s'
                            % (name, tag, latest))

for problem in problems:
    print(problem)
PY
}
report "no pinned uv tool is behind upstream" \
  "bump the tag in uv-tools.txt, then ./install.sh" \
  "$(stale_uv_pins)"

printf '\n%sRuntimes%s\n' "$DIM" "$OFF"

# The README states this as a rule -- "Homebrew installs programs, mise installs
# runtimes" -- and until now nothing enforced it. A runtime from Homebrew is a
# single global version: whichever shell has mise activated gets the right one
# and everything else (scripts, launchd jobs, non-interactive shells) silently
# gets Homebrew's. The symptom appears far from the cause.
RUNTIMES="node deno bun go ruby rust php openjdk"
through_brew=""
for r in $RUNTIMES; do
  brew list --formula --versions "$r" > /dev/null 2>&1 &&
    through_brew+="$r ($(brew list --versions "$r" | awk '{print $2}'))"$'\n'
done
report "no runtime comes from Homebrew" \
  "install it with mise instead: brew uninstall <name> && mise use -g <name>@lts" \
  "${through_brew%$'\n'}"

# Running a version nobody patches anymore is not drift between two files: it is
# drift against a calendar, so no amount of reading this repo can detect it. A
# pin that was correct when it was written becomes wrong on a date, silently,
# and the only signal is that security fixes stop arriving.
#
# This is the one check here that needs the network. It is also why the whole
# file is run by hand: a check that fails because GitHub's DNS blinked has no
# business gating a commit.
#
# endoflife.date rather than nodejs.org's own schedule.json, which is
# first-party and would be the better source if node were the only thing pinned.
# It is not -- and endoflife.date returns the same shape for python, go and
# ruby, so covering another runtime is one line in the map below instead of a
# second parser for a second format.
eol_runtimes() {
  python3 - << 'PY'
import datetime
import json
import subprocess
import sys
import urllib.request

# A runtime missing from this map is reported, not skipped. An unchecked runtime
# reads exactly like a supported one, which is the failure this file exists for.
PRODUCTS = {
    'node': 'nodejs',
    'python': 'python',
    'go': 'go',
    'ruby': 'ruby',
    'rust': 'rust',
    'php': 'php',
    'bun': 'bun',
    'deno': 'deno',
}

problems = []
today = datetime.date.today()

current = json.loads(subprocess.run(
    ['mise', 'ls', '--current', '--json'],
    capture_output=True, text=True, check=True).stdout)

for tool, entries in sorted(current.items()):
    product = PRODUCTS.get(tool)
    if product is None:
        problems.append('%s: no end-of-life source mapped for it' % tool)
        continue
    try:
        url = 'https://endoflife.date/api/%s.json' % product
        with urllib.request.urlopen(url, timeout=20) as response:
            cycles = json.load(response)
    except Exception as err:
        problems.append('%s: could not reach endoflife.date (%s)' % (tool, err))
        continue

    for entry in entries:
        version = entry['version']
        # Longest matching cycle wins, so 3.13 is preferred over a bare 3.
        matches = [c for c in cycles
                   if version == c['cycle'] or version.startswith(c['cycle'] + '.')]
        if not matches:
            problems.append('%s %s: matches no known release cycle' % (tool, version))
            continue
        eol = max(matches, key=lambda c: len(c['cycle']))['eol']
        # Some products report a boolean instead of a date once it has passed.
        if eol is True:
            problems.append('%s %s: past end of life' % (tool, version))
        elif isinstance(eol, str) and datetime.date.fromisoformat(eol) <= today:
            problems.append('%s %s: end of life since %s' % (tool, version, eol))

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
}
report "no runtime is past end of life" \
  "upgrade it: mise use -g <tool>@<newer>" \
  "$(eol_runtimes)"

# The schemas under schemas/ are copies of something upstream keeps changing,
# and a copy is only as good as the thing that notices it went stale. Stale here
# has a specific and annoying shape: adopt a key that starship or mise added
# after the copy was taken, and taplo calls your correct config invalid. The
# check that guards the configs would be the thing blocking you.
#
# This lives here and not in check.sh for the reason stated at the top of this
# file: it needs the network, and a gate that fails because DNS blinked is a
# gate you learn to ignore. Vendoring is what keeps the commit path offline;
# this is what keeps the vendored copy honest.
#
# Compared as parsed JSON rather than byte-for-byte, so a reordered key or a
# reindent upstream does not read as a change worth acting on.
stale_schemas() {
  python3 - << 'PY'
import json
import urllib.request

SCHEMAS = {
    "schemas/starship.json": "https://starship.rs/config-schema.json",
    "schemas/mise.json": "https://mise.jdx.dev/schema/mise.json",
}

# Both hosts sit behind a CDN that answers urllib's default User-Agent with a
# 403, which arrives here as "could not reach" and reads as a network problem
# it is not. Anything else gets through; this says who is asking rather than
# pretending to be a browser.
HEADERS = {"User-Agent": "dotfiles-drift (+https://github.com/camilopiedra92/dotfiles)"}


def canonical(raw):
    return json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":"))


problems = []
for path, url in sorted(SCHEMAS.items()):
    try:
        request = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(request, timeout=10) as response:
            remote = canonical(response.read())
    except Exception as err:
        problems.append("%s: could not reach %s (%s)" % (path, url, err))
        continue
    with open(path, "rb") as handle:
        if canonical(handle.read()) != remote:
            problems.append("%s is behind: curl -fsSL %s -o %s" % (path, url, path))

for problem in problems:
    print(problem)
PY
}
report "vendored schemas match upstream" \
  "refresh it, then ./check.sh -- a newer schema can reject a config it used to accept" \
  "$(stale_schemas)"

if [ "$FAILED" -eq 0 ]; then
  printf '\n%sNo drift: installed and declared match%s\n\n' "$GREEN" "$OFF"
else
  printf '\n%sDrift found%s\n\n' "$RED" "$OFF"
fi
exit "$FAILED"
