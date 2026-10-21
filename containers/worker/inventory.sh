#!/bin/sh
# Every package the worker image installs, with its version, one per line and
# sorted: what prepare-worker compares with inventory.txt beside it (FR-032,
# research R26). Debian packages from dpkg; node, mise and uv from
# themselves; npm packages by walking the tree
# npm ci installed under /opt/sdd — scoped and nested ones included — so a
# transitive dependency that moved shows as well as a direct one.
#
# Regenerate inventory.txt on purpose after moving a pin:
#   container run --rm --entrypoint /usr/local/lib/sdd/inventory.sh <tag> > containers/worker/inventory.txt
set -eu
# Collected into a file first: sh has no pipefail, so a command failing inside
# a group piped to sort would still leave sort's status and a partial list,
# read as "an input moved" (review of Phase 2b).
list=$(mktemp)
trap 'rm -f "$list"' EXIT
{
  dpkg-query -W -f='deb ${Package} ${Version}\n'
  # The tools neither dpkg nor npm installed: node from the base, mise and uv
  # from their checked downloads.
  echo "tool node $(node --version | sed 's/^v//')"
  echo "tool mise $(mise --version | awk '{ print $1 }')"
  echo "tool uv $(uv --version | awk '{ print $2 }')"
  node -e '
const fs = require("fs"), path = require("path");
function walk(dir) {
  const nm = path.join(dir, "node_modules");
  if (!fs.existsSync(nm)) return;
  for (const entry of fs.readdirSync(nm)) {
    if (entry.startsWith(".")) continue;
    const roots = entry.startsWith("@") ? fs.readdirSync(path.join(nm, entry)).map(s => path.join(nm, entry, s)) : [path.join(nm, entry)];
    for (const p of roots) {
      const manifest = path.join(p, "package.json");
      if (!fs.existsSync(manifest)) continue;
      const m = JSON.parse(fs.readFileSync(manifest, "utf8"));
      console.log("npm " + m.name + " " + m.version);
      walk(p);
    }
  }
}
walk("/opt/sdd");'
} > "$list"
LC_ALL=C sort -u "$list"
