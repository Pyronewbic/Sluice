# FastAPI / uvicorn (Python) web API for YOUR repo, sandboxed + firewalled.
# Copy into your project as sluice.config.sh (expects requirements.txt + app.py exposing `app`).
SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"
# pip fetches from PyPI at runtime (not in the base allowlist), so allow it here:
SLUICE_ALLOW_DOMAINS="pypi.org files.pythonhosted.org"
SLUICE_PORTS="8000"
SLUICE_RUN_CMD='export PATH="$HOME/.local/bin:$PATH"; pip install --user -r requirements.txt && uvicorn app:app --host 0.0.0.0 --port 8000'
