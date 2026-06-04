# SLUICE_ALLOW_IPS - reach a database (or any non-HTTP service) at a fixed IP, made visible.
#
#   mkdir db && cp examples/database.config.sh db/sluice.config.sh && cd db && sluice
#
# The egress firewall proxies HTTP/HTTPS by hostname; everything else is default-DROP. A database
# (Postgres/Redis/MySQL) speaks its own protocol on its own port, so it can't go through the
# hostname proxy - it needs the SLUICE_ALLOW_IPS escape hatch: a reviewed fixed IP/CIDR gets direct
# egress, bypassing the proxy. Scope it to one port with IP:port (a bare IP/CIDR opens every port);
# 80/443 are always proxied. This demo proves it with a raw TCP connection on the allowed port - swap
# the IP/port for your DB. Runs to completion; no server.
SLUICE_ALLOW_IPS="1.1.1.1:853"
SLUICE_RUN_CMD='
probe() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo "  reachable" || echo "  BLOCKED (firewall dropped it)"; }
echo "Allowed fixed IP:port (stands in for your database):"
echo "  1.1.1.1:853  (in SLUICE_ALLOW_IPS):"
probe 1.1.1.1 853
echo "Any other IP is still default-DROP:"
echo "  8.8.8.8:853  (NOT allowlisted):"
probe 8.8.8.8 853
echo
echo "-> set SLUICE_ALLOW_IPS to your DB host and port, e.g. 10.0.0.5:5432 (Postgres), :6379 (Redis)."
echo "   Scope to the port: 10.0.0.5:5432 grants ONLY 5432; a bare 10.0.0.5 opens every port."
'
