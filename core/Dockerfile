# syntax=docker/dockerfile:1
# sluice sandbox image: `base` (generic core, published + cosign-signed to GHCR) and `project`
# (per-project tooling on top). SLUICE_BASE_IMAGE builds the project FROM the signed base, not local core.

# BASE_IMAGE: the project stage's FROM; SLUICE_BASE_IMAGE points it at a published sluice-base ref.
ARG BASE_IMAGE=base
# WOLFI_BASE: the base stage's FROM; SLUICE_PIN=1 swaps in the sluice.pin @sha256 digest for a replay.
ARG WOLFI_BASE=cgr.dev/chainguard/wolfi-base

# ===== base: generic sluice core (published + cosign-signed) =====
FROM ${WOLFI_BASE} AS base

# OCI provenance: links the GHCR package to the repo; revision is CI-stamped (empty on local builds).
ARG VCS_REF=""
LABEL org.opencontainers.image.source="https://github.com/Pyronewbic/Sluice" \
      org.opencontainers.image.revision="${VCS_REF}"

# Full Wolfi OS repo so SLUICE_EXTRA_PKGS can pull anything Wolfi ships. Signing key is vendored +
# sha256-pinned (test/verify-ci-supplychain-unit.bats), never fetched: a rotated key fails apk closed.
COPY wolfi-signing.rsa.pub /etc/apk/keys/wolfi-signing.rsa.pub
RUN grep -qxF "https://packages.wolfi.dev/os" /etc/apk/repositories \
    || echo "https://packages.wolfi.dev/os" >> /etc/apk/repositories

RUN apk add --no-cache \
      bash coreutils diffutils ca-certificates-bundle curl git less vim procps shadow \
      iptables bind-tools jq gh squid dnsmasq openssl \
      nodejs-24 npm

# Non-root sluice user (uid 1000; wolfi-base ships none). The /home/node symlink keeps older
# SLUICE_MOUNTS targets working.
RUN groupadd -g 1000 sluice \
    && useradd -u 1000 -g sluice -d /home/sluice -m -s /bin/bash sluice \
    && ln -s /home/sluice /home/node

# User-writable npm prefix. APPEND to PATH, never prepend: the dir is uid-1000-owned, so a root-context
# exec must resolve /usr/bin first or a planted ~/.npm-global/bin/tail runs as root (_root_exec in
# src/10-egress-helpers.sh also passes a clean PATH; belt + braces).
ENV NPM_CONFIG_PREFIX=/home/sluice/.npm-global
ENV PATH=${PATH}:/home/sluice/.npm-global/bin

# squid's own uid (the only one with direct egress) + its dirs. Splice cert is minted at RUNTIME
# (entrypoint.sh) so the base carries no key - it splices, never forges.
RUN { getent group squid  >/dev/null 2>&1 || groupadd -r squid; } \
    && { getent passwd squid >/dev/null 2>&1 || useradd -r -g squid -d /var/cache/squid -s /bin/false squid; } \
    && mkdir -p /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid \
    && chown -R squid:squid /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid \
    && apk del shadow
COPY squid.conf /etc/squid.conf
COPY doh-endpoints.txt /etc/squid/doh-endpoints.txt

# No in-box sudo (neither a setuid binary nor a NOPASSWD path): the entrypoint and the `sluice learn`
# reload re-enter as root via the host engine, so uid 1000 has no route to root.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY smoke-test.sh    /usr/local/bin/smoke-test.sh
COPY dns-allow.sh     /usr/local/bin/sluice-dns-allow
COPY replay.sh        /usr/local/bin/sluice-replay
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/smoke-test.sh /usr/local/bin/sluice-dns-allow /usr/local/bin/sluice-replay

# Defense in depth: strip setuid/setgid from every base binary (shadow's passwd/chsh set is gone with
# the package above; other packages could still ship bits). The structure test asserts none remain.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod -s {} + 2>/dev/null || true

# Starts as root (entrypoint configures iptables, then idles); sessions exec in as sluice.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ===== project: this project's tooling, layered on the base =====
# FROM the local `base` by default, or the published signed base when BASE_IMAGE is set.
FROM ${BASE_IMAGE} AS project

# Per-project config (0644: the sluice user sources it). mkdir first: Docker 29.5.x's COPY --chmod also
# 0644s the auto-created parent, blocking non-root traversal - pre-creating keeps /usr/local/share 0755.
RUN mkdir -p /usr/local/share
COPY --chmod=0644 sluice.config.sh /usr/local/share/sluice.config.sh

# SLUICE_EXTRA_PKGS: the project's declared Wolfi packages, its own layer on the base.
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_EXTRA_PKGS:-}" ]; then apk add --no-cache ${SLUICE_EXTRA_PKGS}; fi

# SLUICE_EXTRA_NPM: pinned global npm packages, baked at build (to the root prefix).
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_EXTRA_NPM:-}" ]; then npm install -g ${SLUICE_EXTRA_NPM}; fi

# SLUICE_SETUP_ROOT_CMDS: build-time root setup, free egress; same trust as SLUICE_EXTRA_PKGS.
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_SETUP_ROOT_CMDS:-}" ]; then sh -eux -c "$SLUICE_SETUP_ROOT_CMDS"; fi

# SLUICE_SETUP_CMDS: build-time setup as sluice, free egress; the running container stays locked.
USER sluice
WORKDIR /home/sluice
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_SETUP_CMDS:-}" ]; then sh -eux -c "$SLUICE_SETUP_CMDS"; fi

# SLUICE_PREFETCH_CMD: fetch deps at build into a $HOME cache the runtime mount won't shadow, so the
# runtime allowlist can drop the package registry (F2). Runs as sluice, after SETUP_CMDS.
COPY --chown=sluice:sluice prefetch/ /home/sluice/.sluice-prefetch/
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_PREFETCH_CMD:-}" ]; then cd /home/sluice/.sluice-prefetch && sh -eux -c "$SLUICE_PREFETCH_CMD"; fi
USER root
WORKDIR /

# SLUICE_PIN=1: pinned replay converges package versions onto sluice.pin. Two guarded legs at the END
# so a normal build runs neither and keeps every earlier layer's cache; the pin crosses in as a build-arg.
ARG SLUICE_PIN=""
COPY pin/ /usr/local/share/sluice-pin/
RUN if [ "${SLUICE_PIN}" = 1 ]; then SLUICE_PIN=1 /usr/local/bin/sluice-replay root; fi
USER sluice
WORKDIR /home/sluice
RUN if [ "${SLUICE_PIN}" = 1 ]; then SLUICE_PIN=1 /usr/local/bin/sluice-replay user; fi
USER root
WORKDIR /

# Mirror the base setuid strip as the LAST root layer: SLUICE_EXTRA_PKGS (e.g. a re-added shadow),
# SLUICE_SETUP_ROOT_CMDS, or a pin replay can install setuid bits into this stage past the base sweep.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod -s {} + 2>/dev/null || true
