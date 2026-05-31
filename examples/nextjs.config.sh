# Next.js dev server for YOUR repo, sandboxed + firewalled.
# Copy into a Next.js project as sluice.config.sh, then `sluice`.
SLUICE_PORTS="3000"
SLUICE_RUN_CMD="npm install && npm run dev -- -H 0.0.0.0 -p 3000"
# Add runtime hosts your app fetches from (or run `sluice learn`).
SLUICE_ALLOW_DOMAINS=""
