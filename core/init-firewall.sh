#!/bin/bash
# Egress firewall: force all HTTP/HTTPS through squid (hostname-filtered, spliced not decrypted);
# default-DROP everything else (other ports, IPv6, direct-IP). squid is the only uid allowed
# direct egress (enforces the allowlist + avoids the REDIRECT loop). See THREAT_MODEL.md.
set -euo pipefail

echo "[firewall] configuring hostname-filtered egress..."

# Per-project config (SLUICE_PORTS, SLUICE_ALLOW_IPS) - baked at /usr/local/share/sluice.config.sh.
[ -f /usr/local/share/sluice.config.sh ] && . /usr/local/share/sluice.config.sh

SQUID_UID="$(id -u squid)"
HTTP_PORT=3129
HTTPS_PORT=3130

# --- reset (v4) ----------------------------------------------------------------
iptables -F
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true

# --- INPUT (v4) ----------------------------------------------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -s 127.0.0.11 -j ACCEPT                              # docker embedded DNS
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Published ports (docker -p) are DNAT'd to the container - allow them inbound.
for p in ${SLUICE_PORTS:-}; do
  iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
done

# --- redirect all HTTP/HTTPS egress to squid (v4 nat) --------------------------
# Everyone but squid: tcp/80 -> 3129, tcp/443 -> 3130 (the owner exclusion avoids a loop).
iptables -t nat -A OUTPUT -p tcp --dport 80  -m owner ! --uid-owner "$SQUID_UID" -j REDIRECT --to-ports "$HTTP_PORT"
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner ! --uid-owner "$SQUID_UID" -j REDIRECT --to-ports "$HTTPS_PORT"

# --- OUTPUT (v4) ---------------------------------------------------------------
iptables -A OUTPUT -o lo -j ACCEPT                                     # loopback
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT                            # REDIRECT'd pkts (dst rewritten to localhost -> squid)
iptables -A OUTPUT -m owner --uid-owner "$SQUID_UID" -j ACCEPT         # squid's own egress (enforces the allowlist)
# DNS only to the resolvers in resolv.conf (blocks DNS tunneling to an arbitrary nameserver).
for ns in $(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null); do
  case "$ns" in *:*) continue;; esac                                  # skip IPv6 resolvers
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# SLUICE_ALLOW_IPS: reviewed fixed IPs/CIDRs get direct egress (escape hatch for non-HTTP).
for ip in ${SLUICE_ALLOW_IPS:-}; do
  iptables -A OUTPUT -d "$ip" -j ACCEPT
done
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# --- IPv6: default-drop everything (no v6 proxying in this prototype) -----------
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F 2>/dev/null || true
  ip6tables -t nat -F 2>/dev/null || true
  ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -P INPUT   DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
  ip6tables -P OUTPUT  DROP 2>/dev/null || true
fi

# --- verify (fail closed on the deny tests) ------------------------------------
# Deny self-test: a non-allowlisted host must be blocked. Pick a canary not in this allowlist.
deny_canary=""
for c in example.com example.net example.org; do
  grep -qiF "$c" /etc/squid/allowlist.txt 2>/dev/null && continue
  deny_canary="$c"; break
done
if [ -n "$deny_canary" ]; then
  if curl -sS -o /dev/null --max-time 6 "https://$deny_canary" 2>/dev/null; then
    echo "[firewall] FAIL: $deny_canary reachable - hostname filtering not enforced" >&2
    exit 1
  fi
else
  echo "[firewall] WARN: every deny-canary is allowlisted - skipping the deny self-test" >&2
fi
# Deny: a direct-IP HTTPS connection carries no SNI -> the proxy must block it.
if curl -sS -o /dev/null --max-time 6 https://1.1.1.1 2>/dev/null; then
  echo "[firewall] FAIL: direct-IP egress reachable - proxy bypassed" >&2
  exit 1
fi
# Allow: an always-allowlisted base host must work THROUGH the proxy. Warn-only (transient).
curl -sS -o /dev/null --max-time 12 https://registry.npmjs.org 2>/dev/null \
  || echo "[firewall] WARN: registry.npmjs.org unreachable via proxy - check 'docker exec <sluice> cat /var/log/squid/cache.log'" >&2
echo "[firewall] hostname-filtered egress active (proxy: squid)."
