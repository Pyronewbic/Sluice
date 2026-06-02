# Security policy

Sluice is a security tool - its job is to contain untrusted code. If you find a way to
**escape the sandbox** or **defeat the egress firewall**, please report it privately.

## Reporting a vulnerability

- Preferred: open a **private** GitHub Security Advisory ->
  <https://github.com/Pyronewbic/Sluice/security/advisories/new>
- Or email <kan.nam.dev@gmail.com>.

Include a description, the affected version/commit, and a reproduction. Please don't open a
public issue for a vulnerability.

## Disclosure

We aim to acknowledge a report within a few days and give an initial assessment within about a
week, then coordinate a fix and a public advisory with you. Please allow a reasonable window -
up to **90 days** - to ship a fix before public disclosure; we'll credit you in the advisory
unless you'd prefer to stay anonymous.

## Safe harbor

We support good-faith security research. If you make a genuine effort to follow this policy -
stay in scope, avoid privacy violations and service disruption, and report privately - we will
not pursue or support legal action against you for that research.

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

## Verifying a release

Release tarballs are signed with [cosign](https://github.com/sigstore/cosign) keyless (Sigstore
OIDC, no long-lived key). From a release's assets:

```sh
sha256sum -c SHA256SUMS                          # integrity
cosign verify-blob sluice-<version>.tar.gz \     # authenticity
  --bundle sluice-<version>.tar.gz.cosign.bundle \
  --certificate-identity-regexp='^https://github.com/Pyronewbic/Sluice/' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com
```

The tarball is reproducible: `git archive --format=tar --prefix=sluice-<version>/ v<version> |
gzip -n9` regenerates the same bytes, so the sha is independently checkable. The opt-in GHCR base
image (`SLUICE_BASE_IMAGE`) is signed the same way; `sluice` verifies it at build time, soft by
default or enforced with `SLUICE_REQUIRE_SIGNED=1`.
