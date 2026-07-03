#!/bin/bash
set -euo pipefail

# Default-deny outbound firewall. Only traffic to an explicit allowlist of
# domains (resolved to IPs at startup) is permitted on 80/443; everything
# else outbound is dropped. Must run as root / with NET_ADMIN+NET_RAW.
#
# Caveat: this is DNS-snapshot based, not a live-inspecting proxy. It stops
# opportunistic exfiltration/downloads to arbitrary hosts, but a resolved IP
# could theoretically change after the snapshot, and it doesn't inspect
# traffic content. Treat it as raising the bar, not a hard guarantee.

DEFAULT_DOMAINS="api.anthropic.com,claude.ai,statsig.anthropic.com,registry.npmjs.org,registry.yarnpkg.com,pypi.org,files.pythonhosted.org,github.com,api.github.com,raw.githubusercontent.com,codeload.github.com,objects.githubusercontent.com"
ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-$DEFAULT_DOMAINS}"

# Add more domains per-project without editing this file, e.g.
#   EXTRA_ALLOWED_DOMAINS=my-private-registry.example.com
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
  ALLOWED_DOMAINS="${ALLOWED_DOMAINS},${EXTRA_ALLOWED_DOMAINS}"
fi

iptables -F OUTPUT

# Always allow loopback and Docker's embedded DNS resolver
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT

# Allow return traffic for connections we initiate
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS lookups themselves
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Resolve and allow each domain on 80/443
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

# Deny everything else outbound
iptables -P OUTPUT DROP

echo "Firewall active. Outbound allowed only to: $ALLOWED_DOMAINS"
