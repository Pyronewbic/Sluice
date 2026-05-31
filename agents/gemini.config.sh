# Google Gemini CLI - inside a sluice.
#
#   sluice agent gemini
#
# Auth: export GEMINI_API_KEY (from Google AI Studio) on the HOST (forwarded, never baked).
SLUICE_EXTRA_NPM="@google/gemini-cli"
SLUICE_ALLOW_DOMAINS="generativelanguage.googleapis.com cloudcode-pa.googleapis.com oauth2.googleapis.com"
SLUICE_ENV="GEMINI_API_KEY GOOGLE_API_KEY"
# --yolo auto-approves actions; safe here because the sluice is the sandbox. Drop it for interactive.
SLUICE_RUN_CMD="gemini --yolo"
