# JupyterLab - a Python notebook server, served from a sluice.
#
# Usage: copy this file into an (empty) project dir as sluice.config.sh, then run `sluice`.
#   mkdir notebooks && cp examples/jupyter.config.sh notebooks/sluice.config.sh
#   cd notebooks && sluice
# Then open http://localhost:8888 in your HOST browser. Your project dir is mounted, so
# notebooks you create are saved on the host. Token auth is disabled for easy localhost
# access - fine because the port is published to 127.0.0.1 only.
#
# Contrast with the Strudel example: a totally different stack (Python/pip, not npm),
# and it needs NO runtime egress - the lab UI assets are served locally, so
# SLUICE_ALLOW_DOMAINS stays empty. The only network use is pip at BUILD time (free egress).

# --- software (build time) ------------------------------------------------------
# Wolfi's Python + pip. (Wolfi is glibc-based, so pip pulls manylinux wheels - no
# compiler needed for jupyterlab/ipykernel/pyzmq.)
SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"

# Install JupyterLab + a Python kernel as the node user (--user -> ~/.local), and
# register the kernel. Runs before the firewall, so pip reaches PyPI freely.
SLUICE_SETUP_CMDS='
pip install --user --no-input jupyterlab ipykernel
python -m ipykernel install --user --name python3
'

# --- serve ----------------------------------------------------------------------
# Publish 8888 (the firewall opens the matching inbound rule). Bind 0.0.0.0 so the
# docker-forwarded traffic reaches the server; put ~/.local/bin on PATH (where pip
# --user placed the launchers); disable the token for local use.
SLUICE_PORTS="8888"
SLUICE_RUN_CMD='export PATH="$HOME/.local/bin:$PATH"; jupyter lab --ip 0.0.0.0 --port 8888 --no-browser --IdentityProvider.token='

# No runtime egress needed. To pull data/packages from inside a notebook, add the
# host(s) here, e.g. SLUICE_ALLOW_DOMAINS="data.example.com files.pythonhosted.org".
SLUICE_ALLOW_DOMAINS=""
