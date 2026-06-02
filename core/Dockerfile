# syntax=docker/dockerfile:1
# sluice sandbox image, two stages: `base` (generic core - Wolfi + shell + squid/dnsmasq firewall +
# non-root user; published + cosign-signed to GHCR) and `project` (per-project tooling on top). Local
# build does both from scratch; SLUICE_BASE_IMAGE -> --build-arg BASE_IMAGE builds FROM the signed base.

# BASE_IMAGE (global, used in the project FROM) defaults to the local `base` stage; override it
# with a published ghcr.io/.../sluice-base:<ver> ref (via SLUICE_BASE_IMAGE) to skip rebuilding.
ARG BASE_IMAGE=base

# ============ base: generic sluice core (published + cosign-signed) =====================
FROM cgr.dev/chainguard/wolfi-base AS base

# Add the full Wolfi OS repo (+ signing key) so SLUICE_EXTRA_PKGS can pull anything Wolfi ships.
RUN apk add --no-cache curl \
    && curl -fsSL https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \
        -o /etc/apk/keys/wolfi-signing.rsa.pub \
    && echo "https://packages.wolfi.dev/os" >> /etc/apk/repositories

# --- Base tooling: node/git/gh + the firewall (iptables, squid, dnsmasq, openssl) ---------
RUN apk add --no-cache \
      bash coreutils ca-certificates-bundle curl git less vim procps shadow \
      iptables bind-tools jq gh squid dnsmasq openssl \
      nodejs-24 npm

# --- Non-root `sluice` user (uid 1000; wolfi-base ships none). The /home/node symlink
#     keeps older configs whose SLUICE_MOUNTS target /home/node working. ----------------
RUN groupadd -g 1000 sluice \
    && useradd -u 1000 -g sluice -d /home/sluice -m -s /bin/bash sluice \
    && ln -s /home/sluice /home/node

# User-writable npm prefix so node can `npm i -g` at runtime.
ENV NPM_CONFIG_PREFIX=/home/sluice/.npm-global
ENV PATH=/home/sluice/.npm-global/bin:${PATH}

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
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/smoke-test.sh

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
USER root
WORKDIR /
