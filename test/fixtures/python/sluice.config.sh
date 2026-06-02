# sluice config - scaffolded by 'sluice init' (detected: python-3.12/pip (flask)).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).

SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"
SLUICE_PORTS="5000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="export PATH=\"\$HOME/.local/bin:\$PATH\"; pip install --user -r requirements.txt && flask --app app run --host 0.0.0.0 --port 5000"
SLUICE_ALLOW_DOMAINS="pypi.org files.pythonhosted.org"    # runtime egress hosts (or run 'sluice learn')
