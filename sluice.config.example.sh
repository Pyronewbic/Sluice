# sluice project config - copy to your project as `sluice.config.sh` and edit.
#
# Sourced in three places, so keep it POSIX-sh-safe:
#   - the Dockerfile build   (/bin/sh)  -> SLUICE_EXTRA_PKGS, SLUICE_EXTRA_NPM, SLUICE_SETUP_CMDS
#   - init-firewall.sh at boot (bash)   -> SLUICE_ALLOW_DOMAINS, SLUICE_ALLOW_IPS, SLUICE_PORTS
#   - bin/sluice on the host      (bash)   -> SLUICE_PORTS, SLUICE_RUN_CMD, SLUICE_ENV, SLUICE_MOUNTS, SLUICE_PRELAUNCH
# Use plain space/newline-separated strings - NO bash arrays.
#
# Every knob is optional. A minimal config is just a SLUICE_RUN_CMD.

# --- identity -------------------------------------------------------------------

# Image/container name (sluice-<name>). Defaults to the project directory's name.
# Set it when two checkouts share a basename, or to pin a stable name across worktrees.
SLUICE_NAME=""

# One-line human description, shown in `sluice ls` and `sluice doctor` (optional).
SLUICE_DESC=""

# --- software (baked into the image at build time) ------------------------------

# Extra apk packages on top of the base (node/npm/git/gh/curl/jq + firewall tools).
# Space-separated. e.g. "terraform postgresql-16-client python-3.12"
# Installed unpinned (Wolfi is a rolling repo); run `sluice lock` to record the exact resolved
# versions + digests to a committable sluice.lock (audit/drift; `sluice doctor` flags drift).
SLUICE_EXTRA_PKGS=""

# Extra global npm packages, pinned for supply-chain hygiene (baked, not npx'd).
# Space-separated. e.g. "pnpm @some/mcp-server@1.2.3"
SLUICE_EXTRA_NPM=""

# Build-time setup: clones, dependency installs, codegen. Runs as the non-root sluice
# user in /home/sluice, on the host BEFORE the firewall - so egress is unrestricted here
# (the *running* container is still locked to the allowlist). One shell string; chain
# with && or newlines. Whatever it writes is sluice-owned and writable at runtime.
# e.g. "git clone --depth 1 https://example.com/app && cd app && npm ci"
SLUICE_SETUP_CMDS=""

# Like SLUICE_SETUP_CMDS but run as ROOT at build (free egress, same trust as SLUICE_EXTRA_PKGS).
# For provisioning OUTSIDE the home dir - creating dirs the sluice user then owns, /opt, etc.
# Runs before SLUICE_SETUP_CMDS. One shell string. e.g. (single-user Nix store):
#   SLUICE_SETUP_ROOT_CMDS='mkdir -p /nix && chown sluice:sluice /nix'
SLUICE_SETUP_ROOT_CMDS=""

# Dep prefetch (tighter runtime egress): fetch the project's deps at BUILD (free egress) into a $HOME
# cache the runtime mount won't shadow, so the runtime allowlist can DROP the package registry and
# repeat runs skip the re-fetch. SLUICE_PREFETCH_FILES = manifests copied into the build; SLUICE_PREFETCH_CMD
# = the fetch, run in a staging dir after SLUICE_SETUP_CMDS. `sluice init` sets these for go/rust/ruby/
# python-pip when a lockfile is present (and switches the run command to offline). e.g. (go):
#   SLUICE_PREFETCH_FILES="go.mod go.sum"   SLUICE_PREFETCH_CMD="go mod download"   (run with GOPROXY=off)
SLUICE_PREFETCH_FILES=""
SLUICE_PREFETCH_CMD=""

# Build the project layer FROM a prebuilt, cosign-signed base instead of rebuilding the core
# locally (faster; auditable). Opt-in: set to a published ref, e.g.
# "ghcr.io/pyronewbic/sluice-base:0.2.1". sluice cosign-verifies it if cosign is installed
# (SLUICE_REQUIRE_SIGNED=1 makes a missing/failed signature fatal). Unset = build from core/.
SLUICE_BASE_IMAGE=""

# --- egress allowlist (runtime; default-DROP otherwise) -------------------------

# HTTP/HTTPS hosts the running container may reach, ON TOP of the base (npm/yarn
# registries + GitHub git/release hosts). Space/newline-separated. Egress is matched by
# Host/TLS-SNI through an in-sluice proxy (by name, not IP - survives IP rotation); a leading
# dot matches subdomains (".example.com"). This is usually the one thing you must get
# right: anything the app fetches at runtime (CDNs, sample/asset hosts, APIs) must be
# listed or the proxy blocks it (sluice flags the host at exit; 'sluice learn' to allow).
SLUICE_ALLOW_DOMAINS=""

# Fixed IPs/CIDRs for NON-HTTP services (e.g. a database) - direct egress on any port,
# bypassing the hostname proxy. Space-separated. Keep minimal. e.g. "203.0.113.7/32"
SLUICE_ALLOW_IPS=""

# Central egress policy: a URL (http/https/file) returning a plain-text allowlist (one host per
# line, # comments OK), fetched on the HOST at run and merged into this box's allowlist. Additive
# only (it can't weaken the sandbox) and host-trusted - keep it a URL you control. e.g. a shared
# org allowlist. Leave empty for none.
SLUICE_POLICY_URL=""

# Scoped TLS interception (SSL-bump): OPT-IN, OFF BY DEFAULT. By default every allowed host is
# spliced (SNI read, never decrypted). List a host here and the box mints a per-container CA, trusts
# it, and decrypts that host so squid can filter by URL - every other host still splices. Space/
# newline-separated. WEIGH IT: a CA signing key then lives in the box for that run (blast radius is
# the box itself), and cert-pinned hosts can't be bumped (they fail TLS) - list only hosts you
# control or that don't pin. See THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default.
# e.g. "api.internal.example.com"
SLUICE_BUMP_DOMAINS=""

# url_regex patterns ALLOWED on a bumped host; non-matching paths get 403. Embed the host in the
# pattern so it scopes to one bumped host. Space/newline-separated. Empty = allow each bumped host
# wholesale but log its full URLs. e.g. "^https?://api\.internal\.example\.com/v1/"
SLUICE_BUMP_URLS=""

# --- hardening (opt-in; off by default) -----------------------------------------

# Extra seccomp syscall filter on top of the already-dropped caps. "hardened" = a denylist that is a
# strict superset of the engine default (blocks userns/ptrace/bpf/mount/modules/userfaultfd, the
# ASLR-disable path, ...). "browser" = hardened minus the calls Chromium/Playwright need to build
# their own userns sandbox. "audit" = log-only (observe, enforce nothing). Unset = the engine's
# default profile. See THREAT_MODEL.md.
SLUICE_SECCOMP=""

# Immutable rootfs: tmpfs the ephemeral system paths; /etc/squid + /home/sluice become writable anon
# volumes pre-populated from the image. Set to 1 to enable.
SLUICE_READONLY_ROOT=""

# Protected workspace: mount the host repo READ-ONLY and have the box edit a throwaway copy - review
# with `sluice diff`, write back with `sluice apply`. Set to "overlay" to enable.
SLUICE_WORKSPACE=""

# --- serving --------------------------------------------------------------------

# TCP ports to publish to the host (bound to 127.0.0.1 -> reach via localhost only).
# Space-separated. The firewall opens a matching inbound rule for each. The app MUST
# bind 0.0.0.0 inside the container (not 127.0.0.1) for forwarded traffic to reach it.
SLUICE_PORTS=""

# --- run ------------------------------------------------------------------------

# The command run by a bare `sluice` (a single shell string, run as node in the project
# dir). Defaults to an interactive bash if unset. e.g. "npm run dev -- --host 0.0.0.0"
SLUICE_RUN_CMD="bash"

# --- optional: credentials / extra wiring (host -> container) --------------------

# Names of host env vars to forward into the container session (values come from your
# host environment / the prelaunch hook below). Space-separated. e.g. "GH_TOKEN API_KEY"
SLUICE_ENV=""

# Extra bind mounts, newline-separated "host:container[:ro]". e.g.
#   SLUICE_MOUNTS="$HOME/.config/gh:/home/sluice/.config/gh:ro
#   $HOME/.cache/app:/home/sluice/.cache/app"
SLUICE_MOUNTS=""

# Home-relative dirs to PERSIST across container recreation (rebuild, `sluice stop`, reboot).
# Each is bind-mounted from a per-project host store ($XDG_STATE_HOME/sluice/<name>, default
# ~/.local/state/sluice/<name>) into /home/sluice - so a coding agent's sessions/history/auth
# survive runs (the agents/ presets set this). Dirs only; relative paths (no leading / or ..);
# never list a dir holding baked binaries/config (.npm-global, or .local for some agents).
# Space/newline-separated. e.g. ".claude"  or  ".myagent .config/myagent"
SLUICE_STATE_DIRS=""

# Name of a shell function defined in THIS file, run on the host before launch - use
# it to mint/stage short-lived credentials (write a token file, then expose its path
# via SLUICE_MOUNTS, or export an env var named in SLUICE_ENV). Keeps cred plumbing in the
# project config, out of the generic core. e.g.
#   stage_creds() { umask 077; gcloud auth print-access-token > "$HOME/.cache/app/token"; }
#   SLUICE_PRELAUNCH="stage_creds"
SLUICE_PRELAUNCH=""
