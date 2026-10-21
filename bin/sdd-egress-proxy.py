#!/usr/bin/env python3
"""The egress proxy of a routed Spec Kit run (specs/003-sdd-model-routing,
contracts/pass.md "The egress proxy", research R23).

Every agent container's firewall allows this proxy and nothing else. It holds
the run's provider credentials -- no agent does -- and:

- forwards plain-HTTP requests to the provider of the pass that sent them,
  over TLS, with the pass's token replaced by the provider's credential;
- tunnels CONNECT to the package registries for implement and verify passes;
- refuses and logs everything else.

Started by `sdd-step egress-proxy` in a container of its own, it reads ONE
line of JSON from stdin and nothing after it:

    {"listen": "0.0.0.0:8080", "admissions": "/admissions",
     "heartbeat_seconds": 60,
     "providers": {"anthropic": {"upstream": "https://api.anthropic.com",
                                 "credential": "<claude-oauth>"},
                   "deepseek":  {"upstream": "https://api.deepseek.com",
                                 "credential": "<deepseek-api>",
                                 "models": "/models"}},
     "registries": ["registry.npmjs.org", "pypi.org:443"]}

A provider is present only when the run may use it: no DeepSeek key, no
DeepSeek pass. A registry without a port means 443. Once listening, it
fetches each provider's `models` path, if it names one, with its credential
and prints one line on stdout: {"api_port": …, "models": {"deepseek": <the
answer, or {"error": …}>}} -- the run records the model behind each
configured id from it (research R6).

Passes are keyed by a random token the pass makes: the placeholder
credential its agent sends (`Authorization: Bearer` or `x-api-key` for an
API request, `Proxy-Authorization` Basic user or Bearer on CONNECT). Before
its agent starts, the pass writes `$SDD_RUN_DIR/admissions/<token>.json` =
{"admit": [...]}, any of "anthropic", "deepseek", "registries", and deletes
it afterwards; that directory is mounted read-only at `admissions`, and the
proxy reads the token's file on every request, so an unknown or retired
token reaches nothing. An API request goes to the one provider its pass
admits -- none, or two, is refused. The run's heartbeat is that directory's
`heartbeat` file: the proxy exits once its modification time has not changed
for `heartbeat_seconds`, so no credential outlives a run whose sdd-run was
killed. A change, not a timestamp, is what counts: the host's clock and the
container's need not agree.

Standard library only, Python 3.9 or later: it runs on the worker image's
Python and in this repository's checks on the host's.
"""

import base64
import http.client
import http.server
import json
import os
import re
import select
import socket
import ssl
import sys
import threading
import time
import urllib.parse

ADMITS = {"anthropic", "deepseek", "registries"}

# A token names a file, so only what the run's tokens are made of is read:
# no separator, no dot, nothing that walks out of the directory.
TOKEN = re.compile(r"[A-Za-z0-9_-]{16,128}")

# Not forwarded: hop-by-hop headers, the agent's placeholder in any of the
# places a credential travels, and Host, which is the upstream's own.
DROPPED = {
    "host", "authorization", "x-api-key", "proxy-authorization",
    "connection", "keep-alive", "proxy-connection", "te", "trailer",
    "transfer-encoding", "upgrade", "content-length",
}


def log(message):
    # Tokens, credentials and headers are never logged: a pass is named by
    # the first characters of its token, enough to tell passes apart.
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    sys.stderr.write("%s %s\n" % (stamp, message))
    sys.stderr.flush()


def hostport(entry):
    host, sep, port = entry.rpartition(":")
    return (host, int(port)) if sep and port.isdigit() else (entry, 443)


class State:
    def __init__(self, config):
        self.providers = {}
        for name, p in config["providers"].items():
            url = urllib.parse.urlsplit(p["upstream"])
            # TLS only: a credential never crosses a network in clear.
            if name not in ADMITS - {"registries"} or url.scheme != "https" or not url.hostname or not p.get("credential"):
                raise ValueError("provider %r needs a known name, an https upstream and a credential" % name)
            self.providers[name] = (url.hostname, url.port or 443, p["credential"], p.get("models"))
        self.registries = {hostport(r) for r in config.get("registries", [])}
        self.admissions = config["admissions"]
        self.heartbeat_seconds = float(config["heartbeat_seconds"])

    def admitted(self, token):
        """The set a pass admits, or None for no such pass."""
        if not token or not TOKEN.fullmatch(token):
            return None
        try:
            with open(os.path.join(self.admissions, token + ".json")) as f:
                admit = json.load(f)["admit"]
        except (OSError, ValueError, KeyError, TypeError):
            return None
        if not isinstance(admit, list) or not set(admit) <= ADMITS:
            return None
        return set(admit)

    def heartbeat(self):
        try:
            return os.stat(os.path.join(self.admissions, "heartbeat")).st_mtime_ns
        except OSError:
            return None


def bearer(headers, name):
    value = headers.get(name) or ""
    return value[len("Bearer "):] if value.startswith("Bearer ") else None


def api_token(headers):
    return bearer(headers, "Authorization") or headers.get("x-api-key")


def proxy_token(headers):
    value = headers.get("Proxy-Authorization") or ""
    if value.startswith("Basic "):
        try:
            return base64.b64decode(value[len("Basic "):]).decode().partition(":")[0]
        except (ValueError, UnicodeDecodeError):
            return None
    return bearer(headers, "Proxy-Authorization")


# The only requests that carry the owner's credential, by provider: what
# Claude Code and pi call (seen 2026-10-21: Claude Code's POST /v1/messages;
# pi's POST /chat/completions). Anything else on the provider's host — keys,
# batches, files, admin — is refused, so a pass cannot mint or spend beyond
# its own conversation (review of Phase 2). A refusal is logged, so an agent
# that needs a new endpoint shows up there.
ENDPOINTS = {
    "anthropic": {("POST", "/v1/messages"), ("POST", "/v1/messages/count_tokens")},
    "deepseek": {("POST", "/chat/completions")},
}


def who(token):
    return "pass " + token[:6] if token and TOKEN.fullmatch(token) else "no pass"


def upstream(host, port):
    return http.client.HTTPSConnection(host, port, context=ssl.create_default_context(), timeout=600)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None  # set in serve()
    # A client that stops sending is dropped instead of holding a thread for
    # good; long enough for a slow upload of a large prompt.
    timeout = 300

    def log_message(self, *args):
        pass  # the default logs every request line; ours say only what is safe

    def refuse(self, status, why, token=None):
        log("refused %s %s (%s): %s" % (self.command, self.path, who(token), why))
        body = (why + "\n").encode()
        self.send_response(status)
        if status == 407:
            self.send_header("Proxy-Authenticate", 'Basic realm="sdd"')
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def forward(self):
        # An absolute URL is a plain-HTTP proxy request for another host:
        # nothing a pass may do.
        if not self.path.startswith("/"):
            return self.refuse(403, "not a provider request", proxy_token(self.headers))
        token = api_token(self.headers)
        admit = self.state.admitted(token)
        if admit is None:
            return self.refuse(407, "no pass with this token", token)
        providers = admit & set(self.state.providers)
        if len(providers) != 1 or len(admit - {"registries"}) != 1:
            return self.refuse(403, "the pass admits no single provider this run holds", token)
        name = providers.pop()
        if (self.command, self.path.split("?")[0]) not in ENDPOINTS.get(name, set()):
            return self.refuse(403, "not an endpoint the agents use", token)
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            # Bodies are read by Content-Length; the agents send one.
            return self.refuse(411, "a chunked body is not forwarded", token)
        host, port, credential, _ = self.state.providers[name]
        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROPPED}
        headers["Authorization"] = "Bearer " + credential
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        c = upstream(host, port)
        try:
            self.relay(c, body, headers, token, name)
        finally:
            # Also when the agent hangs up mid-stream (review of Phase 2).
            c.close()

    def relay(self, c, body, headers, token, name):
        try:
            c.request(self.command, self.path, body=body, headers=headers)
            r = c.getresponse()
        except (OSError, http.client.HTTPException) as e:
            log("%s %s %s -> upstream error %s" % (who(token), self.command, self.path.split("?")[0], type(e).__name__))
            return self.refuse(502, "upstream unreachable", token)
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in DROPPED:
                self.send_header(k, v)
        # Re-chunked as it arrives, so a streamed answer streams through.
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        while True:
            chunk = r.read1(65536)
            if not chunk:
                break
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        log("%s %s %s -> %s %s" % (who(token), self.command, self.path.split("?")[0], name, r.status))

    do_GET = do_POST = forward

    def refuse_method(self):
        self.refuse(405, "method not forwarded")

    do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = refuse_method

    def do_CONNECT(self):
        token = proxy_token(self.headers)
        admit = self.state.admitted(token)
        if admit is None:
            return self.refuse(407, "no pass with this token", token)
        if "registries" not in admit:
            return self.refuse(403, "the pass admits no registry", token)
        target = hostport(self.path)
        if target not in self.state.registries:
            return self.refuse(403, "not a registry", token)
        try:
            far = socket.create_connection(target, timeout=30)
        except OSError as e:
            log("%s CONNECT %s -> error %s" % (who(token), self.path, type(e).__name__))
            return self.refuse(502, "registry unreachable", token)
        self.send_response(200, "Connection Established")
        self.end_headers()
        log("%s CONNECT %s -> tunnel" % (who(token), self.path))
        self.close_connection = True
        near = self.connection
        try:
            while True:
                ready, _, _ = select.select([near, far], [], [], 600)
                if not ready:
                    return
                for s in ready:
                    data = s.recv(65536)
                    if not data:
                        return
                    (far if s is near else near).sendall(data)
        except OSError:
            pass
        finally:
            far.close()


def models(state):
    out = {}
    for name, (host, port, credential, path) in sorted(state.providers.items()):
        if not path:
            continue
        try:
            c = upstream(host, port)
            c.request("GET", path, headers={"Authorization": "Bearer " + credential})
            r = c.getresponse()
            body = r.read()
            out[name] = json.loads(body) if r.status == 200 else {"error": "HTTP %d" % r.status}
        except (OSError, ValueError, http.client.HTTPException) as e:
            out[name] = {"error": type(e).__name__}
        log("GET %s %s -> %s" % (name, path, "ok" if "error" not in out[name] else out[name]["error"]))
    return out


class Server(http.server.ThreadingHTTPServer):
    # A client that resets its connection (Claude Code does, after a refused
    # CONNECT; seen 2026-10-21) is not the proxy's error: one line, where the
    # default handler printed a traceback per reset.
    def handle_error(self, request, client_address):
        err = sys.exc_info()[1]
        if isinstance(err, (ConnectionResetError, BrokenPipeError)):
            log("connection from %s closed by the client" % client_address[0])
        else:
            log("error serving %s: %s" % (client_address[0], type(err).__name__))


def main():
    # One line, read once: the credentials live in this process's memory and
    # nowhere else.
    config = json.loads(sys.stdin.readline())
    state = State(config)
    cls = type("ApiHandler", (Handler,), {"state": state})
    server = Server(hostport(config["listen"]), cls)
    server.daemon_threads = True
    del config
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"api_port": server.server_address[1], "models": models(state)}), flush=True)
    log("ready: providers %s, %d registries" % (", ".join(sorted(state.providers)) or "none", len(state.registries)))
    seen, since = state.heartbeat(), time.monotonic()
    while time.monotonic() - since < state.heartbeat_seconds:
        time.sleep(min(1.0, state.heartbeat_seconds / 8))
        beat = state.heartbeat()
        if beat != seen:
            seen, since = beat, time.monotonic()
    log("no heartbeat for %ss: exiting" % state.heartbeat_seconds)
    # os._exit, not sys.exit: a tunnel or a streamed answer in another thread
    # must not keep the credentials alive past the window.
    os._exit(0)


if __name__ == "__main__":
    main()
