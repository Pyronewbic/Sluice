# Hardening (opt-in layers)

Every layer here is off by default and independent - enable only what your threat calls for.
This page owns the how-to; the guarantees live in the
[threat model](../THREAT_MODEL.md#what-it-defends-against-today). Knob reference: [configuration.md](configuration.md).

## `SLUICE_SECCOMP`: syscall filter

Protects against: kernel-surface exploitation from inside the box - namespace creation, tracing,
the mount API ([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).

```bash
SLUICE_SECCOMP=hardened   # enforce
SLUICE_SECCOMP=browser    # enforce, minus what a browser sandbox needs
SLUICE_SECCOMP=audit      # log-only, enforce nothing
```

- `hardened` ([core/seccomp.json](../core/seccomp.json)) - a denylist that is a strict superset of
  the engine's default deny set, so it is never weaker than the profile it replaces. On top of
  that default it blocks in-box namespace creation (`unshare`, `clone(CLONE_NEWUSER)`, `clone3`),
  tracing (`ptrace`, `bpf`, `perf_event_open`), key material, the mount API, modules, kexec/swap,
  and non-cap-gated exploitation primitives (`userfaultfd`, the ASLR-disable `personality` path).
- `browser` ([core/seccomp-browser.json](../core/seccomp-browser.json)) - `hardened` minus the
  namespace/mount calls a browser engine (Chromium/Playwright) needs for its own userns sandbox.
  Everything else stays blocked.
- `audit` - the hardened profile with every deny rewritten to `SCMP_ACT_LOG`: see what WOULD be
  blocked (kernel audit log) before flipping to `hardened`.

Cost: `hardened` breaks browser-engine sandboxes - use `browser` for those, or run the browser
`--no-sandbox` (the container is already the jail). Unset = the engine's own default profile.

## `SLUICE_READONLY_ROOT`: immutable rootfs

Protects against: in-box persistence and tampering outside the project mount
([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).

Set `SLUICE_READONLY_ROOT=1`. The rootfs becomes read-only; `/tmp`, `/run`, and squid's log/cache
dirs become tmpfs; `/etc/squid` and `/home/sluice` (baked content plus runtime writes) become
anonymous volumes pre-populated from the image. DNS still works: `resolv.conf` can't be rewritten,
so the launcher sets `--dns 127.0.0.1` and probes the real upstream from a throwaway run.

Cost: writes outside the project dir, `/home/sluice`, or a tmpfs fail; one extra run at start.

## `SLUICE_WORKSPACE=overlay`: protected workspace

Protects against: a misbehaving agent destroying the host repo
([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).

Set `SLUICE_WORKSPACE=overlay`. The host repo is mounted read-only at `/mnt/sluice-orig`; the box
works on a writable copy at the same project path, seeded at container start. Review and write
back from the host:

```bash
sluice diff    # unified diff: working copy vs the protected original (.git excluded)
sluice apply   # write adds/mods/deletes back to the host repo
```

`apply` confirms interactively and **refuses non-interactively** unless `SLUICE_YES=1` (it writes to
your repo, so it never applies unprompted). Deletions are computed against the repo state captured
when the box started, not the live mount, so a file you create on the host mid-session is never
mistaken for a box deletion. `SLUICE_APPLY_NO_DELETE=1` writes adds and modifications but leaves the
host files the box deleted in place. A write failure aborts loudly rather than reporting success.

After a session sluice prints the changeset counts as a nudge. Cost: the git common dir is not
mounted (an rw mount would bypass the protection), so a git worktree can't resolve refs in the
box; seeding a large repo costs startup time.

## `SLUICE_MASK`: in-repo secret masking

Protects against: the agent reading secrets that live inside the repo - the project mount is
otherwise all-or-nothing ([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).

```bash
SLUICE_MASK=".env* secrets packages/*/.env"   # space-separated project-relative globs
```

At launch each current match is shadowed - an empty read-only bind for a file, a tmpfs for a
directory. The box sees the path exists but cannot read the contents. `sluice doctor` shows what
is masked now and warns about secret-looking files (`.env*`, `*.pem`, key JSON, SSH keys,
`*.p12`/`*.pfx`) that no pattern covers. The README's [agent demo](../README.md) shows this in
motion - inside the box `cat .env` prints nothing and `wc -c .env` is 0 bytes.

Limits: matches are evaluated at launch, so a secret created mid-run is not masked; a slash-less
pattern matches root-level entries only (use `packages/*/.env` to reach deeper); a matched symlink
masks the file it resolves to, not the link itself - a target resolving outside the **project dir**,
or one that cannot be resolved, is left **unmasked**. Note a git worktree mounts the git common dir
too, and symlink resolution does not cover it: a matched link pointing into that dir stays readable
in the box, and `doctor` will not flag it. More:
[what it does not defend against](../THREAT_MODEL.md#what-it-does-not-defend-against-be-explicit).

## `SLUICE_OVERLAY_DIRS`: box-local dirs

Keeps platform-specific artifacts apart: the box gets its own contents for each listed dir
(e.g. Linux-built `node_modules`) while the host's stay untouched.

```bash
SLUICE_OVERLAY_DIRS="node_modules .venv"     # project-relative dirs
```

Each dir gets a per-box named volume that starts empty (install inside the box) and persists
across container recreation; `sluice rm` and `sluice prune` remove it with the box.

## Resource caps

Protects against: a runaway agent or build exhausting the host
([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).
`SLUICE_PIDS_LIMIT` caps box processes (default 4096, always on - fork bombs die in the box);
`SLUICE_MEMORY` (e.g. `4g`) caps RAM, unset by default.

## Egress tightening

The default posture is default-drop with an allowlist; these knobs gate or bound what an allowed
host can still carry ([residual risk](../THREAT_MODEL.md#residual-risk-one-line)).

<p align="center"><img src="../assets/hard-cap-demo.gif" width="720" alt="with SLUICE_EGRESS_HARD_CAP_BYTES=1258291 a warm GET returns http 200, proving httpbin.org is genuinely allowlisted; an upload to that same allowed host then puts 1556480 bytes on the wire before it dies (curl exit 28); re-running the warm GET that had just succeeded now times out with http 000, showing egress is dead box-wide rather than one flow being slow - which is what confirms the cap fired; the receipt closes at 1 reached, 0 blocked, 1.4 MB"></p>

- `SLUICE_EGRESS_MAX_BYTES` - a **detective** budget on bytes sent to reached hosts. Over the cap,
  `sluice egress` exits non-zero (a CI gate) and `sluice learn` warns. Bounds laundering volume.
- `SLUICE_EGRESS_HOST_BUDGETS` - a **detective** *per-host* budget (`host=bytes .wildcard=bytes`), a
  tighter laundering bound than the whole-box cap. Over any host's cap, `sluice egress` exits non-zero.
- `SLUICE_EGRESS_HARD_CAP_BYTES` - a **preventive** per-boot ceiling: an in-box `xt_quota` DROP on all
  proxied egress, so bytes are stopped mid-flight (even established flows hard-stop), not just gated
  after. Numeric, **>= 1 MiB**. Honest limits worth internalizing before you set a tight one: it counts
  **wire bytes** (headers, TLS overhead, and *download* ACKs debit it too), the window is **per-boot**
  (a long-lived box accumulates across runs), hitting it kills **all** proxied egress (including a
  `sluice learn` hot-reload target and the ephemeral `learn --audit` box, which can truncate the audit
  run), and it needs `xt_quota` - if the kernel lacks it the box **fails closed** (refuses to boot).
- `SLUICE_ALLOW_IPS_MAX_BYTES` - the same preventive `xt_quota` budget, shared across all
  `SLUICE_ALLOW_IPS` direct egress (the escape hatch that bypasses the proxy). The direct-IP lane is
  metered per entry in the receipt (`allow_ips[]`); the firewall-drop total (`fw_dropped`) and the
  denied raw-IP request count (`denied_ip_requests`) are recorded for every box, lane configured or not.
- `SLUICE_BUMP_METHODS` / `SLUICE_BUMP_MAX_BODY` - upload controls on the decrypted (bumped) lane: an
  HTTP-method allowlist and a request-body cap (413 over it). No-op without `SLUICE_BUMP_DOMAINS`.
  `SLUICE_BUMP_MAX_BODY` is **per request**, not cumulative - pair it with a byte budget.
- `SLUICE_DNS_AUDIT=1` - **detects** DNS-tunnel patterns (many unique labels under one allowlisted
  parent) in the receipt. Detection, not prevention; `SLUICE_DNS_TUNNEL_THRESHOLD` (default 500) trips
  the flag.
- Laundering gate - at session start sluice warns when the allowlist contains shared hosts an
  attacker could also write to. `SLUICE_LAUNDERING_OK=1` acknowledges and silences;
  `SLUICE_STRICT_LAUNDERING=1` refuses to run instead.
- `SLUICE_DNS_OPEN` - leave unset: resolution is scoped to the allowlist, and a non-allowlisted
  name resolves to a dead sink that never reaches an upstream resolver (no DNS-label exfil).
  `=1` restores forward-all resolution (weaker).
- `SLUICE_ALLOW_DOH` - leave unset: DoH/DoT resolvers are dropped from the allowlist even when
  listed, because DNS-over-HTTPS to an allowed resolver bypasses the SNI filter. `=1` permits
  them (weaker).

## `SLUICE_RUNTIME=kata`: own-kernel runtime

Protects against: shared-kernel escape - the box runs as a micro-VM with its own kernel
([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).

```bash
SLUICE_RUNTIME=kata
```

Linux only. Needs containerd + nerdctl + Kata Containers (the `containerd-shim-kata-v2` shim);
Kata wants a rootful containerd. Your engine (docker or podman) still builds the image; sluice
loads it into containerd and runs the box under nerdctl with the Kata runtime - same firewall,
non-root user, and mount semantics. Cost: slower boot than a container, plus an image copy into
containerd's store after every rebuild.

## Rootless podman: repo ownership

The box runs as uid 1000 (`sluice`) and chowns the mounted repo to it so the sandboxed user can write.
Under rootless podman your host user maps to container-root, so sluice adds `--userns=keep-id:uid=1000`
to map your host user straight onto the sluice uid: the repo stays writable in the box **and** owned by
you on the host. This needs **podman >= 4.3**. On older podman sluice warns and falls back to the plain
chown, which re-owns the repo to a subuid; restore your write access with
`podman unshare chown -R 0:0 "$PWD"`.

## Rootless podman: other caveats

Rootless podman can't do a few things docker does; `sluice doctor` flags the ones your config triggers.

- **Resource caps may not apply.** `--pids-limit` / `SLUICE_MEMORY` enforce only when the host has
  cgroups v2 with systemd delegation. Without it podman silently ignores them, so the fork-bomb / RAM
  cap is off. Enable [rootless cgroup delegation](https://rootlesscontaine.rs/getting-started/common/cgroup2/)
  or run under docker if you rely on those caps.
- **Host ports < 1024 won't bind.** `SLUICE_PORTS` entries below 1024 can't be published rootless
  (`sysctl net.ipv4.ip_unprivileged_port_start=<n>` on the host, or map to a high port).
- **Netfilter modules must be loaded.** The in-box firewall uses `xt_owner`, `xt_state`, and
  `nat`/`REDIRECT`; a rootless user namespace can't autoload kernel modules, so on a podman-only host
  where they aren't already loaded the box fails to boot. Preload them (`modprobe`) once on the host.
