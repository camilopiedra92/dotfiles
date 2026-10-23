#!/usr/bin/env bash
# Deny-by-default egress for the worker container: the egress proxy's address
# and port are the only destination (specs/003-sdd-model-routing,
# contracts/pass.md, research R5, R23).
#
# Usage: init-firewall.sh <proxy IPv4 address> <proxy port>   (as root)
#
# Adapted from Anthropic's reference devcontainer firewall,
# https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
# (read 2026-10-21). Kept from it: policies to DROP, loopback and replies
# allowed, a REJECT at the end of OUTPUT for immediate feedback. Dropped on
# purpose: its DNS, SSH and host-network rules and its ipset of resolved
# domains — every name here is resolved by the proxy, so the container sends
# no DNS and needs no list of addresses, and the host network would include
# the host and every other container on it.
set -euo pipefail

proxy=${1:-}
port=${2:-}
[[ $proxy =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
  echo "init-firewall: the proxy must be an IPv4 address, got '$proxy'" >&2
  exit 2
}
[[ $port =~ ^[0-9]{1,5}$ ]] || {
  echo "init-firewall: the proxy port must be a number, got '$port'" >&2
  exit 2
}

# The policies go first, so no moment exists in which an allow rule is in
# place and the default is still to accept.
for fam in iptables ip6tables; do
  for chain in INPUT FORWARD OUTPUT; do
    "$fam" -P "$chain" DROP
  done
  "$fam" -F
  "$fam" -X
  "$fam" -A INPUT -i lo -j ACCEPT
  "$fam" -A OUTPUT -o lo -j ACCEPT
done

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d "$proxy/32" -p tcp --dport "$port" -j ACCEPT

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited

# Read the policy back rather than trust the calls: a kernel or iptables
# backend that accepted a rule without applying it must stop the pass.
for fam in iptables ip6tables; do
  [ "$("$fam" -S OUTPUT | head -1)" = "-P OUTPUT DROP" ] || {
    echo "init-firewall: $fam OUTPUT policy did not read back as DROP" >&2
    exit 1
  }
done
# stderr: the container's stdout carries the agent's JSON result (contracts/pass.md).
echo "init-firewall: egress limited to $proxy:$port" >&2
