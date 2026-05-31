# Google Gemini CLI - run YOLO inside a sluice.
#
#   sluice agent gemini
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: export GEMINI_API_KEY (from Google AI Studio) on the HOST (forwarded, never baked).
SLUICE_EXTRA_NPM="@google/gemini-cli"
# API-key path only. The free "login with Google" OAuth tier needs a browser (not headless).
SLUICE_ALLOW_DOMAINS="generativelanguage.googleapis.com"
SLUICE_ENV="GEMINI_API_KEY GOOGLE_API_KEY"
# --yolo auto-approves all actions. Drop it for interactive.
SLUICE_RUN_CMD="gemini --yolo"
