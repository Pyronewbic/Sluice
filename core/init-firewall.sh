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
# squid's forward-proxy port (3128) is a non-intercept CONNECT proxy: anyone who reaches it can
# blind-tunnel to ANY ip:port, bypassing the SNI filter + direct-IP block. Nothing but squid needs it
# (and squid never dials its own 3128), so REJECT every other uid before the loopback ACCEPT below.
iptables -A OUTPUT -p tcp -d 127.0.0.1 --dport 3128 -m owner ! --uid-owner "$SQUID_UID" -j REJECT --reject-with tcp-reset
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

# Prove the default-DROP actually took effect (not a silent no-op the `|| true`s above could mask).
# These are policy assertions - instant, no live probe - and run in both modes (audit only opens the
# squid allowlist; the OUTPUT/v6 structure stays default-closed). A non-allowlisted / non-80-443 /
# IPv6 path must NOT be able to escape.
case "$(iptables -S OUTPUT 2>/dev/null | head -1)" in
  '-P OUTPUT DROP') ;;
  *) echo "[firewall] FAIL: OUTPUT policy is not DROP - egress not default-closed" >&2; exit 1 ;;
esac
# If ip6tables is usable, its OUTPUT policy MUST be DROP; otherwise the --sysctl disable_ipv6 set at
# run is the closure (no v6 stack to filter). Catches the double-no-op that would leave v6 wide open.
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT >/dev/null 2>&1; then
  case "$(ip6tables -S OUTPUT 2>/dev/null | head -1)" in
    '-P OUTPUT DROP') ;;
    *) echo "[firewall] FAIL: IPv6 OUTPUT is not default-DROP - v6 egress may be open" >&2; exit 1 ;;
  esac
fi

# Audit mode (learn --audit) opens all HTTP/HTTPS via squid, so the enforce-mode deny asserts below
# would fail closed - skip them. Non-HTTP ports + IPv6 stay default-DROP above; the audit container
# is ephemeral + credential-stripped.
if [ "${SLUICE_AUDIT:-}" = 1 ]; then
  echo "[firewall] AUDIT MODE: egress OPEN to all HTTP/HTTPS hosts - deny self-tests skipped" >&2
else
  # Deny self-test: a guaranteed-never-allowlisted host must be blocked. A reserved .invalid name
  # (RFC 2606) can't accidentally appear in a user's allowlist, so this check always runs - the old
  # example.* canaries would silently skip if a config happened to allow all three.
  if curl -sS -o /dev/null --max-time 6 https://blocked.sluice.invalid 2>/dev/null; then
    echo "[firewall] FAIL: a non-allowlisted host was reachable - hostname filtering not enforced" >&2
    exit 1
  fi
  # Deny: a direct-IP HTTPS connection carries no SNI -> the proxy must block it.
  if curl -sS -o /dev/null --max-time 6 https://1.1.1.1 2>/dev/null; then
    echo "[firewall] FAIL: direct-IP egress reachable - proxy bypassed" >&2
    exit 1
  fi
  # Deny: the forward-proxy port (3128) must NOT tunnel a CONNECT to a raw IP - that path would bypass
  # the SNI filter, direct-IP block, and DNS scoping all at once.
  if curl -sS -o /dev/null --max-time 6 -x 127.0.0.1:3128 https://1.1.1.1 2>/dev/null; then
    echo "[firewall] FAIL: forward-proxy CONNECT (3128) reached a raw IP - egress filter bypassable" >&2
    exit 1
  fi
  # Deny: a forged Host over plaintext HTTP to a non-allowlisted IP must NOT be forwarded. squid
  # intercepts :80 and authorizes by the client-supplied Host; host_verify_strict (squid.conf) refuses a
  # Host that doesn't resolve to the connected IP. -f so squid's 409 denial counts as blocked (non-zero);
  # only a real 2xx/3xx (squid forwarded to the bogus IP) trips FAIL. Never false-fails a healthy box.
  if curl -fsS -o /dev/null --max-time 6 --resolve registry.npmjs.org:80:1.1.1.1 http://registry.npmjs.org/ 2>/dev/null; then
    echo "[firewall] FAIL: forged-Host HTTP reached a non-allowlisted IP - host verification off" >&2
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
