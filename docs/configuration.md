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
  user then owns). Same trust as `SLUICE_EXTRA_PKGS`. The base deletes the `shadow`
  package after its own build-time use; a setup needing `useradd`/`groupadd` re-adds it
  with `SLUICE_EXTRA_PKGS="shadow"`.
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
- `SLUICE_PIN` - `=1` builds from `sluice.pin` (written by `sluice lock --pin`): the recorded base
  digest + exact package versions, replayed and then **verified** against `sluice.lock` (the build
  fails closed on any drift). Requires a `sluice.pin`; `sluice update` re-resolves and re-pins. See
  [supply-chain](supply-chain.md#sluice-lock-pin-a-replay-manifest).

## Egress (runtime; default-DROP otherwise)

What the filter guarantees - and does not - is in
[THREAT_MODEL.md](../THREAT_MODEL.md#what-it-defends-against-today).

- `SLUICE_ALLOW_DOMAINS` - HTTP/HTTPS hosts the box may reach, on top of the always-on base
  (npm/yarn registries + GitHub hosts). Matched by Host/TLS-SNI through the in-box proxy; a
  leading dot matches subdomains (`.example.com`). The one **no rebuild** knob - `sluice
  learn` edits it live.
- `SLUICE_ALLOW_IPS` - fixed IPs/CIDRs for non-HTTP services, direct egress bypassing the
  proxy. **IPv4-only.** Scope each entry: `ip:port[/proto]`. Refused: a catch-all (`0.0.0.0/0`, any
  `/0` or `0.0.0.0/N`), a CIDR broader than the `/8` floor (e.g. `0.0.0.0/1 128.0.0.0/1`), an
  IPv6 literal, and a **hostname** (fixed IPs only - a host would resolve to the in-box DNS sink, so
  put it in `SLUICE_ALLOW_DOMAINS`). A colon-less entry (no port) is allowed but warns, since it opens
  every port to that host. The in-box firewall enforces the same floor as a second layer.
- `SLUICE_POLICY_URL` - URL (http/https/file) to a central egress policy, applied host-side as the
  final gate. A bare host list is back-compat (additive); v2 directives can also `deny` hosts and
  refuse to run on a crossed ceiling (`forbid <knob>`, `deny-ip` (bidirectional CIDR overlap),
  `max-allow-ips`, `max-allow-ips-bytes`, `max-hard-cap-bytes`, `forbid-laundering`, `strict-unknown`,
  `require-signed-base`). Also read from `~/.config/sluice/policy.conf` and a root-owned
  `/etc/sluice/policy.conf` (the org's managed policy). Full reference: [policy.md](policy.md).
- `SLUICE_BUMP_DOMAINS`, `SLUICE_BUMP_URLS` - scoped TLS interception, opt-in and off by
  default: listed hosts are decrypted so squid can filter by `SLUICE_BUMP_URLS` url_regex;
  every other host is spliced, never decrypted. Weigh it first:
  [THREAT_MODEL.md](../THREAT_MODEL.md#scoped-tls-interception-opt-in-off-by-default).
- `SLUICE_BUMP_METHODS`, `SLUICE_BUMP_MAX_BODY` - upload controls on the **decrypted** (bumped) lane;
  no-ops without `SLUICE_BUMP_DOMAINS` (`sluice doctor` warns). `SLUICE_BUMP_METHODS` is a space-
  separated HTTP-method allowlist (`GET HEAD OPTIONS`) - a bumped-host request using any other method
  is denied. `SLUICE_BUMP_MAX_BODY` caps request-body bytes (a global directive, so it also bounds
  plain-HTTP bodies; spliced tunnels are opaque and unaffected); over it, squid returns 413. Both are
  validated host-side (letters-only methods, numeric cap) and re-validated in-box. `SLUICE_BUMP_MAX_BODY`
  is **per request** - it bounds a single body, not cumulative exfil (pair it with a byte budget).
- `SLUICE_DNS_AUDIT`, `SLUICE_DNS_TUNNEL_THRESHOLD` - `SLUICE_DNS_AUDIT=1` logs every DNS query to a
  host-readable file so the receipt and `sluice egress --json` surface DNS volume and **tunnel
  patterns** (many unique labels under one parent = exfil-as-DNS-labels). `SLUICE_DNS_TUNNEL_THRESHOLD`
  (default 500) is the per-parent unique-name count that trips a flag. Detective only - resolution
  scoping is unchanged.
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
- `SLUICE_EGRESS_HOST_BUDGETS` - a **per-host** tx budget, a tighter laundering bound than the
  whole-box cap. Space-separated `host=bytes` tokens; a leading dot is a wildcard
  (`.s3.amazonaws.com=1048576` matches the host and its subdomains), exact beats wildcard, the
  longest wildcard wins. Over any single host's cap, `sluice egress` exits non-zero and the receipt
  warns. Unlike `SLUICE_EGRESS_MAX_BYTES` (silently ignored when malformed), a malformed token here
  **dies** (fail closed) - a silently-void security budget is worse than a stop.
- `SLUICE_EGRESS_FLAG_BYTES` - a **visibility aid**, not a bound: when a single reached host's bytes
  meet or exceed it, that host is tagged `(high volume)` and carries `"high_volume":true` - flagging a
  bulk transfer to an allowlisted host that would otherwise blend into a normal row. Counts bytes in
  **both** directions, so a large download trips it as readily as an upload. Tagged on the at-exit
  receipt and on `sluice egress`, in both their human and `--json` renders, and on the persisted record
  (`sluice egress --export`, and `last_receipt` in `sluice ls --json`). `sluice egress` reads the whole
  boot while the receipt is run-scoped, so the same threshold can flag on one and not the other. `0`
  disables the flag; a non-numeric value falls back to the default. It bounds nothing (the byte caps do
  that); default 1 GiB.

- `SLUICE_EGRESS_HARD_CAP_BYTES` - a **preventive** per-boot ceiling on all proxied egress, enforced
  in-box with an `xt_quota` iptables rule on squid's uid: once the quota is spent, egress is DROPped
  (even established flows hard-stop). Numeric, **>= 1 MiB** (boot probes + TLS handshakes consume the
  budget, so a smaller cap bricks the box at boot). Honest limits: the quota counts **wire bytes**
  (TCP/IP + TLS overhead, and download ACKs), so a tight cap is impractical for download-heavy
  sessions; the window is **per-boot**, so a long-lived box accumulates across runs; and hitting it
  kills *all* proxied egress (including a `sluice learn` hot-reload target and the ephemeral `learn
  --audit` box). It fails **closed** if the kernel lacks `xt_quota` (refuses to boot). An org can
  mandate a ceiling with the `max-hard-cap-bytes N` [policy](policy.md) directive.
- `SLUICE_ALLOW_IPS_MAX_BYTES` - a **preventive** shared byte budget across *all* `SLUICE_ALLOW_IPS`
  direct egress (the escape hatch that bypasses the proxy). Same `xt_quota` mechanism; over budget,
  direct-IP flows are severed. Numeric. Also needs `xt_quota` (fails closed).

The byte-denominated egress knobs, so they are not conflated:

| Knob | Kind | Scope | Measures |
|---|---|---|---|
| `SLUICE_EGRESS_MAX_BYTES` | detective (CI gate + warning) | whole box | total tx bytes |
| `SLUICE_EGRESS_HOST_BUDGETS` | detective (CI gate + warning) | per host | that host's tx bytes |
| `SLUICE_EGRESS_HARD_CAP_BYTES` | **preventive** (in-box DROP) | whole box, proxied | total wire bytes, per boot |
| `SLUICE_ALLOW_IPS_MAX_BYTES` | **preventive** (in-box DROP) | all direct-IP egress | wire bytes, per boot |

The detective knobs report and gate after the fact (`sluice egress` reads the boot-scoped proxy log);
the preventive knobs stop bytes mid-flight in the firewall but need `xt_quota` and count wire bytes.

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
- `SLUICE_ALLOW_HOME` - `=1` permits a project dir that is `$HOME`, `/`, or an ancestor of `$HOME`,
  which otherwise **refuses to run**. Mounting one of those would hand the box your whole home tree -
  `~/.ssh`, cloud credentials, every other project - so the refusal is the default and this is the
  deliberate override. See the mount-scope guarantee in the
  [threat model](../THREAT_MODEL.md#what-it-defends-against-today).
- `SLUICE_STATE_DIRS` - home-relative dirs persisted across container recreation, backed by
  a per-project host store (`$XDG_STATE_HOME/sluice/<name>`). The
  [agent presets](agents.md) use this for sessions/auth. Dirs only, relative paths only;
  never a dir holding baked binaries (`.npm-global`).
- `SLUICE_OVERLAY_DIRS` - project-relative dirs overlaid with a per-box named volume, so the
  box keeps its own contents (e.g. Linux-built `node_modules`) while the host's stay
  untouched. Starts empty; persists across recreation; removed by `sluice rm`/`prune`.
- `SLUICE_PRELAUNCH` - name of a shell function defined in this config, run on the host
  before **every session** (`sluice` / `run` / `shell`, warm or cold box) and before a
  `rebuild` recreates the container - mint/stage short-lived credentials, then expose them
  via `SLUICE_MOUNTS` or `SLUICE_ENV` (forwarded at exec time, so re-minted values reach
  each new session). Runs once per invocation; keep it idempotent and fast.

## Environment-only knobs

Set these in your shell, not the config:

- `SLUICE_ENGINE` - container engine. Default: `docker`, else `podman`.
- `SLUICE_RUNTIME` - `kata` runs the box under nerdctl/containerd with Kata Containers (an
  own-kernel micro-VM; Linux only, needs the Kata shim). The image still builds with
  `SLUICE_ENGINE` and is loaded across.
- `SLUICE_BUILD_RETRIES` - `=N` retries a failed image build N times (default 0), for a flaky
  registry or network in CI. A deterministic build error still fails after the retries.
- `SLUICE_RM_PURGE_STATE` - `=1` makes `sluice rm` also delete the box's persisted state dir
  (agent sessions/auth); by default `rm` keeps it. Best-effort on Linux (box-owned files may resist).
- `SLUICE_YES` - `=1` auto-confirms non-interactive prompts (`prune`, `apply`). The zero-config
  first run is the exception: non-interactively it always stops after scaffolding the config
  (review it, then run `sluice` again) - the detected run command executes against your mounted
  repo, so it never runs sight-unseen.
- `SLUICE_NO_BANNER` - non-empty suppresses the startup banner. The banner (stderr, TTY only)
  shows a live posture line at launch - engine, allowlist size, active hardening, whether secrets
  are masked - and turns yellow with `exfil risk` when an allowlisted host is a laundering/DoH
  channel. It degrades to one compact line on a narrow terminal.
- `SLUICE_NO_UPDATE_CHECK` - non-empty skips the `sluice version` update notice.
- `NO_COLOR` - non-empty disables colored output.
