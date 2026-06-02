#!/bin/bash
# Runs as root on container start: bring up the egress filter (squid), lock down the
# network (init-firewall.sh), then idle so sessions can be exec'd in as the sluice user.
set -e

. /usr/local/share/sluice.config.sh 2>/dev/null || true
# SLUICE_RUNTIME_ALLOW (live allowlist from the launcher) wins over the baked copy, so an allowlist
# edit (e.g. `sluice learn`) needs no rebuild. Set-but-empty clears it; unset keeps the baked value.
[ -n "${SLUICE_RUNTIME_ALLOW+x}" ] && SLUICE_ALLOW_DOMAINS="${SLUICE_RUNTIME_ALLOW}"
# Same override semantics for the opt-in TLS-interception (bump) knobs (default off; see below).
[ -n "${SLUICE_RUNTIME_BUMP+x}" ]      && SLUICE_BUMP_DOMAINS="${SLUICE_RUNTIME_BUMP}"
[ -n "${SLUICE_RUNTIME_BUMP_URLS+x}" ] && SLUICE_BUMP_URLS="${SLUICE_RUNTIME_BUMP_URLS}"
{
  printf '%s\n' github.com api.github.com codeload.github.com objects.githubusercontent.com \
                registry.npmjs.org registry.yarnpkg.com
  for d in ${SLUICE_ALLOW_DOMAINS:-}; do printf '%s\n' "$d"; done
  # Central egress policy hosts (SLUICE_POLICY_URL), fetched + passed by the launcher at run.
  for d in ${SLUICE_POLICY_ALLOW:-}; do printf '%s\n' "$d"; done
} > /etc/squid/allowlist.txt

# DoH/DoT resolvers are denied even when allowlisted (an agent could tunnel exfil as DNS-over-HTTPS
# past the SNI allowlist). The denylist is baked at /etc/squid/doh-endpoints.txt; SLUICE_ALLOW_DOH=1
# clears it to opt back in.
[ "${SLUICE_ALLOW_DOH:-}" = 1 ] && : > /etc/squid/doh-endpoints.txt

# Audit mode (learn --audit): open egress to ALL HTTP/HTTPS so one run logs every host the app reaches.
# Runtime-only (this container's squid.conf, never the image); ephemeral + cred-stripped; iptables still drops non-HTTP + IPv6.
if [ "${SLUICE_AUDIT:-}" = 1 ]; then
  echo "[sluice] AUDIT MODE: egress OPEN to all HTTP/HTTPS hosts (logging every SNI). Trusted code, no creds." >&2
  : > /etc/squid/doh-endpoints.txt   # audit discovers everything the app reaches, DoH included
  sed -i -e 's/^ssl_bump splice allowed_sni$/ssl_bump splice all/' \
         -e 's/^http_access allow allowed_host$/http_access allow all/' /etc/squid.conf
fi

# (IPv6-off + route_localnet are set via --sysctl at docker run; /proc/sys is ro here.)

# squid's transparent-intercept Host-forgery check compares the client's connected IP against squid's
# own DNS of the SNI. For rotating-CDN hosts (Google/Akamai) the two lookups can hit different pool IPs,
# so squid 409s a legit allowlisted host. A shared DNS cache makes both see the same IPs, so it passes.
# Upstream resolvers for dnsmasq. Normally read from the resolv.conf docker set; in read-only mode
# resolv.conf is already 127.0.0.1 (the launcher sets it via --dns, since we can't rewrite it under
# --read-only), so the launcher passes the real upstream(s) in SLUICE_DNS_UPSTREAM instead.
if [ -n "${SLUICE_DNS_UPSTREAM:-}" ]; then
  dns_up="$SLUICE_DNS_UPSTREAM"
else
  dns_up="$(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null | grep -v ':' | tr '\n' ' ')"
fi
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
} > /run/dnsmasq-sluice.conf       # /run (not /etc) so it works under a read-only rootfs
dnsmasq --conf-file=/run/dnsmasq-sluice.conf
# Point client + squid at the dnsmasq cache. Read-only mode already has resolv.conf=127.0.0.1 (--dns).
[ "${SLUICE_READONLY_ROOT:-}" = 1 ] || printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
ok=0
for _ in $(seq 1 20); do
  if [ -n "$(dig +short +time=1 +tries=1 @127.0.0.1 registry.npmjs.org 2>/dev/null)" ]; then ok=1; break; fi
  sleep 0.25
done
if [ "$ok" != 1 ]; then
  echo "[sluice] FATAL: dnsmasq did not come up on 127.0.0.1:53 - DNS cache unavailable" >&2
  exit 1
fi

# Start squid before the firewall: init-firewall.sh's self-test makes a real request through it.
mkdir -p /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid
# Egress-filter cert. Default: a throwaway splice cert (never presented - we splice, never forge - so
# the published base carries no key). With SLUICE_BUMP_DOMAINS set (scoped TLS interception, opt-in;
# see THREAT_MODEL) the named hosts are decrypted for URL filtering, needing a per-container CA the box trusts.
if [ -n "${SLUICE_BUMP_DOMAINS:-}" ] && [ "${SLUICE_AUDIT:-}" != 1 ]; then
  : > /etc/squid/bumplist.txt; for d in ${SLUICE_BUMP_DOMAINS};   do printf '%s\n' "$d" >> /etc/squid/bumplist.txt; done
  : > /etc/squid/bump-urls.txt; for u in ${SLUICE_BUMP_URLS:-};   do printf '%s\n' "$u" >> /etc/squid/bump-urls.txt; done
  echo "[sluice] TLS interception (bump) ON for: $(tr '\n' ' ' < /etc/squid/bumplist.txt)- everything else still splices." >&2
  if [ ! -f /etc/squid/ssl/squid-cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout /etc/squid/ssl/squid-key.pem -out /etc/squid/ssl/squid-cert.pem \
      -subj "/CN=sluice-egress-ca" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    chmod 600 /etc/squid/ssl/squid-key.pem
    # Make the box trust the CA. wolfi has no update-ca-certificates: append to the system bundle (this
    # combined file is what SSL_CERT_FILE/REQUESTS_CA_BUNDLE point at; NODE_EXTRA_CA_CERTS gets the bare CA).
    cat /etc/squid/ssl/squid-cert.pem >> /etc/ssl/certs/ca-certificates.crt
  fi
  # Per-host cert forging: init the cert-gen db (the helper creates the dir; the parent must exist).
  [ -d /var/cache/squid/ssl_db ] || /usr/libexec/security_file_certgen -c -s /var/cache/squid/ssl_db -M 4MB >/dev/null 2>&1
  # Turn on dynamic cert generation + the bump ACLs/rules (the static squid.conf stays splice-only).
  # Idempotent: skip if already applied (a container restart re-runs this entrypoint).
  if ! grep -q '^ssl_bump bump bump_sni' /etc/squid.conf; then
    sed -i \
      -e 's#^  generate-host-certificates=off#  generate-host-certificates=on#' \
      -e '/^  generate-host-certificates=on/a sslcrtd_program /usr/libexec/security_file_certgen -s /var/cache/squid/ssl_db -M 4MB\nsslcrtd_children 4' \
      -e '/^acl ssl_tunnel   method CONNECT/a acl bump_sni ssl::server_name "/etc/squid/bumplist.txt"\nacl bump_dom dstdomain        "/etc/squid/bumplist.txt"\nacl bump_url url_regex        "/etc/squid/bump-urls.txt"' \
      -e 's#^ssl_bump splice allowed_sni#ssl_bump bump bump_sni\nssl_bump splice allowed_sni#' \
      /etc/squid.conf
    # Enforce per-URL only when patterns were given; else the bumped host is allowed wholesale (you
    # still get full-URL logging). Patterns should embed the host, scoping them to one bumped host.
    [ -s /etc/squid/bump-urls.txt ] \
      && sed -i 's#^http_access allow allowed_host#http_access deny bump_dom !bump_url\nhttp_access allow allowed_host#' /etc/squid.conf
  fi
else
  # Throwaway splice cert, generated per-container (so the published base image carries no key).
  # We splice (never forge), so it is never presented - it only lets squid bind the ssl-bump port.
  if [ ! -f /etc/squid/ssl/squid-cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout /etc/squid/ssl/squid-key.pem -out /etc/squid/ssl/squid-cert.pem \
      -subj "/CN=sluice-egress-filter" 2>/dev/null
    chmod 600 /etc/squid/ssl/squid-key.pem
  fi
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

# SLUICE_WORKSPACE=overlay: the host repo is mounted READ-ONLY at /mnt/sluice-orig; seed the writable
# working copy (an anon volume at SLUICE_WORKDIR) from it. The agent works on the copy; the host repo
# is untouched until `sluice apply`. The chown loop below then hands the copy to the sluice user.
if [ "${SLUICE_WORKSPACE:-}" = overlay ] && [ -d /mnt/sluice-orig ] && [ -n "${SLUICE_WORKDIR:-}" ]; then
  cp -a /mnt/sluice-orig/. "$SLUICE_WORKDIR"/ 2>/dev/null || true
fi

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
