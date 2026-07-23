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
- Multi-tenant / kernel-level isolation of deliberately hostile code (a non-goal;
  `SLUICE_RUNTIME=kata` covers the kernel-escape vector).
- Whatever a malicious `sluice.config.sh` / `SLUICE_PRELAUNCH` does - you author those.
- Behavior behind documented opt-out knobs (`SLUICE_ALLOW_IPS`, `SLUICE_DNS_OPEN`,
  `SLUICE_ALLOW_DOH`, `learn --audit`): setting an open-egress knob and observing open
  egress is working as documented, not a vulnerability.

## Supported versions

Security fixes land on the latest minor release line only; older releases are not patched.
Pin a commit or tag for reproducibility.

## Verifying a release

Release tarballs are signed with [cosign](https://github.com/sigstore/cosign) keyless (Sigstore
OIDC, no long-lived key). From a release's assets:

```sh
# integrity, then authenticity
sha256sum -c SHA256SUMS
cosign verify-blob sluice-<version>.tar.gz \
  --bundle sluice-<version>.tar.gz.cosign.bundle \
  --certificate-identity-regexp='^https://github\.com/Pyronewbic/Sluice/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com
```

The tarball is reproducible **at the tar layer** - compare that, not the `.tar.gz`. The gzip wrapper is
not reproducible across implementations: DEFLATE output differs (GNU gzip on the release runner vs Apple
gzip on macOS), so the compressed sha only matches if you compress with the same one. The `git archive`
output underneath it matches given the same git version **and a default git config** - `tar.umask` and
an `export-ignore` attribute (`core.attributesFile`) each change the digest, so run it in a clean clone.

```sh
# needs a clone with tags (the tar is re-derived from the tag, not from the download)
gunzip -c sluice-<version>.tar.gz                              | sha256sum   # the published tree
git archive --format=tar --prefix=sluice-<version>/ v<version> | sha256sum   # must match
```

`SHA256SUMS` covers the `.tar.gz` (that is what cosign signs); the command above is the separate check
that those bytes were built from this tag. On a host without `sha256sum` (older macOS), use
`shasum -a 256` - and note Alpine and `*-slim` images have the reverse, `sha256sum` but no `shasum`.

The opt-in GHCR base image (`SLUICE_BASE_IMAGE`) is signed the same way; `sluice` verifies it
at build time, soft by default or enforced with `SLUICE_REQUIRE_SIGNED=1`. To verify it yourself:

```sh
cosign verify ghcr.io/pyronewbic/sluice-base:latest \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github\.com/Pyronewbic/Sluice/\.github/workflows/publish-base\.yml@(refs/tags/v|refs/heads/main$)'
```

The same flags with `cosign verify-attestation --type cyclonedx` check the image's attached
SBOM attestation. Details: [docs/supply-chain.md](docs/supply-chain.md).
