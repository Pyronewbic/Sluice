# Claude Code - Anthropic's agentic coding CLI - run YOLO inside a sluice.
#
#   sluice agent claude
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export ANTHROPIC_API_KEY (or CLAUDE_CODE_OAUTH_TOKEN) on the HOST before running -
# it's forwarded into the box, never baked. Browser OAuth can't complete headless, use a key.
SLUICE_EXTRA_NPM="@anthropic-ai/claude-code"
# statsig.com is Claude Code's feature-flag/metrics host (flags can affect behavior). Upstream's
# init-firewall also lists statsig.anthropic.com, but that name has no public DNS (anthropics/claude-code#55623);
# dropped - statsig.com covers the real backend. sentry.io error reporting is left blocked.
SLUICE_ALLOW_DOMAINS="api.anthropic.com platform.claude.com claude.ai statsig.com"
SLUICE_DESC="Claude Code (Anthropic)"
# In-repo secrets: .env* files are shadowed (unreadable in the box); SLUICE_MASK="" to disable.
SLUICE_MASK=".env*"
SLUICE_ENV="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
# Persist Claude Code's sessions/history/auth-cache across runs (host-side, per project).
SLUICE_STATE_DIRS=".claude"
# --dangerously-skip-permissions = YOLO. Drop it for interactive approvals.
SLUICE_RUN_CMD="claude --dangerously-skip-permissions"
