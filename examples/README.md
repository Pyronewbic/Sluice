# Gallery

Drop-in `sluice.config.sh` presets. Copy one into a project, run `sluice` - and it's
non-root, sees only that directory, and can only reach the hosts the preset allows.

Each demo is self-contained (no repo of your own needed) - the "covers" column says which
everyday task it stands in for. Bread-and-butter first; skim down for the security mechanics.

| preset | covers | copy & run |
|---|---|---|
| [webapp](webapp.config.sh) | **the everyday loop** - serve the app you have, watch its one API call get blocked, then `sluice learn --apply` to allow exactly that host (live, no rebuild). A Node service on `:3000`. | `mkdir wa && cp examples/webapp.config.sh wa/sluice.config.sh && cd wa && sluice` |
| [overlay](overlay.config.sh) | **let a tool edit a copy, then review** - host repo stays read-only; the box writes to a throwaway overlay you inspect with `sluice diff` and commit with `sluice apply`. The human gate for a YOLO agent. | `mkdir ov && cp examples/overlay.config.sh ov/sluice.config.sh && cd ov && echo original > notes.txt && sluice` |
| sandbox a coding agent | **not a config** - `sluice agent claude` (or codex/gemini/...) drops a sandboxed agent into the repo. Presets, auth forwarding, and the YOLO rationale: [docs/agents.md](../docs/agents.md). | `sluice agent claude` |
| [firewall](firewall.config.sh) | **prove the boundary** - a fetch to an allowlisted host succeeds, an exfil attempt to a non-allowlisted host (and a raw IP) is **blocked**. Runs to completion, no server. | `mkdir d && cp examples/firewall.config.sh d/sluice.config.sh && cd d && sluice` |
| [database](database.config.sh) | the **`SLUICE_ALLOW_IPS` escape hatch** for a non-HTTP service: a reviewed fixed IP gets direct egress on any port (Postgres/Redis/MySQL), while every other IP stays default-DROP. Raw TCP probe; no server. | `mkdir d && cp examples/database.config.sh d/sluice.config.sh && cd d && sluice` |
| [jupyter](jupyter.config.sh) | **serve with zero runtime egress** (Python/pip, JupyterLab on `:8888`) - the firewall stays fully locked while it serves. | `mkdir d && cp examples/jupyter.config.sh d/sluice.config.sh && cd d && sluice` |
| [nix](nix.config.sh) | **a pinned toolchain** fetched + baked at **build** time, then run with the firewall fully locked (no egress). Niche, heavy (~1.5GB image). | `mkdir d && cp examples/nix.config.sh d/sluice.config.sh && cd d && sluice` |

The [overlay](overlay.config.sh) preset is the human gate in motion - the box edits a
throwaway copy, you review with `sluice diff`, and only `sluice apply` (with a `[y/N]`
confirm) touches your real files:

<p align="center"><img src="../assets/overlay-demo.gif" width="720" alt="with SLUICE_WORKSPACE=overlay the box edits a throwaway copy: on the host notes.txt still reads 'original' and created.txt does not exist; sluice diff shows the box's changes (notes.txt modified, created.txt added); sluice apply prompts [y/N] and on 'y' writes them back - applied 1 added, 1 modified, 0 deleted"></p>

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

The [webapp](webapp.config.sh) preset above runs exactly this loop end to end.
While the box is running, `sluice doctor` shows the same last-run blocked list.
