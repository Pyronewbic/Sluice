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

## What it defends against (today)

- **Secret exfiltration to arbitrary endpoints** -> default-DROP egress, enforced by an
  in-sluice **hostname-filtering proxy** (squid): all HTTP/HTTPS is redirected through it and
  allowed by **Host / TLS-SNI** (spliced, never decrypted), so the decision is by *domain*
  and survives IP rotation. Only the base hosts + `SLUICE_ALLOW_DOMAINS` are reachable; the
  boot self-test fails closed if a denied host or a direct-IP connection is reachable.
- **IP-literal / DoH / IPv6 bypasses** -> a direct-IP HTTPS connection has no SNI ->
  terminated; DNS is restricted to the configured resolver; IPv6 is disabled entirely (we
  proxy v4 only, so a dual-stack app can't slip out over v6).
- **Reading/altering the rest of your machine** -> only the project dir (and its git
  common dir, for worktrees) is mounted. Nothing else is visible.
- **Host privilege escalation** -> runs non-root (uid 1000), only `NET_ADMIN`/`NET_RAW`,
  no Docker socket, no Docker-in-Docker. (On SELinux-enforcing hosts the box runs
  `--security-opt label=disable` so it can read the project mount; that drops the SELinux layer, but
  the non-root / caps / firewall / dir-only guarantees above are unaffected.)
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
  committable inventory (every apk, npm, pip, gem, and go package with its version + digest) so you can
  review and drift-detect exactly what's installed (`sluice doctor` flags drift; `sluice lock --check`
  *enforces* it as a CI gate, and `sluice lock --sbom` emits a CycloneDX SBOM, with apk integrity
  hashes, for scanners). It's an audit/drift aid, not a reproducibility guarantee (Wolfi apk is a
  rolling repo). `sluice lock --scan` runs that SBOM through a **host** Grype/Trivy (never baked) and
  can gate on severity - advisory, though: a clean result means "no *known* CVE in the scanner's DB,"
  not proof of safety.

## What it does NOT defend against (be explicit)

1. **Kernel escape / multi-tenant adversary.** Shared kernel. Out of scope by design;
   stronger isolation is a roadmap opt-in, not a current claim.
2. **Exfil through an *allowed* host.** The allowlist is **host-granular**. If you allow
   a shared host - `raw.githubusercontent.com`, a cloud storage endpoint, an LLM API -
   data can be laundered through it. Keep the list minimal; never allow a host an
   attacker can also write to.
3. **Exfil through `SLUICE_ALLOW_IPS`.** Reviewed fixed IPs get *direct* egress on any port
   (the escape hatch for non-HTTP services like a database) - bypassing the proxy, so
   unfiltered by hostname. Keep the list minimal and specific.
4. **A squid vulnerability or a loose allowlist.** The egress policy now rests on squid +
   the allowlist file. A squid CVE or an over-broad `SLUICE_ALLOW_DOMAINS` is the trust anchor
   to guard - including the `.domain` wildcards `sluice learn` can write (a leading-dot entry
   matches *every* subdomain, so it's offered, never forced; prefer exact hosts when you can).
   `learn` applies your picks live (an in-place squid reload, no rebuild), but only ever **adds**
   the hosts you chose - it never weakens the non-HTTP/IPv6/non-root/direct-IP guarantees. (squid
   runs as its own uid; only that uid is granted direct egress, so app code can't reach the network
   except through it.)
5. **Destruction within the project dir.** It's mounted read-write by design; the sluice
   can corrupt/delete your working tree (git history on the host is your backstop).
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

Egress is **hostname-filtered** (squid splice) with IPv6 off and direct-IP blocked, so the
IP-rotation / direct-IP / DoH / v6 gaps are closed. The remaining sharp edge is
**allowed-host laundering**: because we splice (never decrypt), data hidden in a request to
an *allowed* host isn't inspected. Keep `SLUICE_ALLOW_DOMAINS`/`SLUICE_ALLOW_IPS` minimal and
never allow a host an attacker can also write to.
