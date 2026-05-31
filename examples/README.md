# Gallery

Drop-in `sluice.config.sh` presets. Copy one into a project, run `sluice` — and it's
non-root, sees only that directory, and can only reach the hosts the preset allows.

## Self-contained demos (a real app, no repo of your own needed)

| preset | what it shows | copy & run |
|---|---|---|
| [strudel](strudel.config.sh) | a live-coding music REPL served on `:4321`; the sample-host egress gotcha | `mkdir d && cp examples/strudel.config.sh d/sluice.config.sh && cd d && sluice` |
| [jupyter](jupyter.config.sh) | JupyterLab (Python) on `:8888`; a stack that needs **no** runtime egress | `mkdir d && cp examples/jupyter.config.sh d/sluice.config.sh && cd d && sluice` |

## Stack starters (drop into YOUR repo)

| preset | for | copy |
|---|---|---|
| [vite](vite.config.sh) | a Vite app (React/Vue/Svelte) dev server on `:5173` | `cp examples/vite.config.sh sluice.config.sh` |
| [nextjs](nextjs.config.sh) | a Next.js app on `:3000` | `cp examples/nextjs.config.sh sluice.config.sh` |
| [fastapi](fastapi.config.sh) | a FastAPI/uvicorn Python API on `:8000` | `cp examples/fastapi.config.sh sluice.config.sh` |

Don't see your stack? `sluice init` scaffolds a config by detecting your manifests, and
`sluice learn` fills the egress allowlist from what the app actually tried to reach.

## Coding agents

See [`../agents/`](../agents/) — `sluice agent <name>` for
**claude · codex · gemini · aider · cursor · opencode · amp**.
