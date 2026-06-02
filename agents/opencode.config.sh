# opencode - open-source terminal coding agent (multi-provider) - run YOLO inside a sluice.
#
#   sluice agent opencode
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export your provider key (ANTHROPIC_API_KEY / OPENAI_API_KEY / ...) on the HOST.
SLUICE_EXTRA_NPM="opencode-ai"
# opencode has no stable --yolo flag yet, so YOLO via a global allow-all permission config
# (baked at build as the sluice user). Remove this to get opencode's default prompts.
SLUICE_SETUP_CMDS='mkdir -p /home/sluice/.config/opencode && printf "{\"permission\":{\"*\":\"allow\"}}\n" > /home/sluice/.config/opencode/opencode.json'
# api.anthropic.com / api.openai.com cover the common providers; models.dev is opencode's
# model catalog. If you use another provider, add its host (or run `sluice learn`).
SLUICE_ALLOW_DOMAINS="api.anthropic.com api.openai.com models.dev"
SLUICE_DESC="opencode (multi-provider)"
SLUICE_ENV="ANTHROPIC_API_KEY OPENAI_API_KEY"
# Persist opencode's auth + sessions (its data dir) across runs. NOT .config/opencode - that
# holds the baked allow-all config above, and a mount would shadow it.
SLUICE_STATE_DIRS=".local/share/opencode"
SLUICE_RUN_CMD="opencode"
