# Gallery

Drop-in `sluice.config.sh` presets. Copy one into a project, run `sluice` - and it's
non-root, sees only that directory, and can only reach the hosts the preset allows.

Four demos live here, each self-contained (no repo of your own needed) - the "shows" column says which slice of sluice it demonstrates.

| preset | shows | copy & run |
|---|---|---|
| [firewall](firewall.config.sh) | the **egress firewall as a security control** - a fetch to an allowlisted host succeeds, an exfil attempt to a non-allowlisted host (and a raw IP) is **blocked**. Runs to completion, no server. | `mkdir d && cp examples/firewall.config.sh d/sluice.config.sh && cd d && sluice` |
| [jupyter](jupyter.config.sh) | **serving a web app** (Python/pip, JupyterLab on `:8888`) that needs **no** runtime egress at all - the firewall stays fully locked while it serves. | `mkdir d && cp examples/jupyter.config.sh d/sluice.config.sh && cd d && sluice` |
| [nix](nix.config.sh) | **Nix composed with sluice**: a reproducible, pinned toolchain fetched + baked at **build** time, then run with the firewall fully locked (no egress). Heavy (~1.5GB image). | `mkdir d && cp examples/nix.config.sh d/sluice.config.sh && cd d && sluice` |
| [database](database.config.sh) | the **`SLUICE_ALLOW_IPS` escape hatch** for a non-HTTP service: a reviewed fixed IP gets direct egress on any port (Postgres/Redis/MySQL), while every other IP stays default-DROP. Made visible with a raw TCP probe; no server. | `mkdir d && cp examples/database.config.sh d/sluice.config.sh && cd d && sluice` |

## Your own stack

No preset needed: `sluice init` detects 11 stacks (list in the [main README](../README.md#use);
anything else runs via the generic base) and scaffolds the config, then `sluice learn` (below)
fills the egress allowlist from what the app actually tried to reach.

## Stronger isolation (Linux)

Any preset above - or your own repo - runs under an own-kernel micro-VM with
`SLUICE_RUNTIME=kata`; setup and trade-offs in [docs/hardening.md](../docs/hardening.md).

## Discovering the allowlist with `sluice learn`

You don't have to guess the allowlist up front. Run the app under enforcement; on exit,
sluice prints an egress receipt of what the firewall passed and what it blocked:

```
[sluice] egress receipt: sluice-my-app   1 reached, 1 blocked, 13.1 KB
  reached   api.github.com               3 req   11.9 KB
  blocked   raw.githubusercontent.com    2 req   not allowlisted (sluice learn)
```

Then, with the box still running, `sluice learn` reviews the last run's blocked hosts:

```
$ sluice learn
[sluice] blocked during the last run - allow which? ('s' leaves a host blocked)

  raw.githubusercontent.com      2 req    1.2 KB   [a]llow / [s]kip / [d]omain(.githubusercontent.com) / [q]uit? a

[sluice] allowing: raw.githubusercontent.com
[sluice] wrote /home/you/my-app/sluice.config.sh
[sluice] reloaded the running box (squid reconfigure) - live now, no rebuild.
```

Picks are written to the config **and** hot-loaded into the running box - no rebuild.
`[d]omain` allows the whole `.parent` wildcard, and when 2+ blocked hosts share a parent,
learn offers the collapse up front. Flags:

- `--all` widens the scope from the last run to everything since the box booted.
- `--print` emits the merged allowlist (existing + blocked) to stdout - for review or CI.
- `--apply` allows every blocked host with no prompts - also the non-tty path.

That loop relies on the app *continuing* past a block so the proxy logs every host it wants.
If your command is a trusted fetcher that **aborts on the first blocked host**, `sluice learn
--audit` runs it once with egress open to all HTTP/HTTPS hosts in a throwaway,
credential-stripped container (`SLUICE_ENV`, prelaunch, and persisted auth stripped), then
offers the same per-host review over everything it reached - a loudly-warned,
trusted-code-only escape hatch (see [THREAT_MODEL.md](../THREAT_MODEL.md)).

While the box is running, `sluice doctor` shows the same last-run blocked list.

## Coding agents

`sluice agent claude` drops a sandboxed coding agent into the repo - presets, auth
forwarding, and the YOLO rationale are in [docs/agents.md](../docs/agents.md).
