# syntax=docker/dockerfile:1
# sluice sandbox image, two stages: `base` (generic core - Wolfi + shell + squid/dnsmasq firewall +
# non-root user; published + cosign-signed to GHCR) and `project` (per-project tooling on top). Local
# build does both from scratch; SLUICE_BASE_IMAGE -> --build-arg BASE_IMAGE builds FROM the signed base.

# BASE_IMAGE (global, used in the project FROM) defaults to the local `base` stage; override it
# with a published ghcr.io/.../sluice-base:<ver> ref (via SLUICE_BASE_IMAGE) to skip rebuilding.
ARG BASE_IMAGE=base
# WOLFI_BASE (the local `base` stage's FROM) defaults to the rolling wolfi ref; SLUICE_PIN=1 overrides it
# with the @sha256 digest recorded in sluice.pin, so a replay build starts from the exact base image.
ARG WOLFI_BASE=cgr.dev/chainguard/wolfi-base

# ============ base: generic sluice core (published + cosign-signed) =====================
FROM ${WOLFI_BASE} AS base

# Add the full Wolfi OS repo so SLUICE_EXTRA_PKGS can pull anything Wolfi ships. The signing key is
# VENDORED (sha256 pinned in test/verify-ci-supplychain-unit.bats), never fetched at build; if upstream
# rotates it, apk fails closed until the copy is refreshed (re-fetch from packages.wolfi.dev AND the
# wolfi-base image, require byte-identity, update file + test constant in one commit).
COPY wolfi-signing.rsa.pub /etc/apk/keys/wolfi-signing.rsa.pub
RUN grep -qxF "https://packages.wolfi.dev/os" /etc/apk/repositories \
    || echo "https://packages.wolfi.dev/os" >> /etc/apk/repositories

# --- Base tooling: node/git/gh + the firewall (iptables, squid, dnsmasq, openssl) ---------
RUN apk add --no-cache \
      bash coreutils diffutils ca-certificates-bundle curl git less vim procps shadow \
      iptables bind-tools jq gh squid dnsmasq openssl \
      nodejs-24 npm

# --- Non-root `sluice` user (uid 1000; wolfi-base ships none). The /home/node symlink
#     keeps older configs whose SLUICE_MOUNTS target /home/node working. ----------------
RUN groupadd -g 1000 sluice \
    && useradd -u 1000 -g sluice -d /home/sluice -m -s /bin/bash sluice \
    && ln -s /home/sluice /home/node

# User-writable npm prefix so node can `npm i -g` at runtime. APPEND it to PATH (not prepend): this dir
# is chowned to uid 1000, and a root-context maintenance exec (receipt/learn/apply) must resolve system
# tools (tail/wc/diff/...) from /usr/bin FIRST, so a uid-1000-planted ~/.npm-global/bin/tail can't run
# as root. Root execs also pass an explicit clean PATH (src/10-egress-helpers.sh _root_exec); belt + braces.
ENV NPM_CONFIG_PREFIX=/home/sluice/.npm-global
ENV PATH=${PATH}:/home/sluice/.npm-global/bin

# --- squid: its own uid (the only one with direct egress) + its dirs --------------------
# The splice cert is generated at RUNTIME (entrypoint.sh) so the base carries no key; we splice
# (never forge), so it is never presented - it only lets squid bind the ssl-bump port.
RUN { getent group squid  >/dev/null 2>&1 || groupadd -r squid; } \
    && { getent passwd squid >/dev/null 2>&1 || useradd -r -g squid -d /var/cache/squid -s /bin/false squid; } \
    && mkdir -p /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid \
    && chown -R squid:squid /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid
COPY squid.conf /etc/squid.conf
COPY doh-endpoints.txt /etc/squid/doh-endpoints.txt

# The entrypoint already runs as root and invokes init-firewall.sh directly; the live `sluice learn`
# reload re-enters as root via the host engine. So the box needs no in-box sudo - we ship neither the
# setuid binary nor a NOPASSWD path, leaving uid 1000 with no route to root.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY smoke-test.sh    /usr/local/bin/smoke-test.sh
COPY dns-allow.sh     /usr/local/bin/sluice-dns-allow
COPY replay.sh        /usr/local/bin/sluice-replay
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/smoke-test.sh /usr/local/bin/sluice-dns-allow /usr/local/bin/sluice-replay

# Defense in depth: strip setuid/setgid from EVERY base binary. shadow ships chfn/chsh/passwd/gpasswd/
# chage/expiry setuid-root, but the box runs as root at boot and execs sessions as uid 1000, which
# never needs them. So uid 1000 has no setuid-root primitive even independent of no-new-privileges.
# (shadow stays - useradd needs it at build - only its setuid bits go.) The structure test asserts none remain.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod -s {} + 2>/dev/null || true

# Starts as root (entrypoint configures iptables, then idles); sessions exec in as sluice.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ============ project: this project's tooling, layered on the base ======================
# FROM the local `base` stage by default, or the published signed base when BASE_IMAGE is set.
FROM ${BASE_IMAGE} AS project

# Per-project config (sourced at build, boot, and on the host). 0644: the sluice user sources it.
# mkdir first: Docker 29.5.x's COPY --chmod also chmods the auto-created parent (0644 -> no execute,
# so the non-root user can't traverse /usr/local/share to read the config). Pre-creating it stays 0755.
RUN mkdir -p /usr/local/share
COPY --chmod=0644 sluice.config.sh /usr/local/share/sluice.config.sh

# --- SLUICE_EXTRA_PKGS: the project's declared Wolfi packages (its own layer on the base) ---
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_EXTRA_PKGS:-}" ]; then apk add --no-cache ${SLUICE_EXTRA_PKGS}; fi

# --- SLUICE_EXTRA_NPM: pinned global npm packages, baked at build (to the root prefix) ---
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_EXTRA_NPM:-}" ]; then npm install -g ${SLUICE_EXTRA_NPM}; fi

# --- SLUICE_SETUP_ROOT_CMDS: build-time setup as ROOT (free egress; same trust as SLUICE_EXTRA_PKGS).
#     For provisioning outside $HOME - e.g. a /nix store the sluice user can then own. ----------
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_SETUP_ROOT_CMDS:-}" ]; then sh -eux -c "$SLUICE_SETUP_ROOT_CMDS"; fi

# --- SLUICE_SETUP_CMDS: build-time setup as sluice (free egress; the running container is locked) ---
USER sluice
WORKDIR /home/sluice
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_SETUP_CMDS:-}" ]; then sh -eux -c "$SLUICE_SETUP_CMDS"; fi

# --- SLUICE_PREFETCH_CMD: fetch the project's deps at build (free egress) into a $HOME cache the
#     runtime mount won't shadow, so the runtime allowlist can drop the package registry (F2). The
#     manifests come from build()'s ./prefetch; runs as sluice, after SETUP_CMDS (so e.g. bundler exists). ---
COPY --chown=sluice:sluice prefetch/ /home/sluice/.sluice-prefetch/
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_PREFETCH_CMD:-}" ]; then cd /home/sluice/.sluice-prefetch && sh -eux -c "$SLUICE_PREFETCH_CMD"; fi
USER root
WORKDIR /

# --- SLUICE_PIN=1: pinned replay. Converge the installed package versions onto sluice.pin (copied into
#     the build context by build() only in pin mode; else it's a lone .keep). Two guarded legs at the END
#     so a NORMAL build (SLUICE_PIN unset) runs neither and keeps every earlier layer's cache. The pin is
#     the build-arg, never the baked config, so an env-only SLUICE_PIN=1 crosses into the build. ---
ARG SLUICE_PIN=""
COPY pin/ /usr/local/share/sluice-pin/
RUN if [ "${SLUICE_PIN}" = 1 ]; then SLUICE_PIN=1 /usr/local/bin/sluice-replay root; fi
USER sluice
WORKDIR /home/sluice
RUN if [ "${SLUICE_PIN}" = 1 ]; then SLUICE_PIN=1 /usr/local/bin/sluice-replay user; fi
USER root
WORKDIR /
