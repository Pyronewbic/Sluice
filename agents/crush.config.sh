# Crush (Charm) - multi-provider terminal coding agent - run YOLO inside a sluice.
#
#   sluice agent crush
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export your provider key (ANTHROPIC_API_KEY / OPENAI_API_KEY / ...) on the HOST.
SLUICE_EXTRA_NPM="@charmland/crush"
# api.anthropic.com / api.openai.com cover the common providers; catwalk.charm.sh is Crush's
# model catalog. For another provider, add its host (or run `sluice learn`).
SLUICE_ALLOW_DOMAINS="api.anthropic.com api.openai.com catwalk.charm.sh"
SLUICE_DESC="Crush (Charm)"
SLUICE_ENV="ANTHROPIC_API_KEY OPENAI_API_KEY"
# Persist Crush's sessions/db across runs (its data dir). NOT .config/crush - that's just config.
SLUICE_STATE_DIRS=".local/share/crush"
# --yolo skips all permission prompts (the sluice is the sandbox). Drop it for interactive.
SLUICE_RUN_CMD="crush --yolo"
