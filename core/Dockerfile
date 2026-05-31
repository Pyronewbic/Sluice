# sluice sandbox image. Wolfi-base (low-CVE, apk) + a shell, iptables + squid (egress
# firewall), and each project's declared tooling.
FROM cgr.dev/chainguard/wolfi-base

# Add the full Wolfi OS repo (+ signing key) so SLUICE_EXTRA_PKGS can pull anything Wolfi ships.
RUN apk add --no-cache curl \
    && curl -fsSL https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \
        -o /etc/apk/keys/wolfi-signing.rsa.pub \
    && echo "https://packages.wolfi.dev/os" >> /etc/apk/repositories

# Per-project config (sourced at build, boot, and on the host). 0644: the node user sources it.
COPY --chmod=0644 sluice.config.sh /usr/local/share/sluice.config.sh

# --- Base tooling: node/git/gh + the firewall (iptables, squid, openssl); + SLUICE_EXTRA_PKGS ---
RUN . /usr/local/share/sluice.config.sh && apk add --no-cache \
      bash coreutils ca-certificates-bundle curl git less vim procps sudo shadow \
      iptables bind-tools jq gh squid openssl \
      nodejs-24 npm \
      ${SLUICE_EXTRA_PKGS}

# --- Non-root `node` user (uid 1000; wolfi-base ships none) ---------------------
RUN groupadd -g 1000 node \
    && useradd -u 1000 -g node -d /home/node -m -s /bin/bash node

# --- SLUICE_EXTRA_NPM: pinned global npm packages, baked at build (to the root prefix) ---
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_EXTRA_NPM:-}" ]; then npm install -g ${SLUICE_EXTRA_NPM}; fi

# User-writable npm prefix so node can `npm i -g` at runtime.
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:${PATH}

# --- SLUICE_SETUP_CMDS: build-time setup as node (free egress; the running container is locked) ---
USER node
WORKDIR /home/node
RUN . /usr/local/share/sluice.config.sh \
    && if [ -n "${SLUICE_SETUP_CMDS:-}" ]; then sh -eux -c "$SLUICE_SETUP_CMDS"; fi
USER root
WORKDIR /

# --- squid: its own uid (the only one with direct egress) + a throwaway splice cert ---
# (we SPLICE, never forge, so the cert is never used to MITM.)
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

# Starts as root (entrypoint configures iptables, then idles); sessions exec in as node.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
