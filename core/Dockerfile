# sluice — sandbox image for running untrusted code/deps behind an egress firewall.
# Wolfi-based (Chainguard's open-source undistro): low-CVE, daily-patched, apk.
# This is wolfi-base + apk (NOT distroless): the sluice needs a shell, iptables + squid
# for the egress firewall, and whatever dev tooling each project declares.
FROM cgr.dev/chainguard/wolfi-base

# wolfi-base's apk points only at the curated apk.cgr.dev/chainguard repo (a subset).
# Bootstrap curl (wolfi-base ships none), fetch the Wolfi OS signing key, and add the
# full open-source Wolfi OS repo so SLUICE_EXTRA_PKGS can pull anything Wolfi publishes.
# The build runs on the host, BEFORE the sluice firewall — network is unrestricted here.
RUN apk add --no-cache curl \
    && curl -fsSL https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \
        -o /etc/apk/keys/wolfi-signing.rsa.pub \
    && echo "https://packages.wolfi.dev/os" >> /etc/apk/repositories

# Per-project config. Also read at boot by init-firewall.sh (allowlist + published
# ports) and on the host by bin/sluice. COPY'd from the temp build context bin/sluice assembles.
# --chmod=0644: the build sources this as the non-root node user (BOX_SETUP_CMDS step),
# so it must stay world-readable even if the host file had restrictive perms.
COPY --chmod=0644 sluice.config.sh /usr/local/share/sluice.config.sh

# --- Base tooling (generic, any project) ---------------------------------------
# node/npm/git/gh/curl/jq + the firewall toolchain: iptables (v4+v6) and squid (the
# hostname-filtering egress proxy); openssl mints squid's splice cert. coreutils: GNU
# userland the scripts assume (`sleep infinity`; busybox lacks it). bind-tools: `dig`
# for diagnostics. Project tooling (e.g. terraform, a language runtime) → SLUICE_EXTRA_PKGS.
RUN . /usr/local/share/sluice.config.sh && apk add --no-cache \
      bash coreutils ca-certificates-bundle curl git less vim procps sudo shadow \
      iptables bind-tools jq gh squid openssl \
      nodejs-24 npm \
      ${SLUICE_EXTRA_PKGS}

# --- Non-root `node` user (uid 1000; wolfi-base ships none) ---------------------
RUN groupadd -g 1000 node \
    && useradd -u 1000 -g node -d /home/node -m -s /bin/bash node

# --- Project-specific global npm packages (e.g. pnpm, an MCP server) ------------
# Pinned in sluice.config.sh for supply-chain hygiene; baked at build (no runtime npx
# fetch). Installed to the ROOT prefix (before NPM_CONFIG_PREFIX is repointed below)
# so the bins are on PATH system-wide, including for the node user.
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_EXTRA_NPM:-}" ]; then npm install -g ${SLUICE_EXTRA_NPM}; fi

# User-writable npm prefix so the non-root node user can `npm i -g` at runtime
# (the build-time installs above went to the root-owned default prefix).
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:${PATH}

# --- Build-time project setup (clones, dependency installs) ---------------------
# Runs as the NON-ROOT node user in its home, so anything it produces (cloned repos,
# node_modules, framework caches) is node-owned and writable when the dev server runs.
# Runs on the host before the sluice firewall, so clones/downloads have free egress; the
# RUNNING container is still locked to the allowlist. System packages → SLUICE_EXTRA_PKGS.
USER node
WORKDIR /home/node
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_SETUP_CMDS:-}" ]; then sh -eux -c "$SLUICE_SETUP_CMDS"; fi
USER root
WORKDIR /

# --- egress filter (squid): user, runtime dirs, splice cert ---------------------
# squid runs as its own uid (the firewall's `--uid-owner squid` rule is the only uid
# allowed direct egress). Ensure the user + dirs exist and mint a throwaway self-signed
# cert for the ssl-bump parser — we only SPLICE (never forge), so it's never used to MITM.
RUN { getent group squid  >/dev/null 2>&1 || groupadd -r squid; } \
    && { getent passwd squid >/dev/null 2>&1 || useradd -r -g squid -d /var/cache/squid -s /bin/false squid; } \
    && mkdir -p /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/squid/ssl/squid-key.pem -out /etc/squid/ssl/squid-cert.pem \
        -subj "/CN=sluice-egress-filter" \
    && chmod 600 /etc/squid/ssl/squid-key.pem \
    && chown -R squid:squid /etc/squid/ssl /var/log/squid /var/cache/squid /run/squid
COPY squid.conf /etc/squid.conf

# Let the non-root node user (re)run the firewall script as root without a password.
RUN mkdir -p /etc/sudoers.d \
    && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/firewall \
    && chmod 0440 /etc/sudoers.d/firewall \
    && { grep -qs '^@includedir /etc/sudoers.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers; }

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY smoke-test.sh    /usr/local/bin/smoke-test.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/smoke-test.sh

# Container starts as root so the entrypoint can configure iptables, then idles.
# Interactive/run sessions are exec'd in as the non-root node user by bin/sluice.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
