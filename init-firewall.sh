#!/bin/bash
set -euo pipefail

# Outbound firewall. Two modes, controlled by FIREWALL_MODE:
#   - open (default): outbound allowed to ANY host on ports 80/443 (web
#     browsing, search grounding, arbitrary APIs). Every other port is
#     blocked.
#   - strict (FIREWALL_MODE=strict): default-deny outbound except an
#     explicit allowlist of domains, resolved to IPs at startup. This is
#     the old, more restrictive behavior.
#
# In either mode, EXTRA_ALLOWED_PORTS opens specific additional ports (any
# destination) on demand, e.g. EXTRA_ALLOWED_PORTS=5432,22 for a project
# database or SSH.
#
# Caveat: this is DNS-snapshot/port based, not a content-inspecting proxy.
# "open" mode stops non-web exfiltration/reverse-shell protocols but not
# arbitrary HTTP(S) egress; "strict" mode narrows further to named hosts.

FIREWALL_MODE="${FIREWALL_MODE:-open}"

DEFAULT_DOMAINS="api.anthropic.com,claude.ai,statsig.anthropic.com,registry.npmjs.org,registry.yarnpkg.com,pypi.org,files.pythonhosted.org,github.com,api.github.com,raw.githubusercontent.com,codeload.github.com,objects.githubusercontent.com"

iptables -F OUTPUT

# Always allow loopback and Docker's embedded DNS resolver
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT

# Allow return traffic for connections we initiate
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS lookups themselves
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

if [ "$FIREWALL_MODE" = "strict" ]; then
  ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-$DEFAULT_DOMAINS}"
  # Add more domains per-project without editing this file, e.g.
  #   FIREWALL_MODE=strict EXTRA_ALLOWED_DOMAINS=my-registry.example.com ./cc-container launch ...
  if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    ALLOWED_DOMAINS="${ALLOWED_DOMAINS},${EXTRA_ALLOWED_DOMAINS}"
  fi

  IFS=',' read -ra DOMAINS <<< "$ALLOWED_DOMAINS"
  for domain in "${DOMAINS[@]}"; do
    domain="$(echo "$domain" | xargs)" # trim whitespace
    [ -z "$domain" ] && continue
    ips="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [ -z "$ips" ]; then
      echo "WARNING: could not resolve $domain, skipping" >&2
      continue
    fi
    for ip in $ips; do
      iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
      iptables -A OUTPUT -d "$ip" -p tcp --dport 80 -j ACCEPT
    done
  done
  firewall_desc="strict allowlist: $ALLOWED_DOMAINS"
else
  # open mode: any host, web ports only
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
  firewall_desc="open web (any host, ports 80/443 only)"
fi

# Open extra ports to any destination, on demand, in either mode. e.g.
#   EXTRA_ALLOWED_PORTS=5432,22 ./cc-container launch ...
if [ -n "${EXTRA_ALLOWED_PORTS:-}" ]; then
  IFS=',' read -ra PORTS <<< "$EXTRA_ALLOWED_PORTS"
  for port in "${PORTS[@]}"; do
    port="$(echo "$port" | xargs)"
    [ -z "$port" ] && continue
    iptables -A OUTPUT -p tcp --dport "$port" -j ACCEPT
  done
  firewall_desc="$firewall_desc; extra ports: $EXTRA_ALLOWED_PORTS"
fi

# Deny everything else outbound
iptables -P OUTPUT DROP

echo "Firewall active ($FIREWALL_MODE mode). $firewall_desc"
