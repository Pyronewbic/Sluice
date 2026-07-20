# Running coding agents

`sluice agent <name>` drops you into a coding agent that's non-root, sees only this repo, and can
only reach its own model API - so running it in YOLO mode is defensible.

```bash
export ANTHROPIC_API_KEY=sk-ant-...     # forwarded into the sluice, never baked into the image
cd my-repo
sluice agent claude                     # Claude Code, --dangerously-skip-permissions, sandboxed
sluice agent claude -p "fix the test"   # one-shot: args after the name are forwarded to the agent
```

Run `sluice agent` with no name to list the presets, each with its auth var and whether it's set on
your host. Each preset is a normal `sluice.config.sh` (knob reference: [configuration.md](configuration.md));
the contract a preset must follow lives in [`agents/README.md`](../agents/README.md).

<p align="center"><img src="../assets/agent-demo.gif" width="680" alt="sluice agent lists nine sandboxed coding-agent presets with auth status read live from the host env (the claude row green, key set); inside the box 'cat .env' prints nothing because SLUICE_MASK shadows the secret; and the egress receipt shows api.anthropic.com reached in green and pypi.org blocked in red - one command, the agent caged"></p>

## The presets

| preset | auth env var (forwarded) | runs |
|---|---|---|
| `claude` | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` | `claude --dangerously-skip-permissions` |
| `codex` | `OPENAI_API_KEY` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `gemini` | `GEMINI_API_KEY` | `gemini --yolo` |
| `aider` | `OPENAI_API_KEY` and/or `ANTHROPIC_API_KEY` | `aider --yes-always` |
| `cursor` | `CURSOR_API_KEY` | `cursor-agent --force` |
| `opencode` | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | `opencode` (allow-all permission config baked at build) |
| `amp` | `AMP_API_KEY` | `amp --dangerously-allow-all` |
| `qwen` | `OPENAI_API_KEY` or `DASHSCOPE_API_KEY` (a DashScope key) | `qwen --yolo` against DashScope's OpenAI-compatible endpoint |
| `crush` | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | `crush --yolo` |
| `plandex` | Cloud email-pin sign-in (in-terminal), or BYO `OPENROUTER_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | `plandex --full` (Full Auto) |

Each preset file's header documents its host list and any quirks - read
[`agents/<name>.config.sh`](../agents/) for the one you're running.

## Auth

Export the key on your host before running. It's forwarded into the session via `SLUICE_ENV` - it is
never baked into the image, so the image stays shareable and `docker history` stays clean. Browser
OAuth flows cannot complete headless inside the box, so use an API key; for `claude`, a
`CLAUDE_CODE_OAUTH_TOKEN` works in place of an API key (see
[`agents/claude.config.sh`](../agents/claude.config.sh)).

## YOLO by default

Every preset runs the agent with its skip-approvals flag. That's the point: the sluice replaces the
per-action permission gate with a structural one - the agent can't escape the repo mount, can't run
as root, and can't reach hosts off the allowlist, so approving each shell command buys little.

Honest caveat: the sandbox bounds the blast radius but does not zero it. A YOLO agent can still
rewrite the mounted repo and spend any creds you forward, and the allowlist is host-granular - an
allowed API is also an exfiltration channel for whatever the box can read. Work on a committed
branch, and see the threat model for exactly what is and isn't contained:
[what it defends against](../THREAT_MODEL.md#what-it-defends-against-today),
[what it does not](../THREAT_MODEL.md#what-it-does-not-defend-against-be-explicit).

## One agent per repo, worktrees for parallel

The box is keyed to the project directory, so a repo holds one agent at a time. `sluice agent codex`
in a repo already scaffolded for claude reuses the claude config and says so (it matches the config's
first comment line against the presets). To run several agents in parallel, give each its own
checkout or a git worktree - sluice mounts the git common dir, so each worktree gets an isolated box:

```bash
git worktree add ../myrepo-codex
cd ../myrepo-codex && sluice agent codex   # isolated box + branch, separate from the claude one
```

## Sessions persist

Each preset sets `SLUICE_STATE_DIRS` for the agent's session/auth dir (e.g. `.claude`, `.codex`),
bind-mounted from a per-project host store under `~/.local/state/sluice/<slug>/` (respects
`XDG_STATE_HOME`). So
`sluice agent claude` resumes where you left off and survives a rebuild, a `sluice stop`, or a
reboot. `sluice doctor` shows what's persisted.

## In-repo secrets are masked

Every preset sets `SLUICE_MASK=".env*"`, so the agent can't read in-repo env files - they're
shadowed, not deleted, and the host copies are untouched. Set `SLUICE_MASK=""` in your project's
config to disable, or widen the globs ([configuration.md](configuration.md) has the semantics and
the caveats).

## Stack registries are unioned at scaffold time

The preset files are tool-only: model API and auth hosts, nothing else. When `sluice agent <name>`
first scaffolds your `sluice.config.sh`, it sniffs the project's manifest (package.json, pyproject,
Gemfile, Cargo.toml, go.mod, ...) and appends that stack's package-registry hosts to the allowlist,
marked `# from stack detection: <stack>` - so the agent's first `pip install` or `npm install`
doesn't trip the firewall. An existing config is never edited.

## When the agent hits a blocked host

The post-run egress receipt lists every blocked host. Run `sluice learn` to review them
interactively and allowlist the ones you trust (`--print` to preview, `--apply` to take all);
it persists the choice to your config and hot-reloads the proxy, no rebuild. Telemetry hosts the
presets deliberately leave blocked will show up here - leaving them blocked is fine.
