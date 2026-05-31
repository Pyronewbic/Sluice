# Gallery

Drop-in `sluice.config.sh` presets. Copy one into a project, run `sluice` - and it's
non-root, sees only that directory, and can only reach the hosts the preset allows.

Supported runtimes (Node, Python, Deno, Ruby, Rust, Go) are listed in the
[main README](../README.md#use). Below: copy-paste presets, plus one runnable project per runtime.

## Self-contained demos (a real app, no repo of your own needed)

| preset | what it shows | copy & run |
|---|---|---|
| [strudel](strudel.config.sh) | a live-coding music REPL served on `:4321`; the sample-host egress gotcha | `mkdir d && cp examples/strudel.config.sh d/sluice.config.sh && cd d && sluice` |
| [jupyter](jupyter.config.sh) | JupyterLab (Python) on `:8888`; a stack that needs **no** runtime egress | `mkdir d && cp examples/jupyter.config.sh d/sluice.config.sh && cd d && sluice` |

## Runtime examples (one runnable project per toolchain)

Minimal "serve something" apps, one per toolchain `sluice init` supports. Each is a real
project (app + a `sluice init`-generated config); `cd` in and run `sluice` to build and serve
it through the sandbox, with its one dependency fetched through the egress proxy. These double
as the nightly build-smoke fixtures ([`test/verify-runtimes.sh`](../test/verify-runtimes.sh)).

| example | toolchain | serves on |
|---|---|---|
| [deno](deno/) | `deno task` + a `jsr:` import | `:8000` |
| [ruby](ruby/) | Sinatra + Puma (bundler, native ext) | `:4567` |
| [rust](rust/) | `cargo run` + a crate | `:8080` |
| [go](go/) | `go run` + a module | `:8080` |
| [bun](bun/) | `bun install` + `Bun.serve` | `:3000` |
| [poetry](poetry/) | `poetry` + FastAPI | `:8000` |
| [uv](uv/) | `uv` + FastAPI | `:8000` |

```bash
cd examples/deno && sluice          # build + serve; then in another shell: curl localhost:8000
```

## Stack starters (drop into YOUR repo)

| preset | for | copy |
|---|---|---|
| [vite](vite.config.sh) | a Vite app (React/Vue/Svelte) dev server on `:5173` | `cp examples/vite.config.sh sluice.config.sh` |
| [nextjs](nextjs.config.sh) | a Next.js app on `:3000` | `cp examples/nextjs.config.sh sluice.config.sh` |
| [fastapi](fastapi.config.sh) | a FastAPI/uvicorn Python API on `:8000` | `cp examples/fastapi.config.sh sluice.config.sh` |

Don't see your stack? `sluice init` scaffolds a config by detecting your manifests, and
`sluice learn` fills the egress allowlist from what the app actually tried to reach.

## Coding agents

See [`../agents/`](../agents/) - `sluice agent <name>` for
**claude, codex, gemini, aider, cursor, opencode, amp**.
