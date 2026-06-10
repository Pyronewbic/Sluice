# core/ - the sandbox image

The box every project runs in. A two-stage `Dockerfile`: **`base`** (the generic, cosign-signed core)
and **`project`** (per-project tooling layered on top). `bin/sluice` builds this with the project's
`sluice.config.sh`; the build context is `core/` plus that config. The security *rationale* lives in [THREAT_MODEL.md](../THREAT_MODEL.md) -
this file is the implementation map.

| file | role |
|---|---|
| `Dockerfile` | `base` (Wolfi + shell + the firewall stack + non-root `sluice` uid 1000, **no sudo**, no baked key) and `project` (FROM the base; `SLUICE_EXTRA_PKGS` / `SLUICE_EXTRA_NPM` / `SLUICE_SETUP_ROOT_CMDS` / `SLUICE_SETUP_CMDS` / `SLUICE_PREFETCH_*` layers) |
| `entrypoint.sh` | PID 1: runs as root to bring up DNS + the firewall, then idles; sessions `exec` in as the `sluice` user |
| `init-firewall.sh` | iptables: default-DROP egress, route the app's 80/443 through the in-box squid, allow only the squid uid straight out |
| `squid.conf` | the egress proxy: **splice** allowed hosts by TLS-SNI (never decrypt), deny everything else. The static file stays splice-only; `entrypoint.sh` patches in the `SLUICE_BUMP_DOMAINS` decrypt + URL-filter rules at runtime |
| `doh-endpoints.txt` | known DNS-over-HTTPS/TLS resolvers, refused even when allowlisted (anti-exfil-tunnel) |
| `dns-allow.sh` | writes dnsmasq's per-domain forwarders from the squid allowlist, so name resolution is **scoped to the allowlist** (no DNS-label exfil); runs at boot + on `sluice learn` reload |
| `seccomp.json` | the `SLUICE_SECCOMP=hardened` profile - a syscall denylist that is a strict superset of the engine default |
| `seccomp-browser.json` | the `SLUICE_SECCOMP=browser` variant - hardened minus the userns/mount calls a Chromium/Playwright sandbox needs (`=audit` is generated from `seccomp.json` at run time) |
| `smoke-test.sh` | the base-image smoke (run by `sluice smoke`) |

**Runtime flow:** `entrypoint.sh` (root) -> dnsmasq up (resolution scoped to the allowlist via
`dns-allow.sh`) -> squid up -> `init-firewall.sh` (iptables) -> drop to uid 1000 -> your
`SLUICE_RUN_CMD`. All egress is hostname-filtered through squid; nothing reaches the network except
via the allowlist. The baked `base` invariants (no sudo, uid 1000, firewall packages, no key) are
asserted by `tests/structure.yaml` (container-structure-test) - the publish gate runs it before
pushing; locally, `make structure`.
