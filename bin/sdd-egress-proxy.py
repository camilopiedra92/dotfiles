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

    {"listen": "0.0.0.0:8080", "control_listen": "0.0.0.0:8081",
     "control_key": "<random>", "heartbeat_seconds": 60,
     "providers": {"claude":   {"upstream": "https://api.anthropic.com",
                                "credential": "<claude-oauth>"},
                   "deepseek": {"upstream": "https://api.deepseek.com",
                                "credential": "<deepseek-api>"}},
     "registries": ["registry.npmjs.org", "pypi.org:443"]}

A provider is present only when the run may use it: no DeepSeek key, no
DeepSeek pass. A registry without a port means 443. Once both ports are
bound it prints {"api_port": …, "control_port": …} on stdout.

Passes are keyed by a token the proxy issues. The run registers each pass on
the control port and hands the token to the pass as its placeholder
credential (CLAUDE_CODE_OAUTH_TOKEN, pi's apiKey) and as the user of its
HTTPS_PROXY URL, so the token alone decides where a request may go: a
judgment pass to its provider, an implement pass to its provider and the
registries, verify to the registries only. A token is worth nothing outside
this proxy and dies with the pass.

Control port, every request with `Authorization: Bearer <control_key>`:

    POST   /passes          {"name", "kind", "provider"} -> 201 {"token"}
    DELETE /passes/<token>  -> 204
    POST   /heartbeat       -> 204; the proxy exits after heartbeat_seconds
                               without one, so no credential outlives a run
                               whose sdd-run was killed
    GET    /models?provider=<p>  -> the provider's GET /models, fetched with
                               its credential, for the run's record of the
                               model behind each configured id (research R6)

The agents' firewall admits the API port only; the key guards the control
port as a second line.

Standard library only, Python 3.9 or later: it runs on the worker image's
Python and in this repository's checks on the host's.
"""

import base64
import hmac
import http.client
import http.server
import json
import os
import secrets
import select
import socket
import ssl
import sys
import threading
import time
import urllib.parse

KINDS = {
    # kind: (needs a provider, may reach the registries)
    "judgment": (True, False),
    "implement": (True, True),
    "verify": (False, True),
}

# Not forwarded: hop-by-hop headers, the agent's placeholder in any of the
# places a credential travels, and Host, which is the upstream's own.
DROPPED = {
    "host", "authorization", "x-api-key", "proxy-authorization",
    "connection", "keep-alive", "proxy-connection", "te", "trailer",
    "transfer-encoding", "upgrade", "content-length",
}


def log(message):
    # Tokens, keys and headers are never logged: a pass is named by the name
    # the run gave it.
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
            if url.scheme != "https" or not url.hostname or not p.get("credential"):
                raise ValueError("provider %s needs an https upstream and a credential" % name)
            self.providers[name] = (url.hostname, url.port or 443, p["credential"])
        self.registries = {hostport(r) for r in config.get("registries", [])}
        self.control_key = config["control_key"]
        self.heartbeat_seconds = float(config["heartbeat_seconds"])
        self.last_beat = time.monotonic()
        self.passes = {}
        self.lock = threading.Lock()

    def register(self, name, kind, provider):
        if kind not in KINDS:
            return None, "unknown kind %r" % kind
        if KINDS[kind][0] and provider not in self.providers:
            return None, "%s needs a provider this run holds a credential for, not %r" % (kind, provider)
        if not KINDS[kind][0] and provider is not None:
            return None, "%s reaches no provider" % kind
        token = secrets.token_urlsafe(32)
        with self.lock:
            self.passes[token] = {"name": str(name), "kind": kind, "provider": provider}
        return token, None

    def pass_for(self, token):
        with self.lock:
            return self.passes.get(token) if token else None


def bearer(headers):
    value = headers.get("Authorization") or ""
    if value.startswith("Bearer "):
        return value[len("Bearer "):]
    return headers.get("x-api-key")


def basic_user(headers):
    value = headers.get("Proxy-Authorization") or ""
    if not value.startswith("Basic "):
        return None
    try:
        return base64.b64decode(value[len("Basic "):]).decode().partition(":")[0]
    except (ValueError, UnicodeDecodeError):
        return None


def upstream(host, port):
    return http.client.HTTPSConnection(host, port, context=ssl.create_default_context(), timeout=600)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None  # set per server in serve()

    def log_message(self, *args):
        pass  # the default logs every request line; ours say only what is safe

    def refuse(self, status, why, who="no pass"):
        log("refused %s %s (%s): %s" % (self.command, self.path, who, why))
        body = (why + "\n").encode()
        self.send_response(status)
        if status == 407:
            self.send_header("Proxy-Authenticate", 'Basic realm="sdd"')
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else None


class ApiHandler(Handler):
    def forward(self):
        # An absolute URL is a plain-HTTP proxy request for another host:
        # nothing a pass may do.
        if not self.path.startswith("/"):
            p = self.state.pass_for(basic_user(self.headers))
            return self.refuse(403, "not a provider request", p["name"] if p else "no pass")
        p = self.state.pass_for(bearer(self.headers))
        if p is None:
            return self.refuse(407, "no pass with this token")
        if p["provider"] is None:
            return self.refuse(403, "%s reaches no provider" % p["kind"], p["name"])
        host, port, credential = self.state.providers[p["provider"]]
        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROPPED}
        headers["Authorization"] = "Bearer " + credential
        try:
            c = upstream(host, port)
            c.request(self.command, self.path, body=self.read_body(), headers=headers)
            r = c.getresponse()
        except (OSError, http.client.HTTPException) as e:
            log("pass=%s %s %s -> upstream error %s" % (p["name"], self.command, self.path.split("?")[0], type(e).__name__))
            return self.refuse(502, "upstream unreachable", p["name"])
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
        c.close()
        log("pass=%s %s %s -> %s %s" % (p["name"], self.command, self.path.split("?")[0], p["provider"], r.status))

    do_GET = do_POST = forward

    def refuse_method(self):
        self.refuse(405, "method not forwarded")

    do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = refuse_method

    def do_CONNECT(self):
        p = self.state.pass_for(basic_user(self.headers))
        if p is None:
            return self.refuse(407, "no pass with this token")
        if not KINDS[p["kind"]][1]:
            return self.refuse(403, "%s reaches no registry" % p["kind"], p["name"])
        target = hostport(self.path)
        if target not in self.state.registries:
            return self.refuse(403, "not a registry", p["name"])
        try:
            far = socket.create_connection(target, timeout=30)
        except OSError as e:
            log("pass=%s CONNECT %s -> error %s" % (p["name"], self.path, type(e).__name__))
            return self.refuse(502, "registry unreachable", p["name"])
        self.send_response(200, "Connection Established")
        self.end_headers()
        log("pass=%s CONNECT %s -> tunnel" % (p["name"], self.path))
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


class ControlHandler(Handler):
    def authorized(self):
        given = (bearer(self.headers) or "").encode()
        if hmac.compare_digest(given, self.state.control_key.encode()):
            return True
        self.refuse(401, "control key required", "control")
        return False

    def reply(self, status, obj=None):
        body = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.authorized():
            return
        if self.path == "/heartbeat":
            self.state.last_beat = time.monotonic()
            return self.reply(204)
        if self.path != "/passes":
            return self.refuse(404, "no such control endpoint", "control")
        try:
            req = json.loads(self.read_body() or b"{}")
            token, why = self.state.register(req["name"], req["kind"], req.get("provider"))
        except (ValueError, KeyError, TypeError) as e:
            token, why = None, "bad request: %s" % type(e).__name__
        if token is None:
            return self.refuse(400, why, "control")
        log("pass=%s registered: %s %s" % (req["name"], req["kind"], req.get("provider") or "no provider"))
        self.reply(201, {"token": token})

    def do_DELETE(self):
        if not self.authorized():
            return
        if not self.path.startswith("/passes/"):
            return self.refuse(404, "no such control endpoint", "control")
        with self.state.lock:
            p = self.state.passes.pop(self.path[len("/passes/"):], None)
        if p:
            log("pass=%s retired" % p["name"])
        self.reply(204)

    def do_GET(self):
        if not self.authorized():
            return
        url = urllib.parse.urlsplit(self.path)
        provider = urllib.parse.parse_qs(url.query).get("provider", [None])[0]
        if url.path != "/models" or provider not in self.state.providers:
            return self.refuse(404, "no such control endpoint or provider", "control")
        host, port, credential = self.state.providers[provider]
        try:
            c = upstream(host, port)
            c.request("GET", "/models", headers={"Authorization": "Bearer " + credential})
            r = c.getresponse()
            body = r.read()
        except (OSError, http.client.HTTPException) as e:
            log("control GET /models %s -> upstream error %s" % (provider, type(e).__name__))
            return self.refuse(502, "upstream unreachable", "control")
        log("control GET /models %s -> %s" % (provider, r.status))
        self.send_response(r.status)
        self.send_header("Content-Type", r.getheader("Content-Type") or "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(address, handler, state):
    cls = type(handler.__name__, (handler,), {"state": state})
    server = http.server.ThreadingHTTPServer(hostport(address), cls)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    # One line, read once: the credentials live in this process's memory and
    # nowhere else.
    config = json.loads(sys.stdin.readline())
    state = State(config)
    api = serve(config["listen"], ApiHandler, state)
    control = serve(config["control_listen"], ControlHandler, state)
    del config
    print(json.dumps({"api_port": api.server_address[1], "control_port": control.server_address[1]}), flush=True)
    log("ready: providers %s, %d registries" % (", ".join(sorted(state.providers)) or "none", len(state.registries)))
    while time.monotonic() - state.last_beat < state.heartbeat_seconds:
        time.sleep(min(1.0, state.heartbeat_seconds / 4))
    log("no heartbeat for %ss: exiting" % state.heartbeat_seconds)
    # os._exit, not sys.exit: a tunnel or a streamed answer in another thread
    # must not keep the credentials alive past the window.
    os._exit(0)


if __name__ == "__main__":
    main()
