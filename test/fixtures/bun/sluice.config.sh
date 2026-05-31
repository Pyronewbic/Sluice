# sluice config - scaffolded by 'sluice init' (detected: node/bun).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).
# NOTE: npm/yarn registries are allowed; add runtime CDNs/APIs or run 'sluice learn'.

SLUICE_EXTRA_PKGS="bun"
SLUICE_PORTS="3000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="bun install && bun run dev -- --host 0.0.0.0 --port 3000"
SLUICE_ALLOW_DOMAINS=""    # runtime egress hosts (or run 'sluice learn')
