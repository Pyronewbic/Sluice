# sluice project config - copy to your project as `sluice.config.sh` and edit.
#
# Sourced as POSIX sh in four places - keep it sh-safe (space/newline strings, NO bash arrays):
#   - the Dockerfile build     (/bin/sh) -> SLUICE_EXTRA_PKGS/_NPM, SLUICE_SETUP*_CMDS, SLUICE_PREFETCH_*
#   - entrypoint.sh at boot    (bash)    -> SLUICE_ALLOW_DOMAINS, SLUICE_BUMP_*, SLUICE_DNS_OPEN, SLUICE_ALLOW_DOH
#   - init-firewall.sh at boot (bash)    -> SLUICE_PORTS, SLUICE_ALLOW_IPS
#   - bin/sluice on the host   (bash)    -> everything else (run/mounts/env/hardening)
#
# Every knob is optional - a minimal config is just a SLUICE_RUN_CMD.
# Full semantics, defaults, and when an edit applies: docs/configuration.md.

# --- identity -------------------------------------------------------------------

# Image/container name (sluice-<name>). Defaults to the project directory's name;
# set it when two checkouts share a basename.
SLUICE_NAME=""

# One-line description, shown in `sluice ls` and `sluice doctor`.
SLUICE_DESC=""

# --- software (baked into the image at build time) ------------------------------

# Extra apk packages on top of the base (node/npm/git/gh/curl/jq + firewall tools).
# Space-separated, unpinned - `sluice lock` records the resolved versions.
# e.g. "terraform postgresql-16-client python-3.12"
SLUICE_EXTRA_PKGS=""

# Extra global npm packages, pinned and baked at build.
# e.g. "pnpm @some/mcp-server@1.2.3"
SLUICE_EXTRA_NPM=""

# Build-time setup as the non-root sluice user in /home/sluice (clones, installs, codegen).
# Free egress at build; the RUNNING box stays locked to the allowlist. One shell string.
# e.g. "git clone --depth 1 https://example.com/app && cd app && npm ci"
SLUICE_SETUP_CMDS=""

# Like SLUICE_SETUP_CMDS but as ROOT, run first - provisioning outside the home dir.
# e.g. (single-user Nix store): 'mkdir -p /nix && chown sluice:sluice /nix'
SLUICE_SETUP_ROOT_CMDS=""

# Dep prefetch: copy the manifests into the build and fetch deps into a $HOME cache, so the
# runtime allowlist can drop the package registry. `sluice init` sets these for go/rust/ruby/
# pip when a lockfile is present. e.g. (go, run with GOPROXY=off):
#   SLUICE_PREFETCH_FILES="go.mod go.sum"   SLUICE_PREFETCH_CMD="go mod download"
SLUICE_PREFETCH_FILES=""
SLUICE_PREFETCH_CMD=""

# Build FROM a prebuilt, cosign-signed base instead of rebuilding core/ locally (faster;
# auditable; SLUICE_REQUIRE_SIGNED=1 makes a missing/failed signature fatal). Unset = build from core/.
# e.g. "ghcr.io/pyronewbic/sluice-base:0.2.1"
SLUICE_BASE_IMAGE=""

# Verified pinned replay: =1 builds from ./sluice.pin (base digest + exact versions, written by
# `sluice lock --pin`) and verifies the result against sluice.lock (fails closed on drift). Also
# settable as an env var. `sluice update` re-resolves + re-pins. See docs/supply-chain.md.
SLUICE_PIN=""

# --- egress allowlist (runtime; default-DROP otherwise) -------------------------

# HTTP/HTTPS hosts the running box may reach, on top of the base (npm/yarn registries +
# GitHub hosts). Matched by Host/TLS-SNI; a leading dot matches subdomains (".example.com").
# The one no-rebuild knob - `sluice learn` edits it live. e.g. "api.example.com .cdn.example.net"
SLUICE_ALLOW_DOMAINS=""

# Fixed IPs/CIDRs for NON-HTTP services - direct egress, bypassing the hostname proxy. IPv4-only.
# Scope each to one port with ip:port[/proto]; a colon-less entry opens EVERY port (warns). Refused:
# any /0 or 0.0.0.0/N, a CIDR broader than the /8 floor, and IPv6. e.g. "10.0.0.5:5432" (Postgres)
SLUICE_ALLOW_IPS=""

# Shared PREVENTIVE byte budget across ALL SLUICE_ALLOW_IPS direct egress (in-box xt_quota; over it the
# direct-IP flows are severed). Numeric; needs xt_quota (fails closed if absent). Empty = off.
SLUICE_ALLOW_IPS_MAX_BYTES=""

# Central egress policy: a URL (http/https/file) to an org policy, applied host-side as the final
# gate. A bare host list adds hosts (back-compat); v2 directives also `deny` hosts and refuse to run
# on a crossed ceiling (forbid <knob> / deny-ip / max-allow-ips / forbid-laundering). Also read from
# ~/.config/sluice/policy.conf and a root-owned /etc/sluice/policy.conf. See docs/policy.md.
SLUICE_POLICY_URL=""

# Scoped TLS interception (SSL-bump): OPT-IN, OFF BY DEFAULT. Listed hosts are decrypted so
# squid can filter by URL; every other host is spliced (SNI read, never decrypted). Weigh it
# first: THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default.
# e.g. "api.internal.example.com"
SLUICE_BUMP_DOMAINS=""

# url_regex patterns ALLOWED on a bumped host (embed the host so it scopes to one).
# Empty = allow each bumped host wholesale but log its full URLs.
# e.g. "^https?://api\.internal\.example\.com/v1/"
SLUICE_BUMP_URLS=""

# Bumped-lane upload controls (no-op without SLUICE_BUMP_DOMAINS). METHODS = an HTTP-method allowlist
# for the decrypted host (deny uploads); MAX_BODY = request-body byte cap (per request; 413 over it).
# e.g. SLUICE_BUMP_METHODS="GET HEAD"   SLUICE_BUMP_MAX_BODY="1048576"
SLUICE_BUMP_METHODS=""
SLUICE_BUMP_MAX_BODY=""

# DNS is scoped to the allowlist by default: a non-allowlisted name resolves to a local
# dead-end sink (closes DNS-label exfil; the attempt still shows up for `sluice learn`).
# =1 restores forward-all resolution - weakens the guarantee.
SLUICE_DNS_OPEN=""

# Opt-in DNS query audit: =1 logs every query so the receipt surfaces DNS volume + tunnel patterns
# (many unique labels under one parent). SLUICE_DNS_TUNNEL_THRESHOLD (default 500) trips the flag.
SLUICE_DNS_AUDIT=""
SLUICE_DNS_TUNNEL_THRESHOLD=""

# DoH/DoT resolvers are blocked even when allowlisted (a DNS-over-HTTPS tunnel bypasses the
# SNI filter). =1 permits them.
SLUICE_ALLOW_DOH=""

# An allowlisted host an attacker can also WRITE to (S3, gists, pastebins, LLM APIs) can leak
# data even though it's allowlisted - sluice warns at session start. =1 acknowledges +
# silences it; SLUICE_STRICT_LAUNDERING=1 refuses to run instead.
SLUICE_LAUNDERING_OK=""
SLUICE_STRICT_LAUNDERING=""

# Egress volume budget (bytes SENT OUT this run). Over it, `sluice egress` exits non-zero
# (gate CI) and the run's receipt warns. Empty = off. DETECTIVE (reports after the fact).
SLUICE_EGRESS_MAX_BYTES=""

# Per-host detective budget: "host=bytes .wildcard=bytes ..." - a tighter laundering bound than the
# whole-box cap. Over any host's cap, `sluice egress` exits non-zero. e.g. ".s3.amazonaws.com=1048576"
SLUICE_EGRESS_HOST_BUDGETS=""

# PREVENTIVE per-boot egress ceiling: an in-box xt_quota DROP on all proxied egress (stops bytes
# mid-flight). Numeric, >= 1 MiB (1048576); counts wire bytes; needs xt_quota (fails closed). Empty = off.
SLUICE_EGRESS_HARD_CAP_BYTES=""

# --- hardening (opt-in; off by default) -----------------------------------------

# Extra seccomp filter: "hardened" (denylist, strict superset of the engine default),
# "browser" (hardened minus the calls browser engines need), "audit" (log-only).
# Unset = the engine's default profile.
SLUICE_SECCOMP=""

# Immutable rootfs (=1): tmpfs the ephemeral system paths; /etc/squid + /home/sluice become
# writable anon volumes pre-populated from the image.
SLUICE_READONLY_ROOT=""

# Protected workspace ("overlay"): host repo mounted READ-ONLY, the box edits a throwaway
# copy - review with `sluice diff`, write back with `sluice apply`.
SLUICE_WORKSPACE=""

# In-repo secret masking: space-separated project-root-relative globs, shadowed from the box
# at launch (the path exists; the contents are unreadable). Expanded when the container
# starts - a file created later is NOT masked. The agents/ presets default to ".env*".
# e.g. ".env* *.pem service-account*.json"
SLUICE_MASK=""

# Process cap (a runaway agent or build can't fork-bomb the host). Default 4096.
SLUICE_PIDS_LIMIT=""

# RAM cap; unset = no cap. e.g. "4g"
SLUICE_MEMORY=""

# --- serving --------------------------------------------------------------------

# TCP ports to publish to the host (bound to 127.0.0.1 -> reach via localhost only).
# The app MUST bind 0.0.0.0 inside the box for forwarded traffic to reach it.
SLUICE_PORTS=""

# --- run ------------------------------------------------------------------------

# The command run by a bare `sluice` - one shell string, run as the sluice user in the
# project dir. Defaults to an interactive bash. e.g. "npm run dev -- --host 0.0.0.0"
SLUICE_RUN_CMD="bash"

# --- optional: credentials / extra wiring (host -> container) --------------------

# Names of host env vars to forward into each session (values come from your shell or the
# prelaunch hook below, never baked). e.g. "GH_TOKEN API_KEY"
SLUICE_ENV=""

# Extra bind mounts, newline-separated "host:container[:ro]". e.g.
#   SLUICE_MOUNTS="$HOME/.config/gh:/home/sluice/.config/gh:ro
#   $HOME/.cache/app:/home/sluice/.cache/app"
SLUICE_MOUNTS=""

# Home-relative dirs to PERSIST across container recreation, from a per-project host store
# (~/.local/state/sluice/<name>) - agent sessions/history/auth survive runs. Dirs only,
# relative only; never a dir holding baked binaries (.npm-global, or .local for some agents).
# e.g. ".claude"  or  ".myagent .config/myagent"
SLUICE_STATE_DIRS=""

# Project-relative dirs to OVERLAY with a per-box volume: the box keeps its own contents
# (e.g. Linux-built node_modules) while the host's stay untouched. Starts EMPTY on first run;
# persists across recreation; removed by `sluice rm`/`prune`. e.g. "node_modules .venv"
SLUICE_OVERLAY_DIRS=""

# Name of a shell function defined in THIS file, run on the host before EVERY session (warm or
# cold box) - mint/stage short-lived credentials, then expose them via SLUICE_MOUNTS or
# SLUICE_ENV (read at exec time, so each session gets the freshly-minted value). Keep it
# idempotent and fast. e.g.
#   stage_creds() { umask 077; gcloud auth print-access-token > "$HOME/.cache/app/token"; }
#   SLUICE_PRELAUNCH="stage_creds"
SLUICE_PRELAUNCH=""
