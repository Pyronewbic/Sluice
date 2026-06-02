SLUICE_NAME="lock-demo"
SLUICE_RUN_CMD=true
SLUICE_EXTRA_PKGS="ripgrep"
SLUICE_EXTRA_NPM="lodash@4.17.4"   # a known-CVE pin so `lock --scan --fail-on high` has something to gate on
