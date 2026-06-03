# core/ - the sandbox image

The box every project runs in. A two-stage `Dockerfile`: **`base`** (the generic, cosign-signed core)
and **`project`** (per-project tooling layered on top via `SLUICE_EXTRA_PKGS` / `SLUICE_SETUP_CMDS` /
`SLUICE_PREFETCH_*`). `bin/sluice` builds this with the project's `sluice.config.sh`; the build context
is `core/` plus that config. The security *rationale* lives in [THREAT_MODEL.md](../THREAT_MODEL.md) -
this file is the implementation map.

| file | role |
|---|---|
| `Dockerfile` | `base` (Wolfi + shell + the firewall stack + non-root `sluice` uid 1000, **no sudo**, no baked key) and `project` (FROM the base; per-project pkgs / npm / setup / prefetch) |
| `entrypoint.sh` | PID 1: runs as root to bring up the firewall, then idles; sessions `exec` in as the `sluice` user |
| `init-firewall.sh` | iptables: default-DROP egress, route the app's 80/443 through the in-box squid, allow only the squid uid straight out |
| `squid.conf` | the egress proxy: **splice** allowed hosts by TLS-SNI (never decrypt), or decrypt + URL-filter the `SLUICE_BUMP_DOMAINS` set; deny everything else |
| `doh-endpoints.txt` | known DNS-over-HTTPS/TLS resolvers, refused even when allowlisted (anti-exfil-tunnel) |
| `seccomp.json` | the `SLUICE_SECCOMP=hardened` profile - a syscall denylist that is a strict superset of the engine default |
| `seccomp-browser.json` | the `SLUICE_SECCOMP=browser` variant - hardened minus the userns/mount calls a Chromium/Playwright sandbox needs (`=audit` is generated from `seccomp.json` at run time) |
| `smoke-test.sh` | the base-image smoke (run by `sluice smoke` and the publish gate) |

**Runtime flow:** `entrypoint.sh` (root) -> `init-firewall.sh` (iptables + squid up) -> drop to uid
1000 -> your `SLUICE_RUN_CMD`. All egress is hostname-filtered through squid; nothing reaches the
network except via the allowlist. The baked `base` invariants (no sudo, uid 1000, firewall packages,
no key) are asserted by `tests/structure.yaml` (container-structure-test).
