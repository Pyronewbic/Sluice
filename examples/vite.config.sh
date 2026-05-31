# Vite dev server (React/Vue/Svelte/Solid/...) for YOUR repo, sandboxed + firewalled.
# Copy into a Vite project as sluice.config.sh, then `sluice`.
#
# Installs deps into the mounted repo (the npm registry is allowed by default), then serves
# bound to 0.0.0.0 so the published port reaches it.
SLUICE_PORTS="5173"
SLUICE_RUN_CMD="npm install && npm run dev -- --host 0.0.0.0 --port 5173"
# Add runtime CDNs/APIs your app fetches (or run `sluice learn`). e.g. "fonts.gstatic.com"
SLUICE_ALLOW_DOMAINS=""
