#!/bin/bash
# Egress firewall: force all HTTP/HTTPS through squid (hostname-filtered, spliced not decrypted);
# default-DROP everything else (other ports, IPv6, direct-IP). squid is the only uid allowed
# direct egress (enforces the allowlist + avoids the REDIRECT loop). See THREAT_MODEL.md.
set -euo pipefail

echo "[firewall] configuring hostname-filtered egress..."

# Per-project config (SLUICE_PORTS, SLUICE_ALLOW_IPS) - baked at /usr/local/share/sluice.config.sh.
[ -f /usr/local/share/sluice.config.sh ] && . /usr/local/share/sluice.config.sh
# Disable globbing so the unquoted SLUICE_PORTS / SLUICE_ALLOW_IPS splits below can't glob a '*' in a
# value into filenames. Nothing here needs pathname expansion. (No re-enable; we never glob.)
set -f

# Defense-in-depth floor (must match the launcher's validate_allow_ips): a SLUICE_ALLOW_IPS CIDR
# shorter than this is too broad for a raw direct-egress ACCEPT, so the firewall refuses it even if the
# launcher gate was bypassed (e.g. a hand-baked config). /32 (single host) is always fine.
ALLOW_IPS_MIN_PREFIX=8

# rc 0 (=refuse) if $1 (an ip/cidr, port already stripped) is too broad for a direct-egress ACCEPT:
# any 0.0.0.0/N, a malformed prefix, or a CIDR below the /8 floor. Called from BOTH SLUICE_ALLOW_IPS
# arms (bare + ip:port) so they can't drift. Warns on the refused entry; rc 1 = let it through.
_ip_entry_too_broad() {
  case "$1" in
    0.0.0.0|0.0.0.0/*)  echo "[firewall] WARN: refusing SLUICE_ALLOW_IPS entry covering 0.0.0.0 (all direct egress): $1" >&2; return 0 ;;
    */*)
      _plen="${1##*/}"
      case "$_plen" in
        ''|*[!0-9]*)  echo "[firewall] WARN: skipping malformed SLUICE_ALLOW_IPS entry: $1" >&2; return 0 ;;
        *) [ "$_plen" -lt "$ALLOW_IPS_MIN_PREFIX" ] && { echo "[firewall] WARN: refusing too-broad SLUICE_ALLOW_IPS /$_plen (floor /$ALLOW_IPS_MIN_PREFIX): $1" >&2; return 0; } ;;
      esac ;;
  esac
  return 1
}

# xt_quota may be absent on some kernels (Docker Desktop's LinuxKit, a Kata guest). Probe it in a
# throwaway chain and FAIL CLOSED: if a byte cap was requested but the module can't enforce it, refuse to
# boot rather than run without the cap the user asked for. Idempotent (called from the hard-cap + the
# allow-ips budget paths); the throwaway chain never survives.
_require_xt_quota() {
  iptables -N SLUICE-QPROBE 2>/dev/null || iptables -F SLUICE-QPROBE 2>/dev/null || true
  if iptables -A SLUICE-QPROBE -m quota --quota 1 -j RETURN 2>/dev/null; then
    iptables -F SLUICE-QPROBE 2>/dev/null || true; iptables -X SLUICE-QPROBE 2>/dev/null || true
    return 0
  fi
  iptables -F SLUICE-QPROBE 2>/dev/null || true; iptables -X SLUICE-QPROBE 2>/dev/null || true
  echo "[firewall] FAIL: an egress byte cap (SLUICE_EGRESS_HARD_CAP_BYTES / SLUICE_ALLOW_IPS_MAX_BYTES) was requested but this kernel lacks xt_quota - refusing to boot without the requested cap." >&2
  exit 1
}

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
# squid's own egress (the only uid allowed out; enforces the allowlist). SLUICE_EGRESS_HARD_CAP_BYTES:
# an optional PREVENTIVE per-boot ceiling on ALL proxied egress (bounds laundering by volume, unlike the
# detective SLUICE_EGRESS_MAX_BYTES). Metered with xt_quota: ACCEPT while under budget, then a uid-owner
# DROP once spent - so even an already-established squid flow hard-stops (per-packet match). This pair
# sits before the ESTABLISHED,RELATED accept below, or an in-flight flow would ride that accept past the cap.
_hardcap="${SLUICE_EGRESS_HARD_CAP_BYTES:-}"; case "$_hardcap" in ''|*[!0-9]*) _hardcap="" ;; esac
if [ -n "$_hardcap" ]; then
  _require_xt_quota
  iptables -A OUTPUT -m owner --uid-owner "$SQUID_UID" -m quota --quota "$_hardcap" -j ACCEPT
  iptables -A OUTPUT -m owner --uid-owner "$SQUID_UID" -j DROP
else
  iptables -A OUTPUT -m owner --uid-owner "$SQUID_UID" -j ACCEPT
fi
# DNS to the cache's real upstreams, dnsmasq (root) ONLY - so an app can't bypass the allowlist-scoped
# resolver by talking to the upstream directly. The entrypoint saved them to /run/sluice-dns-upstream;
# fall back to resolv.conf. Match IPv4 only.
dns_src=/run/sluice-dns-upstream
[ -f "$dns_src" ] || dns_src=/etc/resolv.conf
for ns in $(awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i }' "$dns_src" 2>/dev/null); do
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -m owner --uid-owner 0 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -m owner --uid-owner 0 -j ACCEPT
done
# SLUICE_ALLOW_IPS: reviewed fixed IPs/CIDRs get direct egress (escape hatch for non-HTTP). Each entry
# is ip[:port[/proto]] - a bare ip/cidr opens EVERY port (legacy), ip:5432 scopes to one tcp port,
# ip:5432/udp picks the proto. IPv4-only, so the single ':' splits host from port cleanly.
# Route every entry through the SLUICE-ALLOWIPS user chain instead of a bare ACCEPT so (a) its per-entry
# rule counters are visible to the receipt (allowips_rows) and (b) an optional shared byte budget
# (SLUICE_ALLOW_IPS_MAX_BYTES) can cap the lot. The jumps are emitted BEFORE the ESTABLISHED,RELATED
# accept below: the -d match is per-packet, so a long-lived direct-IP flow keeps traversing the chain and
# every packet is metered; after the state accept, only the connection-opening packet would ever reach it
# (a multi-GB exfil would meter as ~60 bytes - the ordering bug this chain fixes).
_allowips_budget="${SLUICE_ALLOW_IPS_MAX_BYTES:-}"; case "$_allowips_budget" in ''|*[!0-9]*) _allowips_budget="" ;; esac
_have_allowips=""
for entry in ${SLUICE_ALLOW_IPS:-}; do
  # Skip+warn an IPv6 literal (the single-colon split below is IPv4-only) - feeding iptables a broken
  # -d would abort the whole firewall under set -e, fail-closing the box on one malformed entry.
  case "$entry" in
    *::*)         echo "[firewall] WARN: skipping IPv6 SLUICE_ALLOW_IPS entry (IPv4-only): $entry" >&2; continue ;;
  esac
  case "$entry" in
    *:*)
      case "${entry#*:}" in *:*) echo "[firewall] WARN: skipping IPv6 SLUICE_ALLOW_IPS entry (IPv4-only): $entry" >&2; continue ;; esac
      ippart="${entry%%:*}"; portspec="${entry#*:}"; proto="tcp"; port="$portspec"
      case "$portspec" in */*) port="${portspec%%/*}"; proto="${portspec#*/}" ;; esac
      # The floor/0.0.0.0 refusal applies to the HOST part too - a port scopes the egress but doesn't
      # narrow the dst, so 0.0.0.0/1:443 would still open port 443 to half the internet, direct.
      _ip_entry_too_broad "$ippart" && continue
      [ -n "$_have_allowips" ] || { iptables -N SLUICE-ALLOWIPS; _have_allowips=1; }
      iptables -A OUTPUT -d "$ippart" -p "$proto" --dport "$port" -j SLUICE-ALLOWIPS ;;
    *)
      # Bare entry = ACCEPT every port to that dst. Refuse a too-broad CIDR (below the floor, or any
      # 0.0.0.0/N) so a bypassed launcher check can't open all direct egress; a /32 or a single IP is fine.
      _ip_entry_too_broad "$entry" && continue
      [ -n "$_have_allowips" ] || { iptables -N SLUICE-ALLOWIPS; _have_allowips=1; }
      iptables -A OUTPUT -d "$entry" -j SLUICE-ALLOWIPS ;;
  esac
done
# Chain body (added once, after the jumps): a shared preventive quota, else a plain accept. On budget
# exhaustion the DROP severs even established direct-IP flows mid-transfer (fail closed; documented).
if [ -n "$_have_allowips" ]; then
  if [ -n "$_allowips_budget" ]; then
    _require_xt_quota
    iptables -A SLUICE-ALLOWIPS -m quota --quota "$_allowips_budget" -j ACCEPT
    iptables -A SLUICE-ALLOWIPS -j DROP
  else
    iptables -A SLUICE-ALLOWIPS -j ACCEPT
  fi
fi
# ESTABLISHED,RELATED: accept return traffic. AFTER the ALLOW_IPS jumps above, so per-packet direct-IP
# metering isn't short-circuited by this state match.
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
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
# Hard cap: prove the uid-owner DROP that enforces it survived (else exhaustion silently un-caps egress).
# Shape only - never the quota byte value ('iptables -S' prints the counting-down REMAINING quota).
if [ -n "${_hardcap:-}" ]; then
  iptables -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner ${SQUID_UID} -j DROP" \
    || { echo "[firewall] FAIL: SLUICE_EGRESS_HARD_CAP_BYTES set but the uid-owner DROP is missing from OUTPUT" >&2; exit 1; }
fi
# ALLOW_IPS: prove the SLUICE-ALLOWIPS jumps precede the ESTABLISHED,RELATED accept - if they fell after
# it, a long-lived direct-IP flow would ride the state accept and never be metered. Rule-order shape check.
if [ -n "${_have_allowips:-}" ]; then
  _fwout="$(iptables -S OUTPUT 2>/dev/null || true)"
  _jln="$(printf '%s\n' "$_fwout" | grep -n -- '-j SLUICE-ALLOWIPS' | head -1 | cut -d: -f1 || true)"
  _eln="$(printf '%s\n' "$_fwout" | grep -nE -- '--state (ESTABLISHED,RELATED|RELATED,ESTABLISHED)' | tail -1 | cut -d: -f1 || true)"
  if [ -z "$_jln" ] || { [ -n "$_eln" ] && [ "$_jln" -gt "$_eln" ]; }; then
    echo "[firewall] FAIL: SLUICE-ALLOWIPS jumps missing or after the ESTABLISHED accept - direct-IP egress would be unmetered" >&2
    exit 1
  fi
fi
# Prove IPv6 egress is actually closed, INDEPENDENT of whether ip6tables is usable - a bare skip would
# rest v6 closure on an unverified --sysctl. Closed if the v6 stack is absent, OR disable_ipv6 took, OR
# ip6tables OUTPUT policy is DROP. Mirrors the disjunction in test/verify-security-egress-bypass.bats.
if [ ! -d /proc/sys/net/ipv6 ]; then :
elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 1 ]; then :
elif [ "$(ip6tables -S OUTPUT 2>/dev/null | head -1)" = '-P OUTPUT DROP' ]; then :
else
  echo "[firewall] FAIL: IPv6 egress not closed - disable_ipv6 off AND ip6tables OUTPUT not DROP" >&2
  exit 1
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
