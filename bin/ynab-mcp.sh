#!/usr/bin/env bash
# Runs the YNAB MCP server with a working directory of its own.
#
# Usage:  configured as the `command` of the ynab server in ~/.claude.json.
#         Not meant to be run by hand.
#
# The server is built on mcp-framework, whose logger opens "logs" as a relative
# path with no way to configure it:
#
#     const logDir = "logs";                       // Logger.js
#     mkdir(logDir, { recursive: true })
#
# Relative to the process's working directory, which is wherever the editor was
# started -- so it drops a logs/ directory with one file per session into every
# repository you open, each of them untracked and each of them somebody's
# problem to gitignore. There is no environment variable for it and Claude Code
# has no `cwd` field for stdio servers, so the only place left to fix it is the
# process's own working directory, which is what this file exists to set.
#
# Under XDG_STATE_HOME rather than a cache: these logs are the record of what a
# long-running background process did, which is what state means here, and
# losing them mid-session would leave a running server writing to a deleted
# file. A cache is something anything may delete at any time.
set -euo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ynab-mcp"
# Both directories, because the server writes into "logs" *under* the working
# directory set here, and the cleanup below has to be given the path the files
# are actually at. Creating it also means that cleanup never runs against a
# directory that does not exist yet.
mkdir -p "$STATE/logs"
cd "$STATE"

# One file per server start, forever, in a directory nothing else prunes. Two
# weeks is long enough to still have the log of the session where something went
# wrong, and short enough that the directory does not become another thing to
# clean up by hand. Never fatal: a failed cleanup must not stop the server from
# starting, and the editor would report that as the server being broken.
find logs -maxdepth 1 -type f -name 'mcp-server-*.log' -mtime +14 -delete || true

# `mise x` and not a bare npx, for the reason bin/aware.sh gives at more length:
# the server is spawned by the editor, which does not read .zshenv, so the mise
# shims may not be on PATH at all. Unlike aware, no -C: the working directory
# set above holds no mise.toml, so this resolves the global runtime -- which is
# what a machine-wide background service should run on, not whichever version
# the repository you happened to open pins.
exec mise x -- npx -y ynab-mcp-server "$@"
