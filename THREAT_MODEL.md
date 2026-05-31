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
  no Docker socket, no Docker-in-Docker.
- **Supply-chain fetch vs. runtime** -> deps are pulled at build (pre-firewall); the
  *running* container is locked to the allowlist.
- **Tampered sandbox core** -> the generic core (proxy, firewall, entrypoint, non-root user)
  can be pulled as a **cosign-signed base image** from GHCR (opt-in via `SLUICE_BASE_IMAGE`);
  `sluice` verifies the keyless signature before building on it (`SLUICE_REQUIRE_SIGNED=1` to
  enforce). The image carries no private key (the splice cert is generated per-container).
  Your declared `SLUICE_EXTRA_PKGS` are your own layer on top - audit them as any dependency.

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
   to guard. (squid runs as its own uid; only that uid is granted direct egress, so app
   code can't reach the network except through it.)
5. **Destruction within the project dir.** It's mounted read-write by design; the sluice
   can corrupt/delete your working tree (git history on the host is your backstop).
6. **Whatever `SLUICE_PRELAUNCH` does.** It runs on the **host** and is fully trusted - a
   malicious config is out of scope (you author it).
7. **Host-side Claude/editor hooks, side channels, timing.** Not addressed.

## Residual risk, one line

Egress is **hostname-filtered** (squid splice) with IPv6 off and direct-IP blocked, so the
IP-rotation / direct-IP / DoH / v6 gaps are closed. The remaining sharp edge is
**allowed-host laundering**: because we splice (never decrypt), data hidden in a request to
an *allowed* host isn't inspected. Keep `SLUICE_ALLOW_DOMAINS`/`SLUICE_ALLOW_IPS` minimal and
never allow a host an attacker can also write to.
