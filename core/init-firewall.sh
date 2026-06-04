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

iptables -F
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -s 127.0.0.11 -j ACCEPT                              # docker embedded DNS
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Published ports (docker -p) are DNAT'd to the container - allow them inbound.
for p in ${SLUICE_PORTS:-}; do
  iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
done

# Everyone but squid: tcp/80 -> 3129, tcp/443 -> 3130 (the owner exclusion avoids a loop).
iptables -t nat -A OUTPUT -p tcp --dport 80  -m owner ! --uid-owner "$SQUID_UID" -j REDIRECT --to-ports "$HTTP_PORT"
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner ! --uid-owner "$SQUID_UID" -j REDIRECT --to-ports "$HTTPS_PORT"

# Apps (uid != root) must resolve via dnsmasq on 127.0.0.1, which is scoped to the egress allowlist
# (see entrypoint). Deny them a direct path to docker's embedded resolver (127.0.0.11) - the
# 127.0.0.0/8 accept just below would otherwise hand it over, and it forwards arbitrary names.
# dnsmasq itself runs as root and still forwards through it.
iptables -A OUTPUT -d 127.0.0.11 -m owner ! --uid-owner 0 -j DROP
iptables -A OUTPUT -o lo -j ACCEPT                                     # loopback
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT                            # REDIRECT'd pkts (dst rewritten to localhost -> squid)
iptables -A OUTPUT -m owner --uid-owner "$SQUID_UID" -j ACCEPT         # squid's own egress (enforces the allowlist)
# DNS to the cache's real upstreams, dnsmasq (root) ONLY - so an app can't bypass the allowlist-scoped
# resolver by talking to the upstream directly. The entrypoint saved them to /run/sluice-dns-upstream;
# fall back to resolv.conf. Match IPv4 only.
dns_src=/run/sluice-dns-upstream
[ -f "$dns_src" ] || dns_src=/etc/resolv.conf
for ns in $(awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i }' "$dns_src" 2>/dev/null); do
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -m owner --uid-owner 0 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -m owner --uid-owner 0 -j ACCEPT
done
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# SLUICE_ALLOW_IPS: reviewed fixed IPs/CIDRs get direct egress (escape hatch for non-HTTP). Each
# entry is ip[:port[/proto]] - a bare ip/cidr opens EVERY port (legacy), ip:5432 scopes to one tcp
# port, ip:5432/udp picks the proto. We are IPv4-only, so the single ':' splits host from port cleanly.
for entry in ${SLUICE_ALLOW_IPS:-}; do
  case "$entry" in
    *:*)
      ippart="${entry%%:*}"; portspec="${entry#*:}"; proto="tcp"; port="$portspec"
      case "$portspec" in */*) port="${portspec%%/*}"; proto="${portspec#*/}" ;; esac
      iptables -A OUTPUT -d "$ippart" -p "$proto" --dport "$port" -j ACCEPT ;;
    *)
      iptables -A OUTPUT -d "$entry" -j ACCEPT ;;
  esac
done
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# IPv6: default-drop everything (we proxy v4 only).
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F 2>/dev/null || true
  ip6tables -t nat -F 2>/dev/null || true
  ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -P INPUT   DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
  ip6tables -P OUTPUT  DROP 2>/dev/null || true
fi

# Audit mode (learn --audit) opens all HTTP/HTTPS via squid, so the enforce-mode deny asserts below
# would fail closed - skip them. Non-HTTP ports + IPv6 stay default-DROP above; the audit container
# is ephemeral + credential-stripped.
if [ "${SLUICE_AUDIT:-}" = 1 ]; then
  echo "[firewall] AUDIT MODE: egress OPEN to all HTTP/HTTPS hosts - deny self-tests skipped" >&2
else
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
fi
# Allow: an always-allowlisted base host must work THROUGH the proxy. Warn-only (transient).
curl -sS -o /dev/null --max-time 12 https://registry.npmjs.org 2>/dev/null \
  || echo "[firewall] WARN: registry.npmjs.org unreachable via proxy - check 'docker exec <sluice> cat /var/log/squid/cache.log'" >&2

# Boot self-tests (deny-canary + allow-check) are now in squid's access log; truncate it so
# `sluice egress` / the receipt show the session's real traffic, not boot checks. squid keeps appending.
squid -k rotate 2>/dev/null || : > /var/log/squid/access.log 2>/dev/null || true
echo "[firewall] hostname-filtered egress active (proxy: squid)."
