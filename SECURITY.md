# Security policy

Sluice is a security tool - its job is to contain untrusted code. If you find a way to
**escape the sandbox** or **defeat the egress firewall**, please report it privately.

## Reporting a vulnerability

- Preferred: open a **private** GitHub Security Advisory ->
  <https://github.com/Pyronewbic/Sluice/security/advisories/new>
- Or email <kan.nam.dev@gmail.com>.

Include a description, the affected version/commit, and a reproduction. Please don't open a
public issue for a vulnerability. We aim to acknowledge within a few days.

## Scope

**In scope** (the guarantees Sluice makes - see [THREAT_MODEL.md](THREAT_MODEL.md)):
- Egress that bypasses the hostname allowlist (exfiltration to a non-allowlisted host).
- Reading or writing the host filesystem outside the mounted project directory.
- Privilege escalation to root on the host, or container escape.

**Out of scope** (documented non-goals - see [THREAT_MODEL.md](THREAT_MODEL.md)):
- Exfiltration *through an allowed host* - the allowlist is host-granular by design.
- Multi-tenant / kernel-level isolation of deliberately hostile code (use a microVM).
- Whatever a malicious `sluice.config.sh` / `SLUICE_PRELAUNCH` does - you author those.

## Supported versions

Pre-1.0: only the latest `main` is supported. Pin a commit or tag for reproducibility.
