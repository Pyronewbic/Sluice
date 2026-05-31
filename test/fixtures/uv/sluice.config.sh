# sluice config - scaffolded by 'sluice init' (detected: python-3.12/uv (fastapi)).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).

SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip uv"
SLUICE_PORTS="8000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="uv sync && uv run uvicorn main:app --host 0.0.0.0 --port 8000"
SLUICE_ALLOW_DOMAINS="pypi.org files.pythonhosted.org"    # runtime egress hosts (or run 'sluice learn')
