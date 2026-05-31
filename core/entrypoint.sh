#!/bin/bash
# Runs as root on container start: bring up the egress filter (squid), lock down the
# network (init-firewall.sh), then idle so sessions can be exec'd in as the sluice user.
set -e

# --- squid allowlist: base hosts (registries + GitHub) + SLUICE_ALLOW_DOMAINS ---
. /usr/local/share/sluice.config.sh 2>/dev/null || true
{
  printf '%s\n' github.com api.github.com codeload.github.com objects.githubusercontent.com \
                registry.npmjs.org registry.yarnpkg.com
  for d in ${SLUICE_ALLOW_DOMAINS:-}; do printf '%s\n' "$d"; done
} > /etc/squid/allowlist.txt

# Audit mode (learn --audit): open egress to ALL HTTP/HTTPS hosts so one run logs every host the
# app reaches. Runtime-only - edits this container's own /etc/squid.conf, never the image; the
# container is ephemeral + credential-stripped. iptables still drops non-HTTP ports + IPv6.
if [ "${SLUICE_AUDIT:-}" = 1 ]; then
  echo "[sluice] AUDIT MODE: egress OPEN to all HTTP/HTTPS hosts (logging every SNI). Trusted code, no creds." >&2
  sed -i -e 's/^ssl_bump splice allowed_sni$/ssl_bump splice all/' \
         -e 's/^http_access allow allowed_host$/http_access allow all/' /etc/squid.conf
fi

# (IPv6-off + route_localnet are set via --sysctl at docker run; /proc/sys is ro here.)

# --- caching DNS resolver (dnsmasq) ---------------------------------------------
# squid's transparent-intercept Host-forgery check compares the client's connected IP
# against squid's own DNS of the SNI. For rotating-CDN hosts (Google/Akamai) the two
# lookups land on different pool IPs, so squid 409s a legitimate allowlisted host. A
# shared cache makes the client and squid see the same IP set, so the check passes.
dns_up="$(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null | grep -v ':' | tr '\n' ' ')"
[ -n "$dns_up" ] || dns_up="127.0.0.11"     # docker embedded DNS
printf '%s\n' $dns_up > /run/sluice-dns-upstream   # init-firewall allows these for dnsmasq
{
  echo "no-resolv"                 # never read /etc/resolv.conf (we point it back at us -> loop)
  echo "no-hosts"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "user=root"                 # wolfi-base has no dnsmasq/nobody user to drop to
  echo "cache-size=2000"
  echo "min-cache-ttl=3600"        # pin pool IPs long enough that client + squid agree
  for u in $dns_up; do echo "server=$u"; done
} > /etc/dnsmasq-sluice.conf
dnsmasq --conf-file=/etc/dnsmasq-sluice.conf
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf  # client + squid resolve via the cache
ok=0
for _ in $(seq 1 20); do
  if [ -n "$(dig +short +time=1 +tries=1 @127.0.0.1 registry.npmjs.org 2>/dev/null)" ]; then ok=1; break; fi
  sleep 0.25
done
if [ "$ok" != 1 ]; then
  echo "[sluice] FATAL: dnsmasq did not come up on 127.0.0.1:53 - DNS cache unavailable" >&2
  exit 1
fi

# --- start the egress filter BEFORE the firewall --------------------------------
# (init-firewall.sh's self-test makes a real request through the proxy.)
mkdir -p /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid
# Throwaway splice cert, generated per-container (so the published base image carries no key).
# We splice (never forge), so it is never presented - it only lets squid bind the ssl-bump port.
if [ ! -f /etc/squid/ssl/squid-cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /etc/squid/ssl/squid-key.pem -out /etc/squid/ssl/squid-cert.pem \
    -subj "/CN=sluice-egress-filter" 2>/dev/null
  chmod 600 /etc/squid/ssl/squid-key.pem
fi
chown -R squid:squid /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid 2>/dev/null || true
# -N (single process) avoids flaky SMP/shm startup; squid drops to its own uid after binding.
squid -N &
ok=0
for _ in $(seq 1 40); do
  if (exec 3<>/dev/tcp/127.0.0.1/3130) 2>/dev/null; then exec 3>&- 3<&-; ok=1; break; fi
  sleep 0.25
done
if [ "$ok" != 1 ]; then
  echo "[sluice] FATAL: squid did not come up on :3130 - egress filter unavailable" >&2
  tail -n 20 /var/log/squid/cache.log 2>/dev/null || true
  exit 1
fi

/usr/local/bin/init-firewall.sh

# User-writable npm prefix (NPM_CONFIG_PREFIX=/home/sluice/.npm-global) for runtime installs.
mkdir -p /home/sluice/.npm-global
chown sluice:sluice /home/sluice/.npm-global 2>/dev/null || true

# chown the mounted repo (and any persisted SLUICE_STATE_DIRS) to sluice when not already
# (Linux bind mounts keep the host uid; no-op at uid 1000 / Docker Desktop).
for d in "${SLUICE_WORKDIR:-}" "${SLUICE_GITDIR:-}" ${SLUICE_STATE_PATHS:-}; do
  if [ -n "$d" ] && [ -d "$d" ]; then
    if [ "$(stat -c %u "$d" 2>/dev/null || echo 0)" != 1000 ]; then
      chown -R sluice:sluice "$d" 2>/dev/null || true
    fi
  fi
done

echo "[sluice] ready. exec sessions as the sluice user."
exec sleep infinity
