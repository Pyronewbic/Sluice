# sluice config - scaffolded by 'sluice init' (detected: python-3.12/pip (flask)).
SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"
SLUICE_PORTS="5000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_PREFETCH_FILES="requirements.txt"   # manifests copied into the build for the prefetch
SLUICE_PREFETCH_CMD="export PATH=\"\$HOME/.local/bin:\$PATH\"; pip install --user -r requirements.txt"
SLUICE_RUN_CMD="export PATH=\"\$HOME/.local/bin:\$PATH\"; flask --app app run --host 0.0.0.0 --port 5000"
SLUICE_ALLOW_DOMAINS=""        # runtime egress hosts (or run 'sluice learn')
