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
# own for tests -- and stand-in registries serving HTTPS the same way, which
# the proxy reaches over verified TLS once it has terminated a pass's
# CONNECT with the certificate its own authority signed (FR-031, R25): the
# client in these cases trusts that authority alone, so a 200 through a
# CONNECT proves the proxy, not the registry, answered the handshake. Passes are admitted as the run admits them: a file per
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

# A stand-in registry over HTTPS: answers every method with "registry-ok",
# so a refusal can only come from the proxy, and records each request it
# gets as a line of JSON.
cat > "$EP_TMP/helpers/registry.py" << 'PY'
import http.server, json, ssl, sys
portfile, cert, key, record = sys.argv[1:5]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _serve(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        with open(record, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "host": self.headers.get("Host"),
                                "headers": dict(self.headers.items())}) + "\n")
        out = b"registry-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)
    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = _serve
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
s.socket = ctx.wrap_socket(s.socket, server_side=True)
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
elif cmd == "connect":  # connect PORT TOKEN HOST:PORT CAFILE [METHOD PATH]
    # CONNECT, then TLS trusting CAFILE alone -- the authority the proxy
    # printed -- then one request: "<status> <body>", or the CONNECT's own
    # status when it is refused, or "tls <error>" when the handshake fails.
    import ssl
    token, target, cafile = sys.argv[3:6]
    method, path = sys.argv[6], sys.argv[7]
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    auth = base64.b64encode((token + ":x").encode()).decode()
    s.sendall(("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n" % (target, target, auth)).encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(1)
        if not chunk:
            break
        data += chunk
    status = data.split(b" ")[1].decode() if data else "none"
    if status != "200":
        print(status)
        sys.exit(0)
    host = target.rpartition(":")[0]
    try:
        t = ssl.create_default_context(cafile=cafile).wrap_socket(s, server_hostname=host)
    except (ssl.SSLError, OSError) as e:
        print("tls", type(e).__name__)
        sys.exit(0)
    c = http.client.HTTPConnection(host, timeout=10)
    c.sock = t
    # Headers a read could carry data out in; the proxy sends none of them on.
    smuggle = {"User-Agent": "agent-SMUGGLE", "Cookie": "c=SMUGGLE", "X-HTTP-Method-Override": "PUT",
               "Referer": "https://SMUGGLE.example/"}
    c.request(method, path, body=b"x" if method in ("POST", "PUT", "PATCH") else None, headers=smuggle)
    r = c.getresponse()
    print(r.status, r.read().decode(errors="replace").strip())
    if len(sys.argv) > 8:  # a retire file: delete it, then a second read in the same tunnel
        import os
        os.remove(sys.argv[8])
        c.request(method, path)
        r = c.getresponse()
        print(r.status, r.read().decode(errors="replace").strip())
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
  # The GitHub stand-in carries github.com's path rule (R25), configured as
  # sdd-step egress-proxy configures it for github.com.
  printf '{"listen": "127.0.0.1:0", "admissions": "%s", "heartbeat_seconds": %s, "providers": %s, "registries": ["localhost:%s", "localhost:%s", "localhost:%s"], "paths": {"localhost:%s": %s}}\n' \
    "$EP_TMP/$label.admit" "$3" "$2" "$EP_REGISTRY" "$EP_GITHUB" "$EP_ROGUE" "$EP_GITHUB" "$(ep_rule github.com)" |
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
  # The authority the proxy made at its start, as the run writes it to the
  # bundle; empty when the ready line carries none.
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ca", ""), end="")' "$EP_TMP/$label.ready" > "$EP_TMP/$label.ca"
}

# Every answer is kept, so the last case's grep covers the responses too.
ep_client() {
  [ -n "$2" ] || {
    echo "no port to reach: the proxy did not start"
    return 1
  }
  python3 -I "$EP_TMP/helpers/client.py" "$@" | tee -a "$EP_TMP/responses.log"
}

# A pass's request to a registry through the main proxy, trusting the
# authority it printed: ep_connect <token> <port> [<method> <path>].
ep_connect() {
  ep_client connect "$EP_API" "$1" "localhost:$2" "$EP_TMP/main.ca" "${3:-GET}" "${4:-/}" ${5:+"$5"}
}

# The path rules the run gives the proxy, read from sdd-pass.py, so the
# checks below test the rules in use, not a copy.
ep_rule() {
  python3 -I -c 'import ast, json, sys
tree = ast.parse(open(sys.argv[1]).read())
rules = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "REGISTRY_PATHS")
print(json.dumps(rules[sys.argv[2]]))' "$EP_ROOT/bin/sdd-pass.py" "$1"
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
      "$EP_TMP/$name.port" "$EP_TMP/$name.jsonl" > /dev/null 2>> "$EP_TMP/standins.err" &
    EP_PIDS+=($!)
  done
  # A certificate the proxy does not trust, for a registry it must not
  # forward to: the upstream side of the inspection is verified TLS.
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$EP_TMP/cert.cnf" \
    -keyout "$EP_TMP/rogue-key.pem" -out "$EP_TMP/rogue-cert.pem" > /dev/null 2>&1 || {
    echo "could not make the rogue registry's certificate"
    return 1
  }
  python3 -I "$EP_TMP/helpers/registry.py" "$EP_TMP/registry.port" "$EP_TMP/cert.pem" "$EP_TMP/key.pem" "$EP_TMP/registry.jsonl" > /dev/null 2>> "$EP_TMP/standins.err" &
  EP_PIDS+=($!)
  # A registry with github.com's path rule.
  python3 -I "$EP_TMP/helpers/registry.py" "$EP_TMP/github.port" "$EP_TMP/cert.pem" "$EP_TMP/key.pem" "$EP_TMP/github.jsonl" > /dev/null 2>> "$EP_TMP/standins.err" &
  EP_PIDS+=($!)
  python3 -I "$EP_TMP/helpers/registry.py" "$EP_TMP/rogue.port" "$EP_TMP/rogue-cert.pem" "$EP_TMP/rogue-key.pem" "$EP_TMP/rogue.jsonl" > /dev/null 2>> "$EP_TMP/standins.err" &
  EP_PIDS+=($!)
  # A registry listening but on no list: a refusal must come from the
  # proxy's list, not from nothing being there.
  python3 -I "$EP_TMP/helpers/registry.py" "$EP_TMP/unlisted.port" "$EP_TMP/cert.pem" "$EP_TMP/key.pem" "$EP_TMP/unlisted.jsonl" > /dev/null 2>> "$EP_TMP/standins.err" &
  EP_PIDS+=($!)
  for name in anthropic deepseek registry github rogue unlisted; do
    ep_wait_for "$EP_TMP/$name.port" || {
      # What it said, and with which interpreter, so a failure on another
      # machine (CI) explains itself.
      echo "the $name stand-in did not start ($(command -v python3), $(python3 -I -c 'import ssl, sys; print(sys.version.split()[0], ssl.OPENSSL_VERSION)')):"
      cat "$EP_TMP/standins.err"
      return 1
    }
  done
  EP_REGISTRY=$(cat "$EP_TMP/registry.port")
  EP_UNLISTED=$(cat "$EP_TMP/unlisted.port")
  EP_GITHUB=$(cat "$EP_TMP/github.port")
  EP_ROGUE=$(cat "$EP_TMP/rogue.port")
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
  out=$(ep_connect "$judge" "$EP_REGISTRY")
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
  out=$(ep_connect "$verify" "$EP_REGISTRY")
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
  out=$(ep_connect "$impl" "$EP_REGISTRY")
  [ "$out" = "200 registry-ok" ] || {
    echo "an implement pass did not reach the registry: $out"
    return 1
  }
}
check "verify reaches the registries and no provider; an implement pass reaches the registries too" ep_verify_registries

ep_other_hosts() {
  local impl out
  impl=$(ep_admit '["deepseek", "registries"]')
  out=$(ep_connect "$impl" "$EP_UNLISTED")
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

# The registries are read-only (FR-031, R25): the proxy answers each pass's
# CONNECT with a certificate its own authority signed -- made at its start,
# its key in no file once it has started and in no output -- and forwards
# only GET and HEAD, over verified TLS, to the real registry; on github.com
# only release and archive downloads. Every other request is refused with
# 403, never reaches the registry, and leaves a line in the log.
ep_registry_readonly() {
  local impl verify method out path
  [ -s "$EP_TMP/main.ca" ] || {
    echo "the ready line carries no certificate authority"
    return 1
  }
  openssl x509 -in "$EP_TMP/main.ca" -noout -text 2> /dev/null | grep -q "CA:TRUE" || {
    echo "the ready line's certificate is not a certificate authority"
    return 1
  }
  # Constrained to the registries' names: were its key to leak, the
  # authority could vouch for no other host (review of Phase 2b).
  openssl x509 -in "$EP_TMP/main.ca" -noout -text 2> /dev/null | grep -q "X509v3 Name Constraints: critical" || {
    echo "the run's authority carries no critical name constraints"
    return 1
  }
  openssl x509 -in "$EP_TMP/main.ca" -noout -text 2> /dev/null | grep -A3 "Permitted:" | grep -q "DNS:localhost" || {
    echo "the run's authority does not permit its registries' names"
    return 1
  }
  # A name type the constraints leave out is unconstrained (RFC 5280): with
  # no registry at an address, every address is excluded.
  openssl x509 -in "$EP_TMP/main.ca" -noout -text 2> /dev/null | grep -A4 "Excluded:" | grep -q "IP:0.0.0.0/0.0.0.0" || {
    echo "the run's authority leaves IP addresses unconstrained"
    return 1
  }
  impl=$(ep_admit '["deepseek", "registries"]')
  verify=$(ep_admit '["registries"]')
  for method in GET HEAD; do
    out=$(ep_connect "$impl" "$EP_REGISTRY" "$method" /left-pad)
    case "$out" in "200"*) ;; *)
      echo "$method through the inspected tunnel answered: $out"
      return 1
      ;;
    esac
  done
  out=$(ep_connect "$verify" "$EP_REGISTRY" GET /six)
  [ "$out" = "200 registry-ok" ] || {
    echo "verify's GET through the inspected tunnel answered: $out"
    return 1
  }
  for method in PUT POST DELETE PATCH OPTIONS; do
    out=$(ep_connect "$impl" "$EP_REGISTRY" "$method" /left-pad)
    case "$out" in "403 "*) ;; *)
      echo "$method to a registry was not refused with 403: $out"
      return 1
      ;;
    esac
    grep -q "refused $method https://localhost:$EP_REGISTRY/left-pad" "$EP_TMP/main.log" || {
      echo "the refused $method is not in the proxy's log"
      return 1
    }
  done
  grep -qvE '"method": "(GET|HEAD)"' "$EP_TMP/registry.jsonl" && {
    echo "a write reached the registry: $(grep -vE '"method": "(GET|HEAD)"' "$EP_TMP/registry.jsonl" | head -1)"
    return 1
  }
  for path in /o/r/releases/download/v1/tool.tgz /o/r/archive/v1.tar.gz; do
    out=$(ep_connect "$impl" "$EP_GITHUB" GET "$path")
    [ "$out" = "200 registry-ok" ] || {
      echo "a GitHub download, $path, answered: $out"
      return 1
    }
  done
  for path in /o/r /o/r/info/refs?service=git-receive-pack /o/r/issues /o/r/releases; do
    out=$(ep_connect "$impl" "$EP_GITHUB" GET "$path")
    case "$out" in "403 "*) ;; *)
      echo "GET $path on GitHub was not refused: $out"
      return 1
      ;;
    esac
  done
  out=$(ep_connect "$impl" "$EP_GITHUB" POST /o/r/git-receive-pack)
  case "$out" in "403 "*) ;; *)
    echo "a push to GitHub was not refused: $out"
    return 1
    ;;
  esac
  out=$(ep_connect "$impl" "$EP_ROGUE" GET /left-pad)
  case "$out" in "502 "*) ;; *)
    echo "a registry whose certificate the proxy does not trust was forwarded to: $out"
    return 1
    ;;
  esac
  [ ! -s "$EP_TMP/rogue.jsonl" ] || {
    echo "a request reached the registry whose certificate the proxy does not trust"
    return 1
  }
  if grep -q "PRIVATE KEY" "$EP_TMP/main.ready" "$EP_TMP/main.log"; then
    echo "the authority's key is in the proxy's output"
    return 1
  fi
  local left
  left=$(grep -rl "PRIVATE KEY" "$EP_TMP" 2> /dev/null | grep -v -e "^$EP_TMP/key.pem$" -e "^$EP_TMP/rogue-key.pem$")
  [ -z "$left" ] || {
    echo "a private key the proxy made is on disk after its start: $left"
    return 1
  }
}
check "the registries are read-only: TLS inspected with the run's own authority, GET and HEAD only, GitHub downloads only" ep_registry_readonly

# Review of Phase 2b: GitHub's rule holds on the path alone — a query, a dot
# segment or an encoded dot or slash cannot carry a request past it; a read
# carries none of the agent's headers but the ones a download needs; a token
# retired while its tunnel is open reaches nothing more; and codeload, where
# GitHub's archives redirect, allows archives only.
ep_registry_hardened() {
  local impl out path retire
  impl=$(ep_admit '["deepseek", "registries"]')
  for path in "/o/r?/archive/" "/settings?a/x/archive/" "/o/r/archive/%2e%2e/%2e%2e/o2/r2.git/info/refs" \
    "/o/r/releases/download/../../../x" "/o/r/archive/%2F..%2Fx" "/o/r/archive/./x" "/o/r/releases/download/v1/%2E%2E/x" \
    "/o/r/archive/%252e%252e/x" "/o/r/archive/..;/..;/x" "/o/r;x/archive/y" "/o/r/archive/x#/../../y" \
    "/o/r/archive/%ef%bc%8e%ef%bc%8e/x"; do
    out=$(ep_connect "$impl" "$EP_GITHUB" GET "$path")
    case "$out" in "403 "*) ;; *)
      echo "GET $path on GitHub was not refused: $out"
      return 1
      ;;
    esac
  done
  out=$(ep_connect "$impl" "$EP_GITHUB" GET "/o/r/releases/download/v1/tool.tgz?x=1")
  [ "$out" = "200 registry-ok" ] || {
    echo "a GitHub download with a query was refused: $out"
    return 1
  }
  grep -q SMUGGLE "$EP_TMP/registry.jsonl" && {
    echo "an agent's header reached a registry: $(grep SMUGGLE "$EP_TMP/registry.jsonl" | head -1)"
    return 1
  }
  python3 -I -c 'import json, sys
last = [json.loads(l) for l in open(sys.argv[1])][-1]["headers"]
ua = {k.lower(): v for k, v in last.items()}.get("user-agent")
sys.exit(0 if ua == "sdd-egress-proxy" else "a read reached the registry with User-Agent %r, not the proxy'"'"'s" % ua)' "$EP_TMP/registry.jsonl" || return 1
  retire=$(ep_admit '["registries"]')
  out=$(ep_connect "$retire" "$EP_REGISTRY" GET /six "$EP_TMP/main.admit/$retire.json")
  case "$out" in "200 registry-ok"*"407 "* | "200 registry-ok"*"403 "*) ;; *)
    echo "a token retired inside its open tunnel still read: $out"
    return 1
    ;;
  esac
  # -B: importing the proxy must not leave its bytecode in bin/.
  python3 -I -B - "$EP_ROOT/bin/sdd-egress-proxy.py" "$(ep_rule codeload.github.com)" << 'PY' || return 1
import importlib.util, json, re, sys
spec = importlib.util.spec_from_file_location("proxy", sys.argv[1])
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)
rule = re.compile(json.loads(sys.argv[2]))
bad = []
for path in ("/o/r/tar.gz/refs/tags/v1", "/o/r/zip/refs/heads/main", "/o/r/legacy.tar.gz/refs/tags/v1"):
    if not proxy.path_allowed(rule, path):
        bad.append("codeload refused the archive %s" % path)
for path in ("/o/r", "/o/r?/tar.gz/", "/o/r/tar.gz/../../x"):
    if proxy.path_allowed(rule, path):
        bad.append("codeload allowed %s" % path)
sys.exit("\n".join(bad) or 0)
PY
  [ ! -e "$EP_ROOT/bin/__pycache__" ] || {
    echo "importing the proxy left bin/__pycache__ behind"
    return 1
  }
}
check "a registry's rule holds on the path alone, no agent header rides a read, a retired token's tunnel goes dark" ep_registry_hardened

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

# Seen with real Claude Code, 2026-10-21: a client refused a CONNECT resets
# the connection, and the server's default error handler printed a traceback
# for each. A reset is the client's business: one log line, no traceback.
ep_reset_quiet() {
  [ -n "${EP_API:-}" ] || {
    echo "no port to reach: the proxy did not start"
    return 1
  }
  python3 -I - "$EP_API" << 'PY' || return 1
import socket, struct, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\nProxy-Authorization: Bearer unknownTOKEN0123456789\r\n\r\n")
s.recv(4096)
# SO_LINGER 0: close sends a reset instead of a FIN, as the agent's client did.
s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
s.close()
PY
  sleep 0.5
  ! grep -q "Traceback" "$EP_TMP/main.log" || {
    echo "a client's reset printed a traceback in the proxy's log:"
    grep -B2 -A3 "Traceback" "$EP_TMP/main.log" | head -12
    return 1
  }
}
check "a client resetting its connection leaves one line in the log, not a traceback" ep_reset_quiet

# Only the endpoints the agents call carry the owner's credential: Claude
# Code's messages (and token counting), DeepSeek's chat completions. Anything
# else on the provider's host — key minting, batches, files, admin — is
# refused (review of Phase 2). A body sent chunked is refused too, rather
# than forwarded without it.
ep_paths() {
  local judge impl out case method path
  judge=$(ep_admit '["anthropic"]')
  impl=$(ep_admit '["deepseek", "registries"]')
  for case in "GET /v1/organizations" "POST /v1/messages/batches" "POST /v1/files" "GET /api/oauth/profile" "POST /v1/messagesX"; do
    read -r method path <<< "$case"
    out=$(ep_client api "$EP_API" "$judge" "$method" "$path")
    case "$out" in "403 "*) ;; *)
      echo "anthropic $case was not refused: $out"
      return 1
      ;;
    esac
  done
  for case in "POST /v1/messages" "POST /v1/messages?beta=true" "POST /v1/messages/count_tokens?beta=true"; do
    read -r method path <<< "$case"
    out=$(ep_client api "$EP_API" "$judge" "$method" "$path")
    case "$out" in "403 "*)
      echo "anthropic $case was refused: $out"
      return 1
      ;;
    esac
  done
  for case in "POST /user/balance" "GET /v1/models" "POST /beta/completions"; do
    read -r method path <<< "$case"
    out=$(ep_client api-key "$EP_API" "$impl" "$method" "$path")
    case "$out" in "403 "*) ;; *)
      echo "deepseek $case was not refused: $out"
      return 1
      ;;
    esac
  done
  grep -q "refused GET /v1/organizations" "$EP_TMP/main.log" || {
    echo "a refused endpoint is not in the log"
    return 1
  }
  out=$(
    python3 -I - "$EP_API" "$judge" << 'PY'
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=10)
c.putrequest("POST", "/v1/messages")
c.putheader("Authorization", "Bearer " + sys.argv[2])
c.putheader("Transfer-Encoding", "chunked")
c.endheaders()
c.send(b"2\r\n{}\r\n0\r\n\r\n")
r = c.getresponse()
print(r.status)
PY
  )
  [ "$out" = 411 ] || {
    echo "a chunked request body was not refused with 411: $out"
    return 1
  }
}
check "only the agents' endpoints reach a provider, and a chunked body is refused" ep_paths

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
