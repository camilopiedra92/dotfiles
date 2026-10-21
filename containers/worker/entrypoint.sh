#!/usr/bin/env bash
# The worker container's entrypoint (specs/003-sdd-model-routing,
# contracts/pass.md): the firewall first, then the pass's command as `node`,
# with no new privileges and an environment cut down to an allow list, so
# nothing the runtime was given reaches the agent unless named here.
#
# Runs as root, with NET_ADMIN and NET_RAW for the firewall only. Reads:
#   SDD_PROXY                ip:port of the run's egress proxy (required)
#   ANTHROPIC_BASE_URL       for a Claude pass; must be the proxy
#   CLAUDE_CODE_OAUTH_TOKEN  for a Claude pass; must be the placeholder
# and, from the pass's read-only mounts:
#   /bundle/models.json      for a pi pass: pi's provider, every baseUrl the
#                            proxy and every apiKey the placeholder
#   /cache                   the pass kind's cache volume, when mounted
# No credential ever enters this container: the proxy replaces the
# placeholder (research R23). A real-looking token here means the host side
# is wrong, so it stops the pass instead of passing it on.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
placeholder=sdd-placeholder

fail() {
  echo "entrypoint: $*" >&2
  exit 2
}

[[ ${SDD_PROXY:-} =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]{1,5})$ ]] ||
  fail "SDD_PROXY must be <IPv4 address>:<port>"
proxy_ip=${BASH_REMATCH[1]}
proxy_port=${BASH_REMATCH[3]}
proxy_url="http://$proxy_ip:$proxy_port"

# A base URL must be the proxy itself, optionally with a plain path: anything
# else would be a route out that the firewall refuses anyway, or a typo that
# would surface later as an opaque connection error. The path's characters are
# limited because the URL is written into pi's JSON below.
at_proxy() { [[ $1 =~ ^http://$proxy_ip:$proxy_port(/[A-Za-z0-9._/-]*)?$ ]]; }

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ "$CLAUDE_CODE_OAUTH_TOKEN" != "$placeholder" ]; then
  fail "CLAUDE_CODE_OAUTH_TOKEN is not the placeholder; no credential may enter the worker"
fi
if [ -n "${ANTHROPIC_BASE_URL:-}" ] && ! at_proxy "$ANTHROPIC_BASE_URL"; then
  fail "ANTHROPIC_BASE_URL must point at the egress proxy ($proxy_url)"
fi

# The mount points of contracts/pass.md. SDD_MOUNT_ROOT is unset in the image;
# checks/92-sdd-worker.sh sets it to a scratch directory, since a test on the
# host cannot create /bundle, and nothing in a pass sets it.
root=${SDD_MOUNT_ROOT:-}
bundle=$root/bundle
cache=$root/cache
work=$root/work

# pi's models.json comes from the host; it is checked before the firewall is
# even up, so a file that would send pi anywhere but the proxy, or carry a
# key, stops the pass.
if [ -f "$bundle/models.json" ]; then
  python3 -I - "$bundle/models.json" "$proxy_ip" "$proxy_port" "$placeholder" << 'PY' ||
import json, re, sys
path, ip, port, placeholder = sys.argv[1:]
at_proxy = re.compile(r"http://%s:%s(/[A-Za-z0-9._/-]*)?" % (re.escape(ip), port))
try:
    providers = json.load(open(path))["providers"]
    ok = bool(providers) and all(
        at_proxy.fullmatch(p["baseUrl"]) and p["apiKey"] == placeholder
        for p in providers.values()
    )
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
    fail "/bundle/models.json must give every provider the proxy as baseUrl and the placeholder as apiKey"
fi

"$here/init-firewall.sh" "$proxy_ip" "$proxy_port"

home=$(getent passwd node | cut -d: -f6)
[ -n "$home" ] || fail "no user node"

# pi reads its provider from ~/.pi/agent/models.json; the image creates that
# file owned by node, and writing into it keeps its owner.
if [ -f "$bundle/models.json" ]; then
  cat "$bundle/models.json" > "$home/.pi/agent/models.json"
fi

env=(
  HOME="$home"
  USER=node
  LOGNAME=node
  PATH=/usr/local/bin:/usr/bin:/bin
  LANG=C.UTF-8
  # Registries are reached by CONNECT through the proxy; the proxy itself is
  # reached directly, as the API gateway it also is.
  HTTPS_PROXY="$proxy_url"
  https_proxy="$proxy_url"
  HTTP_PROXY="$proxy_url"
  http_proxy="$proxy_url"
  NO_PROXY="$proxy_ip"
  no_proxy="$proxy_ip"
)
[ -z "${ANTHROPIC_BASE_URL:-}" ] || env+=(ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL")
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || env+=(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN")

# A cache volume is created by the runtime owned by root; node gets it, and
# every package manager in the image keeps its cache there.
if [ -d "$cache" ]; then
  chown node:node "$cache"
  env+=(
    NPM_CONFIG_CACHE="$cache/npm"
    UV_CACHE_DIR="$cache/uv"
    PIP_CACHE_DIR="$cache/pip"
    MISE_CACHE_DIR="$cache/mise"
    MISE_DATA_DIR="$cache/mise-data"
  )
fi

cd "$work"
exec setpriv --reuid=node --regid=node --init-groups --no-new-privs \
  --inh-caps=-all --bounding-set=-all \
  env -i "${env[@]}" "$@"
