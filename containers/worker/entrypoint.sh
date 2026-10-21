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
#   SDD_DEEPSEEK_BASE_URL    for a pi pass; must be the proxy
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
if [ -n "${SDD_DEEPSEEK_BASE_URL:-}" ] && ! at_proxy "$SDD_DEEPSEEK_BASE_URL"; then
  fail "SDD_DEEPSEEK_BASE_URL must point at the egress proxy ($proxy_url)"
fi

"$here/init-firewall.sh" "$proxy_ip" "$proxy_port"

home=$(getent passwd node | cut -d: -f6)
[ -n "$home" ] || fail "no user node"

# pi reads its provider from ~/.pi/agent/models.json; the image creates that
# file owned by node, and writing into it keeps its owner.
if [ -n "${SDD_DEEPSEEK_BASE_URL:-}" ]; then
  sed "s#\"http://sdd-egress-proxy.invalid\"#\"$SDD_DEEPSEEK_BASE_URL\"#" "$here/models.json" > "$home/.pi/agent/models.json"
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

cd /work 2> /dev/null || cd "$home"
exec setpriv --reuid=node --regid=node --init-groups --no-new-privs \
  --inh-caps=-all --bounding-set=-all \
  env -i "${env[@]}" "$@"
