# Configuration reference

Every user-facing knob, in one place. A project's config is `sluice.config.sh` at the
project root; copy [sluice.config.example.sh](../sluice.config.example.sh) to start, or let
`sluice init` scaffold one. Rationale for the guarantees lives in
[THREAT_MODEL.md](../THREAT_MODEL.md) - this page is semantics, defaults, and when an edit
takes effect.

## The config contract

`sluice.config.sh` is sourced as plain POSIX sh by three components: the image build
(`/bin/sh`, in the Dockerfile RUN steps), the container boot scripts
(`core/entrypoint.sh` and `core/init-firewall.sh`, bash, from the copy baked at
`/usr/local/share/sluice.config.sh`), and `bin/sluice` on the host (bash). Keep it
sh-safe: space- or newline-separated strings, no bash arrays. Every knob is optional - a
minimal config is just a `SLUICE_RUN_CMD`.

## When an edit applies

- **rebuild** (the default for every config knob except one): the config feeds a hash baked
  into the image as a label (`config_hash` in [src/10-egress-helpers.sh](../src/README.md)),
  so the next `sluice` run rebuilds the image (layer-cached) and recreates the container.
  No manual step; host-read knobs like the laundering gate take effect the same run.
- **no rebuild** - `SLUICE_ALLOW_DOMAINS` only: excluded from the hash and handed to the box
  at container start, so allowlist edits never rebuild. `sluice learn` applies picks live to
  a running box; a hand edit lands at the next container start (`sluice rebuild`/`stop`).
- **env** - read from your shell per invocation, never from the config.

## Identity

- `SLUICE_NAME` - image/container name (`sluice-<name>`, lowercased). Default: the project
  directory's basename. Set it when two checkouts share a basename.
- `SLUICE_DESC` - one-line description shown in `sluice ls` and `sluice doctor`.

## Build-time (baked into the image)

- `SLUICE_EXTRA_PKGS` - extra Wolfi apk packages on top of the base (bash/node/npm/git/gh/
  curl/jq/vim + the firewall stack). Space-separated, installed unpinned (rolling repo);
  `sluice lock` records resolved versions ([supply-chain](supply-chain.md)).
- `SLUICE_EXTRA_NPM` - global npm packages baked at build; pin versions
  (`@some/mcp-server@1.2.3`).
- `SLUICE_SETUP_ROOT_CMDS` - one shell string run as root at build, before
  `SLUICE_SETUP_CMDS` - provisioning outside the home dir (`/opt`, a `/nix` the `sluice`
  user then owns). Same trust as `SLUICE_EXTRA_PKGS`.
- `SLUICE_SETUP_CMDS` - one shell string run at build as the non-root `sluice` user in
  `/home/sluice`: clones, dependency installs, codegen. Build egress is unrestricted; the
  running container stays locked to the allowlist.
- `SLUICE_PREFETCH_FILES`, `SLUICE_PREFETCH_CMD` - dependency prefetch: the listed
  project-relative manifests are copied into the build, then the command fetches deps into a
  `$HOME` cache the runtime mount won't shadow - so the runtime allowlist can drop the
  package registry. Manifest contents are hashed too: a lockfile change triggers the rebuild.
  `sluice init` sets these for go/rust/ruby/pip when a lockfile is present.
- `SLUICE_BASE_IMAGE` - build the project layer FROM a published ref instead of rebuilding
  the core locally; the published sluice base is cosign-verified when cosign is installed.
  Default: build from `core/`. See [supply-chain](supply-chain.md).
- `SLUICE_REQUIRE_SIGNED` - `=1` makes a missing/failed base signature or SBOM attestation
  fatal (default: warn and continue).

## Egress (runtime; default-DROP otherwise)

What the filter guarantees - and does not - is in
[THREAT_MODEL.md](../THREAT_MODEL.md#what-it-defends-against-today).

- `SLUICE_ALLOW_DOMAINS` - HTTP/HTTPS hosts the box may reach, on top of the always-on base
  (npm/yarn registries + GitHub hosts). Matched by Host/TLS-SNI through the in-box proxy; a
  leading dot matches subdomains (`.example.com`). The one **no rebuild** knob - `sluice
  learn` edits it live.
- `SLUICE_ALLOW_IPS` - fixed IPs/CIDRs for non-HTTP services, direct egress bypassing the
  proxy. Scope each entry: `ip:port[/proto]` (a bare ip/cidr opens every port).
- `SLUICE_POLICY_URL` - URL (http/https/file) returning a plain-text allowlist (one host per
  line, `#` comments), fetched on the host at container start and merged additively.
  Host-trusted: keep it a URL you control.
- `SLUICE_BUMP_DOMAINS`, `SLUICE_BUMP_URLS` - scoped TLS interception, opt-in and off by
  default: listed hosts are decrypted so squid can filter by `SLUICE_BUMP_URLS` url_regex;
  every other host is spliced, never decrypted. Weigh it first:
  [THREAT_MODEL.md](../THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default).
- `SLUICE_DNS_OPEN` - default DNS is scoped to the allowlist (non-allowlisted names resolve
  to a local dead-end sink, closing DNS-label exfil). `=1` restores forward-all resolution -
  weakens the guarantee.
- `SLUICE_ALLOW_DOH` - DoH/DoT resolver hosts are filtered out of the allowlist even when
  listed (a DNS-over-HTTPS tunnel bypasses the SNI filter). `=1` permits them. Read at
  container boot from the baked config, so set it here, not as an env var.
- `SLUICE_LAUNDERING_OK`, `SLUICE_STRICT_LAUNDERING` - session-start gate for allowlisted
  hosts an attacker can also write to (object stores, gists, LLM APIs): sluice warns; `_OK=1`
  acknowledges and silences, `_STRICT=1` refuses to run instead. Why this leak exists:
  [THREAT_MODEL.md](../THREAT_MODEL.md#what-it-does-not-defend-against-be-explicit).
- `SLUICE_EGRESS_MAX_BYTES` - budget on bytes sent out per run: over it, `sluice egress`
  exits non-zero (CI gate) and the run's receipt warns. Empty = off.

## Hardening (opt-in; off by default)

How-to and trade-offs: [hardening](hardening.md).

- `SLUICE_SECCOMP` - `hardened` (denylist, strict superset of the engine default),
  `browser` (hardened minus the calls browser engines need for their own sandbox), or
  `audit` (log-only). Unset = the engine's default profile.
- `SLUICE_READONLY_ROOT` - `=1` makes the rootfs immutable: tmpfs the ephemeral system
  paths; `/etc/squid` + `/home/sluice` become writable anonymous volumes.
- `SLUICE_WORKSPACE` - `overlay` mounts the host repo read-only and gives the box a
  throwaway copy; review with `sluice diff`, write back with `sluice apply`. `apply` refuses
  non-interactively unless `SLUICE_YES=1`; `SLUICE_APPLY_NO_DELETE=1` (env) writes adds and
  modifications but never deletes a host file.
- `SLUICE_MASK` - in-repo secret masking: space-separated project-relative globs shadowed at
  launch (empty read-only bind over a file, empty tmpfs over a dir). Patterns expand when
  the container starts - a file created later is not masked. The agent presets default to
  `.env*`; `sluice doctor` warns on secret-looking files left unmasked.
- `SLUICE_PIDS_LIMIT` - process cap (fork-bomb guard). Default 4096.
- `SLUICE_MEMORY` - RAM cap, e.g. `4g`. Unset = no cap.
  Both caps also work as plain environment variables (read by the launcher at start).

## Serving and run

- `SLUICE_PORTS` - TCP ports published to the host, bound to `127.0.0.1` only; the firewall
  opens a matching inbound rule. The app must bind `0.0.0.0` inside the box.
- `SLUICE_RUN_CMD` - what a bare `sluice` runs: one shell string, as the `sluice` user in
  the project dir. Default: an interactive bash.

## Wiring (host to container)

- `SLUICE_ENV` - names of host env vars forwarded into each session. Values are read from
  your shell at exec time, never baked into the image.
- `SLUICE_MOUNTS` - extra bind mounts, newline-separated `host:container[:ro]`.
- `SLUICE_STATE_DIRS` - home-relative dirs persisted across container recreation, backed by
  a per-project host store (`$XDG_STATE_HOME/sluice/<name>`). The
  [agent presets](agents.md) use this for sessions/auth. Dirs only, relative paths only;
  never a dir holding baked binaries (`.npm-global`).
- `SLUICE_OVERLAY_DIRS` - project-relative dirs overlaid with a per-box named volume, so the
  box keeps its own contents (e.g. Linux-built `node_modules`) while the host's stay
  untouched. Starts empty; persists across recreation; removed by `sluice rm`/`prune`.
- `SLUICE_PRELAUNCH` - name of a shell function defined in this config, run on the host
  before launch - mint/stage short-lived credentials, then expose them via `SLUICE_MOUNTS`
  or `SLUICE_ENV`.

## Environment-only knobs

Set these in your shell, not the config:

- `SLUICE_ENGINE` - container engine. Default: `docker`, else `podman`.
- `SLUICE_RUNTIME` - `kata` runs the box under nerdctl/containerd with Kata Containers (an
  own-kernel micro-VM; Linux only, needs the Kata shim). The image still builds with
  `SLUICE_ENGINE` and is loaded across.
- `SLUICE_YES` - `=1` auto-confirms non-interactive prompts (`prune`, the zero-config first
  run, `apply`).
- `SLUICE_NO_BANNER` - non-empty suppresses the startup banner.
- `SLUICE_NO_UPDATE_CHECK` - non-empty skips the `sluice version` update notice.
- `NO_COLOR` - non-empty disables colored output.
