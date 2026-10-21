#!/usr/bin/env bash
# The worker container's entrypoint (specs/003-sdd-model-routing,
# contracts/pass.md): the firewall first, then the pass's command as `node`,
# with no new privileges and an environment cut down to an allow list, so
# nothing the runtime was given reaches the agent unless named here.
#
# Runs as root, with NET_ADMIN and NET_RAW for the firewall only. Reads:
#   SDD_PROXY                ip:port of the run's egress proxy (required)
#   SDD_PASS_TOKEN           the pass's placeholder (required): random, made
#                            for this pass, and the key by which the proxy
#                            finds what the pass is admitted to
#   ANTHROPIC_BASE_URL       for a Claude pass; must be the proxy
#   CLAUDE_CODE_OAUTH_TOKEN  for a Claude pass; must be the pass's placeholder
# and, from the pass's read-only mounts:
#   /bundle/proxy-ca.pem     the run's certificate authority, with which the
#                            proxy reads the registries' TLS (required)
#   /bundle/models.json      for a pi pass: pi's provider, every baseUrl the
#                            proxy and every apiKey the pass's placeholder
#   /cache                   the pass kind's cache volume, when mounted
# No credential ever enters this container: the proxy replaces the
# placeholder (research R23). A real-looking token here means the host side
# is wrong, so it stops the pass instead of passing it on.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "entrypoint: $*" >&2
  exit 2
}

[[ ${SDD_PROXY:-} =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]{1,5})$ ]] ||
  fail "SDD_PROXY must be <IPv4 address>:<port>"
proxy_ip=${BASH_REMATCH[1]}
proxy_port=${BASH_REMATCH[3]}
proxy_url="http://$proxy_ip:$proxy_port"

# The shape sdd-pass.py makes. A real Anthropic or DeepSeek credential has
# another (sk-...), so one passed here by mistake stops the pass.
[[ ${SDD_PASS_TOKEN:-} =~ ^sdd-pass-[A-Za-z0-9_-]{16,119}$ ]] ||
  fail "SDD_PASS_TOKEN must be the pass's placeholder, sdd-pass-<random>"
placeholder=$SDD_PASS_TOKEN

# A base URL must be the proxy itself, optionally with a plain path: anything
# else would be a route out that the firewall refuses anyway, or a typo that
# would surface later as an opaque connection error. The path's characters are
# limited because the URL is written into pi's JSON below.
at_proxy() { [[ $1 =~ ^http://$proxy_ip:$proxy_port(/[A-Za-z0-9._/-]*)?$ ]]; }

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ "$CLAUDE_CODE_OAUTH_TOKEN" != "$placeholder" ]; then
  fail "CLAUDE_CODE_OAUTH_TOKEN is not the pass's placeholder; no credential may enter the worker"
fi
if [ -n "${ANTHROPIC_BASE_URL:-}" ] && ! at_proxy "$ANTHROPIC_BASE_URL"; then
  fail "ANTHROPIC_BASE_URL must point at the egress proxy ($proxy_url)"
fi

# The mount points of contracts/pass.md, and the system trust directory. SDD_MOUNT_ROOT
# is unset in the image; checks/92-sdd-worker.sh sets it to a scratch
# directory, since a test on the host cannot create /bundle or write
# /usr/local/share, and nothing in a pass sets it.
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
    fail "/bundle/models.json must give every provider the proxy as baseUrl and the pass's placeholder as apiKey"
fi

# The run's authority (FR-031, research R25): the egress proxy terminates the
# registries' TLS with it, so it is trusted before anything reaches out, and
# only if it is an authority; anything else here is a host-side mistake.
ca=$bundle/proxy-ca.pem
[ -f "$ca" ] || fail "/bundle/proxy-ca.pem is missing; the pass did not pass the run's authority"
# Exactly one PEM block, a certificate: openssl reads only the first block of
# a file, so a second certificate or a key beside it would ride in unchecked
# (review of Phase 2b).
if [ "$(grep -c '^-----BEGIN ' "$ca")" != 1 ] || ! grep -qx -- '-----BEGIN CERTIFICATE-----' "$ca"; then
  fail "/bundle/proxy-ca.pem must hold exactly one certificate and nothing else"
fi
openssl x509 -in "$ca" -noout -text 2> /dev/null |
  awk '/X509v3 Basic Constraints/ { getline; found = /CA:TRUE/; exit } END { exit !found }' ||
  fail "/bundle/proxy-ca.pem is not a certificate authority"
mkdir -p "$root/usr/local/share/ca-certificates"
# What is trusted is the certificate checked, re-encoded, not the file as it came.
openssl x509 -in "$ca" -out "$root/usr/local/share/ca-certificates/sdd-run.crt" 2> /dev/null ||
  fail "could not install the run's authority"
update-ca-certificates > /dev/null 2>&1 || fail "update-ca-certificates failed"

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
  # The system store, with the run's authority in it: Node, Python and
  # requests keep their own trust lists unless pointed here.
  NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  # npm's audit and funding calls are POSTs the read-only proxy refuses
  # (research R25); nothing a pass needs comes from them.
  npm_config_audit=false
  npm_config_fund=false
  # Claude Code otherwise opens its own connections to api.anthropic.com
  # (telemetry, error reports), outside ANTHROPIC_BASE_URL; the proxy refuses
  # them, so they are only noise (seen in the first real pass, 2026-10-21).
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  # Registries are reached by CONNECT through the proxy, the placeholder as
  # the proxy user, which is how the proxy knows the pass; the proxy itself
  # is reached directly, as the API gateway it also is.
  HTTPS_PROXY="http://$placeholder@$proxy_ip:$proxy_port"
  https_proxy="http://$placeholder@$proxy_ip:$proxy_port"
  HTTP_PROXY="http://$placeholder@$proxy_ip:$proxy_port"
  http_proxy="http://$placeholder@$proxy_ip:$proxy_port"
  NO_PROXY="$proxy_ip"
  no_proxy="$proxy_ip"
)
[ -z "${ANTHROPIC_BASE_URL:-}" ] || env+=(ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL")
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || env+=(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN")
# The feature Spec Kit's scripts work on (they cannot read it from a git
# branch: the export has none); a path under /work, nothing else.
if [ -n "${SPECIFY_FEATURE_DIRECTORY:-}" ]; then
  [[ $SPECIFY_FEATURE_DIRECTORY =~ ^/work/specs/[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
    fail "SPECIFY_FEATURE_DIRECTORY must be /work/specs/<nnn>-<slug>"
  env+=(SPECIFY_FEATURE_DIRECTORY="$SPECIFY_FEATURE_DIRECTORY")
fi

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
