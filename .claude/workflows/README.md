# Claude workflows

Multi-agent orchestration scripts for Claude Code (not GitHub Actions - those live in
`.github/workflows/`). Each `*.js` here fans work out across subagents.

Run one by asking Claude to "run the `review-launcher` workflow" or via `/review-launcher`.
Watch live progress with `/workflows`. Running a workflow spawns many agents and uses a lot
of tokens, so Claude only starts one when you explicitly ask.

| Workflow | What it does |
|----------|--------------|
| `review-launcher` | Reviews `src/*.sh` + the `core/` firewall stack across security / bash-3.2 / docker-vs-podman, adversarially verifies each finding. |
| `audit-egress` | Cross-checks every `agents/*.config.sh` preset's egress hosts against the allowlist + `THREAT_MODEL.md`, then adversarially verifies each finding against upstream before reporting it. |
| `triage-tests` | Runs the bats suites, clusters failures, root-causes each cluster in parallel. Pass `args.suite` to scope. |
| `release-audit` | Pre-tag sweep: drafts release notes from commits since the last tag, checks version refs / install + brew mechanics / supply-chain doc accuracy / CLI drift / ROADMAP state, verifies each finding. Output only. Pass `args.version` (and optionally `args.since`). |

Anatomy: a pure-literal `export const meta = {...}` (name, description, whenToUse, phases) then a body
using `agent()` (takes a structured-output `schema`; invocation `args` are in scope) / `parallel()` /
`pipeline()` / `phase()` / `log()`. Copy any file here as a template.
