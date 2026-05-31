#!/bin/bash
# Runs as root on container start: bring up the egress filter (squid), lock down the
# network (init-firewall.sh), then idle so sessions can be exec'd in as the node user.
set -e

# --- squid allowlist: base hosts (registries + GitHub) + SLUICE_ALLOW_DOMAINS ---
. /usr/local/share/sluice.config.sh 2>/dev/null || true
{
  printf '%s\n' github.com api.github.com codeload.github.com objects.githubusercontent.com \
                registry.npmjs.org registry.yarnpkg.com
  for d in ${SLUICE_ALLOW_DOMAINS:-}; do printf '%s\n' "$d"; done
} > /etc/squid/allowlist.txt

# (IPv6-off + route_localnet are set via --sysctl at docker run; /proc/sys is ro here.)

# --- start the egress filter BEFORE the firewall --------------------------------
# (init-firewall.sh's self-test makes a real request through the proxy.)
mkdir -p /var/log/squid /var/cache/squid /run/squid
chown -R squid:squid /var/log/squid /var/cache/squid /run/squid 2>/dev/null || true
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

# User-writable npm prefix (NPM_CONFIG_PREFIX=/home/node/.npm-global) for runtime installs.
mkdir -p /home/node/.npm-global
chown node:node /home/node/.npm-global 2>/dev/null || true

# chown the mounted repo to node when it isn't already (Linux bind mounts keep the host uid).
for d in "${SLUICE_WORKDIR:-}" "${SLUICE_GITDIR:-}"; do
  if [ -n "$d" ] && [ -d "$d" ]; then
    if [ "$(stat -c %u "$d" 2>/dev/null || echo 0)" != 1000 ]; then
      chown -R node:node "$d" 2>/dev/null || true
    fi
  fi
done

echo "[sluice] ready. exec sessions as the node user."
exec sleep infinity
