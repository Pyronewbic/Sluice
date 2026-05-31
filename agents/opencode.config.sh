# opencode — open-source terminal coding agent (multi-provider) — inside a sluice.
#
#   sluice agent opencode
#
# Auth: export your provider key (ANTHROPIC_API_KEY / OPENAI_API_KEY / …) on the HOST.
SLUICE_EXTRA_NPM="opencode-ai"
# api.anthropic.com / api.openai.com cover the common providers; models.dev is opencode's
# model catalog. If you use another provider, add its host (or run `sluice learn`).
SLUICE_ALLOW_DOMAINS="api.anthropic.com api.openai.com models.dev"
SLUICE_ENV="ANTHROPIC_API_KEY OPENAI_API_KEY"
SLUICE_RUN_CMD="opencode"
