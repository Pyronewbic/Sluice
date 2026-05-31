# sluice project config — copy to your project as `sluice.config.sh` and edit.
#
# Sourced in three places, so keep it POSIX-sh-safe:
#   - the Dockerfile build   (/bin/sh)  → SLUICE_EXTRA_PKGS, SLUICE_EXTRA_NPM, SLUICE_SETUP_CMDS
#   - init-firewall.sh at boot (bash)   → SLUICE_ALLOW_DOMAINS, SLUICE_ALLOW_IPS, SLUICE_PORTS
#   - bin/sluice on the host      (bash)   → SLUICE_PORTS, SLUICE_RUN_CMD, SLUICE_ENV, SLUICE_MOUNTS, SLUICE_PRELAUNCH
# Use plain space/newline-separated strings — NO bash arrays.
#
# Every knob is optional. A minimal config is just a SLUICE_RUN_CMD.

# --- software (baked into the image at build time) ------------------------------

# Extra apk packages on top of the base (node/npm/git/gh/curl/jq + firewall tools).
# Space-separated. e.g. "terraform postgresql-16-client python-3.12"
SLUICE_EXTRA_PKGS=""

# Extra global npm packages, pinned for supply-chain hygiene (baked, not npx'd).
# Space-separated. e.g. "pnpm @some/mcp-server@1.2.3"
SLUICE_EXTRA_NPM=""

# Build-time setup: clones, dependency installs, codegen. Runs as the non-root node
# user in /home/node, on the host BEFORE the firewall — so egress is unrestricted here
# (the *running* container is still locked to the allowlist). One shell string; chain
# with && or newlines. Whatever it writes is node-owned and writable at runtime.
# e.g. "git clone --depth 1 https://example.com/app && cd app && npm ci"
SLUICE_SETUP_CMDS=""

# --- egress allowlist (runtime; default-DROP otherwise) -------------------------

# HTTP/HTTPS hosts the running container may reach, ON TOP of the base (npm/yarn
# registries + GitHub git/release hosts). Space/newline-separated. Egress is matched by
# Host/TLS-SNI through an in-sluice proxy (by name, not IP — survives IP rotation); a leading
# dot matches subdomains (".example.com"). This is usually the one thing you must get
# right: anything the app fetches at runtime (CDNs, sample/asset hosts, APIs) must be
# listed or the proxy silently blocks it.
SLUICE_ALLOW_DOMAINS=""

# Fixed IPs/CIDRs for NON-HTTP services (e.g. a database) — direct egress on any port,
# bypassing the hostname proxy. Space-separated. Keep minimal. e.g. "203.0.113.7/32"
SLUICE_ALLOW_IPS=""

# --- serving --------------------------------------------------------------------

# TCP ports to publish to the host (bound to 127.0.0.1 → reach via localhost only).
# Space-separated. The firewall opens a matching inbound rule for each. The app MUST
# bind 0.0.0.0 inside the container (not 127.0.0.1) for forwarded traffic to reach it.
SLUICE_PORTS=""

# --- run ------------------------------------------------------------------------

# The command run by a bare `sluice` (a single shell string, run as node in the project
# dir). Defaults to an interactive bash if unset. e.g. "npm run dev -- --host 0.0.0.0"
SLUICE_RUN_CMD="bash"

# --- optional: credentials / extra wiring (host → container) --------------------

# Names of host env vars to forward into the container session (values come from your
# host environment / the prelaunch hook below). Space-separated. e.g. "GH_TOKEN API_KEY"
SLUICE_ENV=""

# Extra bind mounts, newline-separated "host:container[:ro]". e.g.
#   SLUICE_MOUNTS="$HOME/.config/gh:/home/node/.config/gh:ro
#   $HOME/.cache/app:/home/node/.cache/app"
SLUICE_MOUNTS=""

# Name of a shell function defined in THIS file, run on the host before launch — use
# it to mint/stage short-lived credentials (write a token file, then expose its path
# via SLUICE_MOUNTS, or export an env var named in SLUICE_ENV). Keeps cred plumbing in the
# project config, out of the generic core. e.g.
#   stage_creds() { umask 077; gcloud auth print-access-token > "$HOME/.cache/app/token"; }
#   SLUICE_PRELAUNCH="stage_creds"
SLUICE_PRELAUNCH=""
