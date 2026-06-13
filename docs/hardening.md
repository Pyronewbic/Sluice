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

<p align="center"><img src="../assets/overlay-demo.gif" width="720" alt="with SLUICE_WORKSPACE=overlay the box edits a throwaway copy: on the host notes.txt still reads 'original' and created.txt does not exist; sluice diff shows the box's changes (notes.txt modified, created.txt added); sluice apply prompts [y/N] and on 'y' writes them back - applied 1 added, 1 modified, 0 deleted"></p>

## `SLUICE_MASK`: in-repo secret masking

Protects against: the agent reading secrets that live inside the repo - the project mount is
otherwise all-or-nothing ([what it defends against](../THREAT_MODEL.md#what-it-defends-against-today)).

```bash
SLUICE_MASK=".env* secrets packages/*/.env"   # space-separated project-relative globs
```

At launch each current match is shadowed - an empty read-only bind for a file, a tmpfs for a
directory. The box sees the path exists but cannot read the contents. `sluice doctor` shows what
is masked now and warns about secret-looking files (`.env*`, `*.pem`, key JSON, SSH keys,
`*.p12`/`*.pfx`) that no pattern covers.

<p align="center"><img src="../assets/mask-demo.gif" width="680" alt="the host reads .env and sees the API key; inside the box the same cat prints nothing, and wc -c .env shows 0 bytes - the path exists, the contents are shadowed"></p>

Limits: matches are evaluated at launch, so a secret created mid-run is not masked; a slash-less
pattern matches root-level entries only (use `packages/*/.env` to reach deeper); symlink matches
are skipped (a mount over a link would shadow its target). More:
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

- `SLUICE_EGRESS_MAX_BYTES` - a budget on bytes sent to reached hosts. Over the cap,
  `sluice egress` exits non-zero (a CI gate) and `sluice learn` warns. Bounds laundering volume.
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
