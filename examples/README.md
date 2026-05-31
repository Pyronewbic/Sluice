# Gallery

Drop-in `sluice.config.sh` presets. Copy one into a project, run `sluice` - and it's
non-root, sees only that directory, and can only reach the hosts the preset allows.

Each demo below is self-contained (no repo of your own needed) and shows a **different**
slice of what sluice does - read the "shows" column to pick one.

| preset | shows | copy & run |
|---|---|---|
| [firewall](firewall.config.sh) | the **egress firewall as a security control** - a fetch to an allowlisted host succeeds, an exfil attempt to a non-allowlisted host (and a raw IP) is **blocked**; surfaced by `sluice doctor`. Runs to completion, no server. | `mkdir d && cp examples/firewall.config.sh d/sluice.config.sh && cd d && sluice` |
| [strudel](strudel.config.sh) | **serving a web app** (a live-coding music REPL on `:4321`) + the runtime egress allow-gotcha: a host the app needs at play time must be on the allowlist. | `mkdir d && cp examples/strudel.config.sh d/sluice.config.sh && cd d && sluice` |
| [jupyter](jupyter.config.sh) | a **different stack** (Python/pip, JupyterLab on `:8888`) that needs **no** runtime egress at all - the contrast to strudel. | `mkdir d && cp examples/jupyter.config.sh d/sluice.config.sh && cd d && sluice` |
| [nix](nix.config.sh) | **Nix composed with sluice**: a reproducible, pinned toolchain fetched + baked at **build** time, then run at **runtime** with the firewall fully locked (no egress). Heavy (~1.5GB image). | `mkdir d && cp examples/nix.config.sh d/sluice.config.sh && cd d && sluice` |

## Your own stack

No preset needed: run **`sluice init`** in your repo - it detects the stack (Node/Vite/Next,
Python/FastAPI, Deno, Ruby/Rails, Rust, Go) and scaffolds the config, then **`sluice learn`**
fills the egress allowlist from what the app actually tried to reach. Any other language runs
too via `SLUICE_EXTRA_PKGS` + `SLUICE_RUN_CMD` (see the [main README](../README.md#use)).

## Coding agents - run any agent YOLO, safely

The wedge: one command drops you into a coding agent that's non-root, sees only this repo, and
can reach only its own model API - so running it with approvals off is defensible.

```bash
export ANTHROPIC_API_KEY=sk-ant-...   # forwarded into the box, never baked
cd my-repo && sluice agent claude     # Claude Code, --dangerously-skip-permissions, sandboxed
```

Presets ([`../agents/`](../agents/), run `sluice agent` to list): **claude, codex, gemini,
aider, cursor, opencode, amp** - each declares its tool, API hosts, and the auth env var to
forward. Verified end-to-end via [`../test/verify-agents.sh`](../test/verify-agents.sh)
(binary installs + runs, API hosts reachable, non-allowlisted hosts blocked, auth forwarded).
