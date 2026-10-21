# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Egress proxy ─────────────────────────────────────────────────────────────
# bin/sdd-egress-proxy.py is the only destination of every agent container in
# a routed Spec Kit run (specs/003-sdd-model-routing, contracts/pass.md "The
# egress proxy", research R23). It holds the provider credentials, so these
# cases are about where a credential goes and where a pass may reach.
#
# Everything runs on loopback: stand-in provider APIs serving HTTPS with a
# certificate made here, which the proxy trusts through SSL_CERT_FILE -- the
# variable OpenSSL itself reads, so the proxy carries no trust option of its
# own for tests -- and a stand-in registry, a plain TCP server a CONNECT
# tunnel reaches. Passes are admitted as the run admits them: a file per
# token in the admissions directory, which the proxy only reads. The
# credentials are fake and distinctive, so a grep over every file the run
# wrote finds any copy. The proxy runs with HOME, TMPDIR and its working
# directory inside the scratch directory, so that grep covers everywhere it
# could have written.
printf '\n%sEgress proxy%s\n' "$DIM" "$OFF"

EP_TMP=$(mktemp -d)
EP_ROOT=$PWD
EP_PIDS=()
EP_CRED_ANTHROPIC=fake-claude-oauth-3f1b7c2e
EP_CRED_DEEPSEEK=fake-deepseek-key-9a4d0e61
mkdir -p "$EP_TMP/helpers" "$EP_TMP/home" "$EP_TMP/tmp" "$EP_TMP/run"

# A stand-in provider API: records each request as a line of JSON -- the
# authorization as a hash, so the record holds no credential for the grep
# below to find -- and answers "<name>-ok", or a model list on GET /models.
cat > "$EP_TMP/helpers/upstream.py" << 'PY'
import hashlib, http.server, json, ssl, sys
name, cert, key, portfile, record = sys.argv[1:6]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _serve(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        auth = self.headers.get("Authorization") or ""
        with open(record, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                "auth": hashlib.sha256(auth.encode()).hexdigest(),
                "x_api_key": self.headers.get("x-api-key") is not None,
                "beta": self.headers.get("anthropic-beta"),
                "host": self.headers.get("Host"), "body": body.decode()}) + "\n")
        if self.path == "/models":
            out = json.dumps({"object": "list", "data": [{"id": "deepseek-flash", "name": "DeepSeek-Stand-In"}]}).encode()
        else:
            out = (name + "-ok").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    do_GET = do_POST = _serve
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
s.socket = ctx.wrap_socket(s.socket, server_side=True)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PY

# A stand-in registry: whatever reaches it through a tunnel is greeted with a
# fixed line, so the client knows the tunnel arrived.
cat > "$EP_TMP/helpers/registry.py" << 'PY'
import socketserver, sys
portfile = sys.argv[1]
class H(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b"registry-ok\n")
s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PY

# The agent side, one request per call, printing what came back: "<status>
# <body>" for the API, "<status> <tunnel data>" for CONNECT.
cat > "$EP_TMP/helpers/client.py" << 'PY'
import base64, http.client, socket, sys
cmd, port = sys.argv[1], int(sys.argv[2])
def http_call(method, path, headers, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, body=body, headers=headers)
    r = c.getresponse()
    print(r.status, r.read().decode(errors="replace"))
if cmd in ("api", "api-key"):  # api PORT TOKEN METHOD PATH
    token, method, path = sys.argv[3:6]
    h = {"anthropic-beta": "oauth-2025-04-20", "Content-Type": "application/json"}
    if token and cmd == "api":
        h["Authorization"] = "Bearer " + token
    elif token:
        h["x-api-key"] = token
    http_call(method, path, h, "{}" if method == "POST" else None)
elif cmd == "connect":  # connect PORT TOKEN HOST:PORT
    token, target = sys.argv[3:5]
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    auth = base64.b64encode((token + ":x").encode()).decode()
    s.sendall(("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n" % (target, target, auth)).encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    status = head.split(b" ")[1].decode() if head else "none"
    if status == "200":
        while b"\n" not in rest:
            chunk = s.recv(4096)
            if not chunk:
                break
            rest += chunk
    print(status, rest.decode(errors="replace").strip())
elif cmd == "absolute":  # absolute PORT TOKEN URL
    token, url = sys.argv[3:5]
    http_call("GET", url, {"Proxy-Authorization": "Basic " + base64.b64encode((token + ":x").encode()).decode()})
PY

# Waits for a file a background process writes once it is listening.
ep_wait_for() {
  for _ in $(seq 1 100); do
    [ -s "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

# Starts a proxy with the given providers JSON and heartbeat window, its
# configuration on stdin, as sdd-step will start it, reading its admissions
# from $EP_TMP/<label>.admit. Sets EP_API from the line it prints when ready,
# and EP_PID.
ep_start_proxy() { # ep_start_proxy <label> <providers json> <heartbeat seconds>
  local label=$1 dir="$EP_TMP/run/$1"
  mkdir -p "$dir" "$EP_TMP/$label.admit"
  printf '{"listen": "127.0.0.1:0", "admissions": "%s", "heartbeat_seconds": %s, "providers": %s, "registries": ["localhost:%s"]}\n' \
    "$EP_TMP/$label.admit" "$3" "$2" "$EP_REGISTRY" |
    (cd "$dir" && HOME="$EP_TMP/home" TMPDIR="$EP_TMP/tmp" SSL_CERT_FILE="$EP_TMP/cert.pem" \
      exec python3 -I "$EP_ROOT/bin/sdd-egress-proxy.py" > "$EP_TMP/$label.ready" 2> "$EP_TMP/$label.log") &
  EP_PID=$!
  EP_PIDS+=("$EP_PID")
  ep_wait_for "$EP_TMP/$label.ready" || {
    echo "$label: the proxy printed no ready line; its log:"
    cat "$EP_TMP/$label.log"
    return 1
  }
  if ! EP_API=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["api_port"])' "$EP_TMP/$label.ready"); then
    echo "$label: the ready line is not {\"api_port\": …, \"models\": …}: $(cat "$EP_TMP/$label.ready")"
    return 1
  fi
}

# Every answer is kept, so the last case's grep covers the responses too.
ep_client() {
  [ -n "$2" ] || {
    echo "no port to reach: the proxy did not start"
    return 1
  }
  python3 -I "$EP_TMP/helpers/client.py" "$@" | tee -a "$EP_TMP/responses.log"
}

# Admits a pass on the main proxy as the run does, and prints its token.
ep_admit() { # ep_admit <admit json list> [<proxy label>]
  local token
  token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  printf '{"admit": %s}\n' "$1" > "$EP_TMP/${2:-main}.admit/$token.json"
  echo "$token"
}

ep_records() { if [ -f "$EP_TMP/$1.jsonl" ]; then wc -l < "$EP_TMP/$1.jsonl" | tr -d ' '; else echo 0; fi; }

ep_sha() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

ep_setup() {
  # Apple's /usr/bin/python3 is linked against LibreSSL, which ignores
  # SSL_CERT_FILE (seen 2026-10-21: 3.9.6, LibreSSL 2.8.3, "self signed
  # certificate" with the variable set), so the TLS cases need an
  # OpenSSL-linked python3, as the worker image's Debian Python is.
  python3 -I -c 'import ssl, sys; sys.exit(not ssl.OPENSSL_VERSION.startswith("OpenSSL"))' || {
    echo "$(command -v python3) is linked against $(python3 -I -c 'import ssl; print(ssl.OPENSSL_VERSION)'), which ignores SSL_CERT_FILE: put an OpenSSL-linked python3 first on PATH"
    return 1
  }
  cat > "$EP_TMP/cert.cnf" << 'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = localhost
[ext]
subjectAltName = DNS:localhost
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$EP_TMP/cert.cnf" \
    -keyout "$EP_TMP/key.pem" -out "$EP_TMP/cert.pem" > /dev/null 2>&1 || {
    echo "could not make the stand-ins' certificate"
    return 1
  }
  local name
  for name in anthropic deepseek; do
    python3 -I "$EP_TMP/helpers/upstream.py" "$name" "$EP_TMP/cert.pem" "$EP_TMP/key.pem" \
      "$EP_TMP/$name.port" "$EP_TMP/$name.jsonl" > /dev/null 2>&1 &
    EP_PIDS+=($!)
  done
  python3 -I "$EP_TMP/helpers/registry.py" "$EP_TMP/registry.port" > /dev/null 2>&1 &
  EP_PIDS+=($!)
  # A second registry, listening but on no list: a refusal must come from the
  # proxy's list, not from nothing being there.
  python3 -I "$EP_TMP/helpers/registry.py" "$EP_TMP/unlisted.port" > /dev/null 2>&1 &
  EP_PIDS+=($!)
  for name in anthropic deepseek registry unlisted; do
    ep_wait_for "$EP_TMP/$name.port" || {
      echo "the $name stand-in did not start"
      return 1
    }
  done
  EP_REGISTRY=$(cat "$EP_TMP/registry.port")
  EP_UNLISTED=$(cat "$EP_TMP/unlisted.port")
  EP_ANTHROPIC="{\"upstream\": \"https://localhost:$(cat "$EP_TMP/anthropic.port")\", \"credential\": \"$EP_CRED_ANTHROPIC\"}"
  EP_PROVIDERS="{\"anthropic\": $EP_ANTHROPIC, \"deepseek\": {\"upstream\": \"https://localhost:$(cat "$EP_TMP/deepseek.port")\", \"credential\": \"$EP_CRED_DEEPSEEK\", \"models\": \"/models\"}}"
}

# Set up outside `check`, which runs its command in a subshell: the ports and
# process ids have to outlive it. A failed setup still shows, as the first case.
if ep_setup > "$EP_TMP/setup.out" 2>&1; then EP_SETUP=0; else EP_SETUP=1; fi
if ep_start_proxy main "${EP_PROVIDERS:-{\}}" 600 > "$EP_TMP/main.start" 2>&1; then EP_MAIN=0; else EP_MAIN=1; fi

ep_started() {
  [ "$EP_SETUP" -eq 0 ] || {
    cat "$EP_TMP/setup.out"
    return 1
  }
  [ "$EP_MAIN" -eq 0 ] || {
    cat "$EP_TMP/main.start"
    return 1
  }
  python3 - "$EP_TMP/main.ready" "$(ep_sha "Bearer $EP_CRED_DEEPSEEK")" "$EP_TMP/deepseek.jsonl" << 'PY'
import json, sys
ready = json.load(open(sys.argv[1]))
want = {"deepseek": {"object": "list", "data": [{"id": "deepseek-flash", "name": "DeepSeek-Stand-In"}]}}
if ready.get("models") != want:
    sys.exit("the ready line's models are not DeepSeek's /models answer: %r" % ready.get("models"))
r = json.loads(open(sys.argv[3]).read().splitlines()[0])
if (r["method"], r["path"], r["auth"]) != ("GET", "/models", sys.argv[2]):
    sys.exit("DeepSeek's first request was not GET /models with the credential: %s %s" % (r["method"], r["path"]))
PY
}
check "the egress proxy starts from one line on stdin and reports its port and the models behind DeepSeek's ids" ep_started

ep_injects() {
  local judge impl out
  judge=$(ep_admit '["anthropic"]')
  impl=$(ep_admit '["deepseek", "registries"]')
  out=$(ep_client api "$EP_API" "$judge" POST /v1/messages)
  [ "$out" = "200 anthropic-ok" ] || {
    echo "a judgment pass's request to its provider answered: $out"
    return 1
  }
  out=$(ep_client api-key "$EP_API" "$impl" POST /chat/completions)
  [ "$out" = "200 deepseek-ok" ] || {
    echo "an implement pass's request to its provider, its token as x-api-key, answered: $out"
    return 1
  }
  # The last record of each stand-in is the request above.
  python3 - "$EP_TMP" "$(ep_sha "Bearer $EP_CRED_ANTHROPIC")" "$(ep_sha "Bearer $EP_CRED_DEEPSEEK")" << 'PY'
import json, sys
tmp, want_a, want_d = sys.argv[1:4]
for name, want, path in (("anthropic", want_a, "/v1/messages"), ("deepseek", want_d, "/chat/completions")):
    r = json.loads(open("%s/%s.jsonl" % (tmp, name)).read().splitlines()[-1])
    if r["path"] != path:
        sys.exit("%s received %s, not %s" % (name, r["path"], path))
    if r["auth"] != want:
        sys.exit("%s received an Authorization that is not the credential fed at start" % name)
    if r["x_api_key"]:
        sys.exit("%s received the agent's x-api-key besides the credential" % name)
    if not (r["host"] or "").startswith("localhost"):
        sys.exit("%s received Host %r, not its own" % (name, r["host"]))
r = json.loads(open(tmp + "/anthropic.jsonl").read().splitlines()[-1])
if r["beta"] != "oauth-2025-04-20":
    sys.exit("the anthropic-beta header the subscription needs was not forwarded: %r" % r["beta"])
PY
}
check "a pass's request reaches its provider with its token replaced by the credential fed at start" ep_injects

ep_judgment_confined() {
  local judge before out
  judge=$(ep_admit '["anthropic"]')
  before=$(ep_records deepseek)
  out=$(ep_client connect "$EP_API" "$judge" "localhost:$EP_REGISTRY")
  case "$out" in "403 "* | 403) ;; *)
    echo "a judgment pass was not refused the registry: $out"
    return 1
    ;;
  esac
  ep_client api "$EP_API" "$judge" POST /chat/completions > /dev/null
  [ "$(ep_records deepseek)" = "$before" ] || {
    echo "a pass admitting Anthropic only reached DeepSeek"
    return 1
  }
  before=$(($(ep_records anthropic) + $(ep_records deepseek)))
  out=$(ep_client api "$EP_API" not-a-pass-token-at-all POST /v1/messages)
  case "$out" in "407 "*) ;; *)
    echo "an unknown token was not refused with 407: $out"
    return 1
    ;;
  esac
  out=$(ep_client api "$EP_API" "" POST /v1/messages)
  case "$out" in "407 "*) ;; *)
    echo "a request with no token was not refused with 407: $out"
    return 1
    ;;
  esac
  # A token that walks out of the directory: the admission it points at
  # exists, one level up.
  printf '{"admit": ["anthropic"]}\n' > "$EP_TMP/outside-token-file.json"
  out=$(ep_client api "$EP_API" "../outside-token-file" POST /v1/messages)
  case "$out" in "407 "*) ;; *)
    echo "a token naming a file outside the admissions directory was not refused: $out"
    return 1
    ;;
  esac
  [ "$(($(ep_records anthropic) + $(ep_records deepseek)))" = "$before" ] || {
    echo "a request with no admitted token reached a provider"
    return 1
  }
}
check "a judgment pass reaches its own provider only: not the registries, not the other provider; no admission, no request" ep_judgment_confined

ep_verify_registries() {
  local verify impl both before out
  verify=$(ep_admit '["registries"]')
  out=$(ep_client connect "$EP_API" "$verify" "localhost:$EP_REGISTRY")
  [ "$out" = "200 registry-ok" ] || {
    echo "verify did not reach the registry through a tunnel: $out"
    return 1
  }
  both=$(ep_admit '["anthropic", "deepseek"]')
  before=$(($(ep_records anthropic) + $(ep_records deepseek)))
  for token in "$verify" "$both"; do
    out=$(ep_client api "$EP_API" "$token" POST /v1/messages)
    case "$out" in "403 "*) ;; *)
      echo "a pass admitting no single provider was not refused a provider's API: $out"
      return 1
      ;;
    esac
  done
  [ "$(($(ep_records anthropic) + $(ep_records deepseek)))" = "$before" ] || {
    echo "verify's request, or one admitting two providers, reached a provider"
    return 1
  }
  impl=$(ep_admit '["anthropic", "registries"]')
  out=$(ep_client connect "$EP_API" "$impl" "localhost:$EP_REGISTRY")
  [ "$out" = "200 registry-ok" ] || {
    echo "an implement pass did not reach the registry: $out"
    return 1
  }
}
check "verify reaches the registries and no provider; an implement pass reaches the registries too" ep_verify_registries

ep_other_hosts() {
  local impl out
  impl=$(ep_admit '["deepseek", "registries"]')
  out=$(ep_client connect "$EP_API" "$impl" "localhost:$EP_UNLISTED")
  case "$out" in "403 "* | 403) ;; *)
    echo "CONNECT to a host on no list was not refused: $out"
    return 1
    ;;
  esac
  grep -q "refused.*localhost:$EP_UNLISTED" "$EP_TMP/main.log" || {
    echo "the refused CONNECT to localhost:$EP_UNLISTED is not in the proxy's log:"
    cat "$EP_TMP/main.log"
    return 1
  }
  out=$(ep_client absolute "$EP_API" "$impl" "http://localhost:$EP_REGISTRY/")
  case "$out" in "403 "*) ;; *)
    echo "a plain-HTTP proxy request for another host was not refused: $out"
    return 1
    ;;
  esac
  grep -q "refused.*http://localhost:$EP_REGISTRY/" "$EP_TMP/main.log" || {
    echo "the refused plain-HTTP proxy request is not in the proxy's log"
    return 1
  }
}
check "CONNECT, or a plain proxy request, to any host on no list is refused and logged" ep_other_hosts

ep_retire() {
  local judge out
  judge=$(ep_admit '["anthropic"]')
  rm "$EP_TMP/main.admit/$judge.json"
  out=$(ep_client api "$EP_API" "$judge" POST /v1/messages)
  case "$out" in "407 "*) ;; *)
    echo "a pass whose admission was deleted still reached its provider: $out"
    return 1
    ;;
  esac
}
check "a pass whose admission is deleted reaches nothing" ep_retire

# A run that never opted in hands the proxy no DeepSeek key, and then no pass
# reaches DeepSeek whatever its admission says. Started with a heartbeat
# window of two seconds, which the next case uses.
ep_optout() {
  local token before out
  ep_start_proxy optout "{\"anthropic\": $EP_ANTHROPIC}" 2 || return 1
  echo "$EP_PID" > "$EP_TMP/optout.pid"
  touch "$EP_TMP/optout.admit/heartbeat"
  token=$(ep_admit '["deepseek", "registries"]' optout)
  before=$(ep_records deepseek)
  out=$(ep_client api "$EP_API" "$token" POST /chat/completions)
  case "$out" in "403 "*) ;; *)
    echo "a pass admitting DeepSeek was forwarded by a proxy given no DeepSeek key: $out"
    return 1
    ;;
  esac
  [ "$(ep_records deepseek)" = "$before" ] || {
    echo "a proxy given no DeepSeek key reached DeepSeek"
    return 1
  }
}
check "a proxy given no DeepSeek key forwards nothing to DeepSeek, whatever a pass admits" ep_optout

ep_alive() { kill -0 "$1" 2> /dev/null; }

ep_heartbeat() {
  local pid
  pid=$(cat "$EP_TMP/optout.pid" 2> /dev/null) || {
    echo "the two-second proxy did not start (previous case)"
    return 1
  }
  # Beats every half second for four seconds, twice the window: alive
  # throughout. Each beat sets a new modification time explicitly, so it
  # changes whatever the filesystem's timestamp resolution.
  for i in 1 2 3 4 5 6 7 8; do
    touch -t "2001010101.0$i" "$EP_TMP/optout.admit/heartbeat"
    sleep 0.5
  done
  ep_alive "$pid" || {
    echo "the proxy exited although its heartbeat file changed every half second"
    return 1
  }
  # Then silence: gone within twice the window.
  for _ in $(seq 1 40); do
    ep_alive "$pid" || return 0
    sleep 0.1
  done
  echo "the proxy was still running four seconds after its last heartbeat, with a two-second window"
  return 1
}
check "the proxy runs while its heartbeat file changes and exits by itself when it stops" ep_heartbeat

# Last, so every case above has had its chance to write a copy somewhere.
ep_no_copy() {
  local found
  found=$(grep -rlF -e "$EP_CRED_ANTHROPIC" -e "$EP_CRED_DEEPSEEK" "$EP_TMP" 2> /dev/null)
  [ -z "$found" ] || {
    echo "a credential was written to: $found"
    return 1
  }
  [ -s "$EP_TMP/main.log" ] || {
    echo "the proxy logged nothing, so its log proves nothing"
    return 1
  }
}
check "no credential is in the proxy's log, any response, or any file it could write" ep_no_copy

[ -s "$EP_TMP/optout.pid" ] && EP_PIDS+=("$(cat "$EP_TMP/optout.pid")")
for pid in "${EP_PIDS[@]}"; do
  kill "$pid" 2> /dev/null
done
wait 2> /dev/null
rm -rf "$EP_TMP"
unset EP_TMP EP_ROOT EP_PIDS
