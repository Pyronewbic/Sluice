#!/bin/sh
# Scope name resolution to the egress allowlist. Writes dnsmasq per-domain forwarders from the squid
# allowlist: server=/host/upstream forwards only allowlisted names; everything else has no upstream
# (REFUSED), so an app can't tunnel exfil as DNS labels to an off-allowlist nameserver. Runs at boot
# (entrypoint, restricted mode) and on `sluice learn` hot-reload; dnsmasq re-reads this on SIGHUP.
set -eu
al=/etc/squid/allowlist.txt
up=/run/sluice-dns-upstream
out=/run/dnsmasq-servers.conf
: > "$out"
[ -f "$al" ] && [ -f "$up" ] || exit 0
ups="$(tr '\n' ' ' < "$up")"
while IFS= read -r h; do
  [ -n "$h" ] || continue
  case "$h" in \#*) continue ;; esac
  d="${h#.}"                       # leading-dot wildcard -> bare domain (dnsmasq matches subdomains)
  for u in $ups; do printf 'server=/%s/%s\n' "$d" "$u" >> "$out"; done
done < "$al"
