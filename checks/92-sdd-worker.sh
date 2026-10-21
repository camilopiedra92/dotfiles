# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── SDD worker ───────────────────────────────────────────────────────────────
printf '\n%sSDD worker%s\n' "$DIM" "$OFF"

# The worker container's firewall and entrypoint (specs/003-sdd-model-routing,
# contracts/pass.md, research R5, R23) run against stand-ins that record every
# call: iptables and ip6tables, the resolvers and ipset the firewall must never
# need (names are resolved by the egress proxy, so no DNS leaves the container),
# setpriv for the drop to `node`, and getent for node's home. Nothing here
# touches this machine's network: the real firewall is seen working only in
# the image (T016's smoke run, recorded in research R5).

# A recorder for every stand-in: one line per call, "<name> <args>", to $LOG.
# `iptables -S OUTPUT` answers the policy $READBACK names (DROP unless set),
# and a call whose line equals $FAIL_ON fails, so a failing rule can be staged.
sdd_worker_stubs() {
  local bin=$1 name
  mkdir -p "$bin"
  cat > "$bin/rec" << 'STUB'
#!/usr/bin/env bash
name=$(basename "$0")
line="$name $*"
printf '%s\n' "$line" >> "$LOG"
[ "$line" != "${FAIL_ON:-}" ] || exit 1
case "$line" in
  "iptables -S OUTPUT" | "ip6tables -S OUTPUT") echo "-P OUTPUT ${READBACK:-DROP}" ;;
esac
exit 0
STUB
  chmod +x "$bin/rec"
  for name in iptables ip6tables iptables-save ip6tables-save ipset dig getent host nslookup curl chown; do
    ln -s rec "$bin/$name"
  done
}

sdd_fw_run() {
  local tmp=$1
  shift
  : > "$tmp/log"
  env -i PATH="$tmp/bin:/usr/bin:/bin" LOG="$tmp/log" FAIL_ON="${FAIL_ON:-}" READBACK="${READBACK:-}" \
    bash containers/worker/init-firewall.sh "$@" > "$tmp/out" 2>&1
}

# The first line of $2 matching the pattern $3, by number; 0 when none.
sdd_line_of() { grep -n -m1 -E "$2" "$1" | cut -d: -f1 | grep . || echo 0; }

sdd_fw_deny_first() {
  local tmp fam drop accept
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_worker_stubs "$tmp/bin"
  sdd_fw_run "$tmp" 192.168.70.2 8080 || {
    echo "the firewall failed with every rule succeeding: $(cat "$tmp/out")"
    return 1
  }
  for fam in iptables ip6tables; do
    drop=$(sdd_line_of "$tmp/log" "^$fam -P OUTPUT DROP\$")
    accept=$(sdd_line_of "$tmp/log" "^$fam .*-j ACCEPT")
    [ "$drop" -gt 0 ] || {
      echo "$fam: OUTPUT policy never set to DROP:"
      cat "$tmp/log"
      return 1
    }
    [ "$accept" -eq 0 ] || [ "$drop" -lt "$accept" ] || {
      echo "$fam: an ACCEPT rule (line $accept) comes before the DROP policy (line $drop)"
      return 1
    }
    for chain in INPUT FORWARD; do
      grep -qx "$fam -P $chain DROP" "$tmp/log" || {
        echo "$fam: $chain policy is not DROP"
        return 1
      }
    done
  done
}
check "the worker firewall sets every policy to DROP before any allow rule, IPv4 and IPv6" sdd_fw_deny_first

sdd_fw_allows_only_proxy() {
  local tmp got want fam last
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_worker_stubs "$tmp/bin"
  sdd_fw_run "$tmp" 192.168.70.2 8080 || {
    echo "the firewall failed: $(cat "$tmp/out")"
    return 1
  }
  got=$(grep -E '^ip6?tables .*-j ACCEPT' "$tmp/log" | sort)
  want=$(
    sort << 'WANT'
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d 192.168.70.2/32 -p tcp --dport 8080 -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
WANT
  )
  [ "$got" = "$want" ] || {
    echo "the ACCEPT rules are not exactly loopback, replies and the proxy's address and port:"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got")
    return 1
  }
  for fam in iptables ip6tables; do
    last=$(grep -E "^$fam -A OUTPUT " "$tmp/log" | tail -1)
    case "$last" in "$fam -A OUTPUT -j REJECT"*) ;; *)
      echo "$fam: the OUTPUT chain does not end in a REJECT; its last rule is: $last"
      return 1
      ;;
    esac
  done
  ! grep -qE '^(ipset|dig|getent|host|nslookup|curl) ' "$tmp/log" || {
    echo "the firewall resolved a name or built an ipset, which a proxy-only container never needs:"
    grep -E '^(ipset|dig|getent|host|nslookup|curl) ' "$tmp/log"
    return 1
  }
}
check "the worker firewall allows loopback, replies and the egress proxy's address and port, nothing else, DNS included, and ends in REJECT" sdd_fw_allows_only_proxy

sdd_fw_fails_closed() {
  local tmp args
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_worker_stubs "$tmp/bin"
  for args in "" "192.168.70.2" "proxy.example 8080" "192.168.70.2 http" "192.168.70.2/24 8080"; do
    # shellcheck disable=SC2086  # the cases are word lists on purpose
    if sdd_fw_run "$tmp" $args; then
      echo "accepted the arguments '$args' instead of an IPv4 address and a port"
      return 1
    fi
    ! grep -qE '^ip6?tables ' "$tmp/log" || {
      echo "touched the rules before refusing the arguments '$args'"
      return 1
    }
  done
  FAIL_ON="iptables -A OUTPUT -d 192.168.70.2/32 -p tcp --dport 8080 -j ACCEPT"
  if sdd_fw_run "$tmp" 192.168.70.2 8080; then
    echo "succeeded although a rule failed"
    return 1
  fi
  FAIL_ON=
  if READBACK=ACCEPT sdd_fw_run "$tmp" 192.168.70.2 8080; then
    echo "succeeded although the OUTPUT policy read back as ACCEPT"
    return 1
  fi
}
check "the worker firewall refuses anything but an address and a port, and fails when a rule or the read-back fails" sdd_fw_fails_closed

# The entrypoint is copied beside a stand-in init-firewall.sh, as it sits beside
# the real one in the image, with the image's models.json template; node's home
# is a scratch directory holding the file the image creates for pi.
sdd_ep_setup() {
  local tmp=$1
  sdd_worker_stubs "$tmp/bin"
  rm "$tmp/bin/getent"
  cat > "$tmp/bin/getent" << STUB
#!/usr/bin/env bash
printf '%s\n' "getent \$*" >> "\$LOG"
[ "\$*" = "passwd node" ] && echo "node:x:1000:1000::$tmp/home:/bin/bash"
STUB
  cat > "$tmp/bin/setpriv" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "setpriv" >> "$LOG"
printf '%s\n' "$@" > "$ARGS"
pwd -P > "$(dirname "$ARGS")/cwd"
STUB
  mkdir -p "$tmp/lib" "$tmp/home/.pi/agent" "$tmp/root/work" "$tmp/root/bundle"
  cp containers/worker/entrypoint.sh "$tmp/lib/"
  cp containers/worker/models.json "$tmp/lib/" 2> /dev/null
  cat > "$tmp/lib/init-firewall.sh" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "firewall $*" >> "$LOG"
exit "${FW_EXIT:-0}"
STUB
  chmod +x "$tmp/bin/getent" "$tmp/bin/setpriv" "$tmp/lib/init-firewall.sh"
  echo template > "$tmp/home/.pi/agent/models.json"
  ln -s rec "$tmp/bin/update-ca-certificates"
  # The run's authority, as the egress proxy makes one (research R25), and a
  # certificate that is not an authority, made with the host's openssl.
  printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=sdd run CA\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n[leaf]\nbasicConstraints=CA:FALSE\n' > "$tmp/openssl.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/ca.key" -out "$tmp/root/bundle/proxy-ca.pem" \
    -days 1 -config "$tmp/openssl.cnf" -extensions ca > /dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/leaf.key" -out "$tmp/leaf.pem" \
    -days 1 -config "$tmp/openssl.cnf" -extensions leaf > /dev/null 2>&1
}

# Runs the entrypoint with a clean environment plus the assignments given
# before `--`, and the command after it.
# A pass's placeholder in the shape sdd-pass.py makes; every run of the
# entrypoint gets it unless a case overrides SDD_PASS_TOKEN.
SDD_EP_TOKEN=sdd-pass-checkTOKEN0123456789abcdef
sdd_ep_run() {
  local tmp=$1
  shift
  local vars=()
  while [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  shift
  : > "$tmp/log"
  : > "$tmp/args"
  env -i PATH="$tmp/bin:/usr/bin:/bin" LOG="$tmp/log" ARGS="$tmp/args" FW_EXIT="${FW_EXIT:-0}" \
    SDD_MOUNT_ROOT="$tmp/root" SDD_PASS_TOKEN="$SDD_EP_TOKEN" "${vars[@]}" \
    bash "$tmp/lib/entrypoint.sh" "$@" > "$tmp/out" 2>&1
}

sdd_ep_firewall_first() {
  local tmp fw sp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_ep_setup "$tmp"
  sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- true || {
    echo "failed with a valid proxy and a firewall that succeeds: $(cat "$tmp/out")"
    return 1
  }
  # Trusting the run's authority is local and comes first (sdd_ep_ca); the
  # firewall is the first thing after it, before anything could reach out.
  [ "$(grep -v '^update-ca-certificates' "$tmp/log" | head -1)" = "firewall 192.168.70.2 8080" ] || {
    echo "the firewall is not the first thing run, with the proxy's address and port; calls:"
    cat "$tmp/log"
    return 1
  }
  fw=$(sdd_line_of "$tmp/log" '^firewall ')
  sp=$(sdd_line_of "$tmp/log" '^setpriv$')
  [ "$sp" -gt "$fw" ] || {
    echo "the command was not started after the firewall"
    return 1
  }
  if FW_EXIT=1 sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- true; then
    echo "succeeded although the firewall failed"
    return 1
  fi
  ! grep -qx setpriv "$tmp/log" || {
    echo "started the command although the firewall failed"
    return 1
  }
  for bad in "" "192.168.70.2" "proxy.example:8080" "192.168.70.2:http"; do
    if sdd_ep_run "$tmp" "SDD_PROXY=$bad" -- true; then
      echo "accepted SDD_PROXY='$bad'"
      return 1
    fi
    ! grep -qE '^(firewall|setpriv)' "$tmp/log" || {
      echo "ran the firewall or the command with SDD_PROXY='$bad'"
      return 1
    }
  done
}
check "the worker entrypoint brings the firewall up for the proxy first, and runs nothing when it or the proxy address fails" sdd_ep_firewall_first

sdd_ep_runs_as_node() {
  local tmp secret=sk-planted-credential-value
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_ep_setup "$tmp"
  sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 \
    ANTHROPIC_BASE_URL=http://192.168.70.2:8080 CLAUDE_CODE_OAUTH_TOKEN=$SDD_EP_TOKEN \
    ANTHROPIC_API_KEY=$secret DEEPSEEK_API_KEY=$secret GITHUB_TOKEN=$secret \
    -- claude -p "say hi" || {
    echo "failed with a valid environment: $(cat "$tmp/out")"
    return 1
  }
  local args
  args=$(cat "$tmp/args")
  for want in --reuid=node --regid=node --init-groups --no-new-privs; do
    grep -qx -- "$want" <<< "$args" || {
      echo "setpriv was not given $want; it got:"
      printf '%s\n' "$args"
      return 1
    }
  done
  [ "$(tail -3 <<< "$args")" = "$(printf '%s\n' claude -p "say hi")" ] || {
    echo "the command is not passed last and intact; setpriv got:"
    printf '%s\n' "$args"
    return 1
  }
  grep -qx -- "-i" <<< "$args" || {
    echo "the command's environment is not cleared down to an allow list"
    return 1
  }
  ! grep -qF -- "$secret" <<< "$args" || {
    echo "a credential reached the command's environment or arguments"
    return 1
  }
  ! grep -qF -- "$secret" "$tmp/out" || {
    echo "a credential was printed"
    return 1
  }
  for want in ANTHROPIC_BASE_URL=http://192.168.70.2:8080 CLAUDE_CODE_OAUTH_TOKEN=$SDD_EP_TOKEN \
    HTTPS_PROXY="http://$SDD_EP_TOKEN@192.168.70.2:8080" HOME="$tmp/home" USER=node \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; do
    grep -qx -- "$want" <<< "$args" || {
      echo "the command's environment lacks $want; setpriv got:"
      printf '%s\n' "$args"
      return 1
    }
  done
  ! grep -qE '^(NPM_CONFIG_CACHE|UV_CACHE_DIR)=' <<< "$args" || {
    echo "cache variables were set with no cache mounted"
    return 1
  }
  ! grep -qE '^(LOG|ARGS|FW_EXIT|SDD_PROXY|SDD_MOUNT_ROOT|SDD_PASS_TOKEN)=' <<< "$args" || {
    echo "a variable outside the allow list reached the command"
    return 1
  }
}
check "the worker entrypoint starts the command as node with no new privileges, its environment an allow list with no credential" sdd_ep_runs_as_node

sdd_ep_refuses() {
  local tmp case
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_ep_setup "$tmp"
  for case in CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-planted ANTHROPIC_BASE_URL=https://api.anthropic.com \
    ANTHROPIC_BASE_URL=http://192.168.70.3:8080 SDD_PASS_TOKEN=sk-ant-oat01-planted SDD_PASS_TOKEN= \
    CLAUDE_CODE_OAUTH_TOKEN=sdd-pass-anotherPASS0123456789; do
    if sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 "$case" -- true; then
      echo "accepted $case"
      return 1
    fi
    ! grep -qx setpriv "$tmp/log" || {
      echo "started the command with $case"
      return 1
    }
    ! grep -qF -- "sk-ant-oat01-planted" "$tmp/out" || {
      echo "printed the token it refused"
      return 1
    }
  done
}
check "the worker entrypoint refuses a token other than the pass's placeholder and a base URL other than the proxy" sdd_ep_refuses

# pi's models.json arrives filled at /bundle/models.json (contracts/pass.md);
# the entrypoint copies it to node's home only when every provider points at
# the proxy with the placeholder key, and stops the pass otherwise.
sdd_ep_pi_models() {
  local tmp models good bad
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_ep_setup "$tmp"
  models=$tmp/root/bundle/models.json
  good='{"providers":{"deepseek":{"baseUrl":"http://192.168.70.2:8080/deepseek","apiKey":"'"$SDD_EP_TOKEN"'","models":[]}}}'
  printf '%s\n' "$good" > "$models"
  sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- true || {
    echo "failed with a models.json at the proxy: $(cat "$tmp/out")"
    return 1
  }
  [ "$(cat "$tmp/home/.pi/agent/models.json")" = "$good" ] || {
    echo "pi's models.json in node's home is not the bundle's"
    return 1
  }
  for bad in \
    '{"providers":{"deepseek":{"baseUrl":"https://api.deepseek.com","apiKey":"'"$SDD_EP_TOKEN"'"}}}' \
    '{"providers":{"deepseek":{"baseUrl":"http://192.168.70.2:8081","apiKey":"'"$SDD_EP_TOKEN"'"}}}' \
    '{"providers":{"deepseek":{"baseUrl":"http://192.168.70.2:8080","apiKey":"sk-planted-key"}}}' \
    '{"providers":{"a":{"baseUrl":"http://192.168.70.2:8080","apiKey":"'"$SDD_EP_TOKEN"'"},"b":{"baseUrl":"http://10.0.0.1:80","apiKey":"'"$SDD_EP_TOKEN"'"}}}' \
    '{"providers":{}}' 'not json'; do
    printf '%s\n' "$bad" > "$models"
    echo template > "$tmp/home/.pi/agent/models.json"
    if sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- true; then
      echo "accepted the models.json $bad"
      return 1
    fi
    ! grep -qE '^(firewall|setpriv)' "$tmp/log" || {
      echo "ran the firewall or the command with the models.json $bad"
      return 1
    }
    [ "$(cat "$tmp/home/.pi/agent/models.json")" = template ] || {
      echo "copied the refused models.json $bad"
      return 1
    }
    ! grep -qF sk-planted-key "$tmp/out" || {
      echo "printed the key it refused"
      return 1
    }
  done
}
check "the worker entrypoint gives pi the bundle's models.json only when every provider is the proxy with the placeholder key" sdd_ep_pi_models

sdd_ep_cache_and_work() {
  local tmp args
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_ep_setup "$tmp"
  mkdir -p "$tmp/root/cache"
  sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- pwd || {
    echo "failed with a cache mounted: $(cat "$tmp/out")"
    return 1
  }
  args=$(cat "$tmp/args")
  grep -qx "chown node:node $tmp/root/cache" "$tmp/log" || {
    echo "the cache volume was not given to node"
    return 1
  }
  for want in NPM_CONFIG_CACHE="$tmp/root/cache/npm" UV_CACHE_DIR="$tmp/root/cache/uv" \
    PIP_CACHE_DIR="$tmp/root/cache/pip" MISE_CACHE_DIR="$tmp/root/cache/mise"; do
    grep -qx -- "$want" <<< "$args" || {
      echo "the command's environment lacks $want"
      return 1
    }
  done
  # setpriv is a stand-in that does not exec, so the working directory is
  # the entrypoint's own when it calls it: the stub records it.
  [ "$(cat "$tmp/cwd")" = "$(cd "$tmp/root/work" && pwd -P)" ] || {
    echo "the command does not start in /work but in $(cat "$tmp/cwd")"
    return 1
  }
}
check "the worker entrypoint gives node the cache volume, points every package manager at it, and starts in /work" sdd_ep_cache_and_work

# The run's certificate authority (FR-031, research R25): the egress proxy
# reads the registries' TLS with it, so the worker must trust it, and only a
# certificate authority, before anything runs. The entrypoint installs it
# into the system store before the firewall, points every client that keeps
# its own trust list at that store, and turns npm's audit off — a POST, the
# one non-read a registry read would make. A missing file, or a certificate
# that is not an authority, stops the pass.
sdd_ep_ca() {
  local tmp args want
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  sdd_ep_setup "$tmp"
  sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- true || {
    echo "failed with the run's authority in place: $(cat "$tmp/out")"
    return 1
  }
  cmp -s "$tmp/root/bundle/proxy-ca.pem" "$tmp/root/usr/local/share/ca-certificates/sdd-run.crt" || {
    echo "the authority was not copied to /usr/local/share/ca-certificates/sdd-run.crt"
    return 1
  }
  local ca fw
  ca=$(sdd_line_of "$tmp/log" '^update-ca-certificates')
  fw=$(sdd_line_of "$tmp/log" '^firewall ')
  [ "$ca" -gt 0 ] && [ "$ca" -lt "$fw" ] || {
    echo "update-ca-certificates did not run before the firewall:"
    cat "$tmp/log"
    return 1
  }
  args=$(cat "$tmp/args")
  for want in NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt npm_config_audit=false npm_config_fund=false; do
    grep -qx -- "$want" <<< "$args" || {
      echo "the command's environment lacks $want"
      return 1
    }
  done
  local case
  for case in missing leaf garbage; do
    rm -rf "${tmp:?}"/* && sdd_ep_setup "$tmp"
    case $case in
      missing) rm "$tmp/root/bundle/proxy-ca.pem" ;;
      leaf) cp "$tmp/leaf.pem" "$tmp/root/bundle/proxy-ca.pem" ;;
      garbage) echo "not a certificate" > "$tmp/root/bundle/proxy-ca.pem" ;;
    esac
    if sdd_ep_run "$tmp" SDD_PROXY=192.168.70.2:8080 -- true; then
      echo "accepted a $case authority"
      return 1
    fi
    ! grep -qE '^(firewall|setpriv|update-ca-certificates)' "$tmp/log" || {
      echo "went on with a $case authority:"
      cat "$tmp/log"
      return 1
    }
  done
}
check "the worker entrypoint trusts the run's authority before the firewall, and only an authority" sdd_ep_ca

# drift.sh reports each pin of the worker image that upstream has moved past
# (constitution V): worker_pin_report compares the Containerfile with the
# latest values worker_pins_latest fetched, and is run here on a fixture and
# canned answers, so no network is needed. A pin it cannot read, or an
# upstream that did not answer, is reported, never read as current.
sdd_worker_pin_drift() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn=$tmp/fn.sh
  sed -n '/^worker_pin_report() {$/,/^}$/p' drift.sh > "$fn"
  grep -q 'worker_pin_report' "$fn" || {
    echo "could not extract worker_pin_report from drift.sh"
    return 1
  }
  cat > "$tmp/Containerfile" << 'CF'
FROM docker.io/library/node:24-bookworm-slim@sha256:aaaa
ARG CLAUDE_CODE_VERSION=2.1.306
ARG PI_VERSION=1.3.0
ARG MISE_VERSION=2026.10.7
ARG UV_VERSION=0.13.0
CF
  report_with() { bash -c '. "$1" && worker_pin_report "$2" "$3"' _ "$fn" "$tmp/Containerfile" "$1"; }
  out=$(report_with '{"node":"sha256:aaaa","claude_code":"2.1.306","pi":"1.3.0","mise":"v2026.10.7","uv":"0.13.0"}') || {
    echo "current: failed: $out"
    return 1
  }
  [ -z "$out" ] || {
    echo "current: reported drift with every pin current: $out"
    return 1
  }
  out=$(report_with '{"node":"sha256:bbbb","claude_code":"2.1.310","pi":"1.4.0","mise":"v2026.10.17","uv":"0.13.4"}')
  local want
  for want in "node:24-bookworm-slim: pinned to sha256:aaaa, the tag now points at sha256:bbbb" \
    "Claude Code: pinned to 2.1.306, upstream now releases 2.1.310" "pi: pinned to 1.3.0, upstream now releases 1.4.0" \
    "mise: pinned to 2026.10.7, upstream now releases 2026.10.17" "uv: pinned to 0.13.0, upstream now releases 0.13.4"; do
    grep -qxF "$want" <<< "$out" || {
      echo "moved: missing '$want' in:"
      printf '%s\n' "$out"
      return 1
    }
  done
  out=$(report_with '{"node":{"error":"timed out"},"claude_code":"2.1.306","pi":"1.3.0","mise":"v2026.10.7","uv":"0.13.0"}')
  grep -q "node:24-bookworm-slim: could not ask upstream (timed out)" <<< "$out" || {
    echo "unanswered: an upstream that did not answer was not reported: $out"
    return 1
  }
  sed -i.bak '/^ARG PI_VERSION/d' "$tmp/Containerfile"
  out=$(report_with '{"node":"sha256:aaaa","claude_code":"2.1.306","pi":"1.3.0","mise":"v2026.10.7","uv":"0.13.0"}')
  grep -q "pi: no pin found in the Containerfile" <<< "$out" || {
    echo "missing pin: a pin it could not read was not reported: $out"
    return 1
  }
}
check "drift.sh reports each worker image pin upstream has moved past, and any it cannot check" sdd_worker_pin_drift
