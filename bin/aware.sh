#!/usr/bin/env bash
# Runs the aware-connector CLI — Autodesk's people directory from the terminal —
# from anywhere, against the checkout in ~/Development/aware-connector.
#
# Usage:  aware <login | me | search <query> | people | logout>
#
# `mise x -C "$REPO"` rather than a bare `node`: the CLI is TypeScript executed
# by Node's type-stripping, so it needs the runtime the repo pins in its own
# mise.toml. A bare `node` resolves against the *current* directory's mise
# config, so running this inside a project pinned to an older Node would fail on
# syntax, which reads as a broken tool rather than a version mismatch.
#
# Deliberately not `npm link`. That writes a symlink into the npm prefix of one
# exact Node version (installs/node/26.7.0/bin), so the command disappears at the
# next patch upgrade, and nothing in version control records it ever existed.
set -euo pipefail

REPO="${AWARE_CONNECTOR_DIR:-$HOME/Development/aware-connector}"

if [ ! -f "$REPO/src/cli.ts" ]; then
  echo "aware: no aware-connector checkout at $REPO" >&2
  echo "       clone it there, or set AWARE_CONNECTOR_DIR to where it lives." >&2
  exit 1
fi

# The CLI reads its credential from the keychain and needs no dependencies, so
# there is nothing to install first — it runs straight from source.
exec mise x -C "$REPO" -- node "$REPO/src/cli.ts" "$@"
