# sluice config - scaffolded by 'sluice init' (detected: node/npm).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).
# NOTE: npm/yarn registries are allowed; add runtime CDNs/APIs or run 'sluice learn'.

SLUICE_PORTS="3000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="npm install && npm start"
SLUICE_ALLOW_DOMAINS=""    # runtime egress hosts (or run 'sluice learn')
