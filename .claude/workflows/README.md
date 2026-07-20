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
| `preflight` | Ship-readiness gate for a branch: runs the house pre-merge checklist (bin/sluice in sync, shellcheck, unit lane, commit hygiene), judges the diff for missing tests / THREAT_MODEL + doc drift, adversarially verifies each blocker, and folds in `review-launcher` when the launcher changed. Output only. Pass a base ref as `args` (default `main`). |
| `parallel-worktree` | Splits a multi-part task into **disjoint-file** streams, implements each in an isolated git worktree in parallel (the one write-workflow here), and verifies each in-scope. A preflight gate serializes any streams that overlap. Reports per-stream branches + gotchas; the driver integrates (bin/sluice merge driver), full-gates on Linux, and ships. Pass `args.task` (and optionally `args.streams` / `args.base`). Use selectively - sluice is overlap-dense. |

Anatomy: a pure-literal `export const meta = {...}` (name, description, whenToUse, phases) then a body
using `agent()` (takes a structured-output `schema`; invocation `args` are in scope) / `parallel()` /
`pipeline()` / `phase()` / `log()`. Copy any file here as a template.
