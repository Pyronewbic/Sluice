#!/usr/bin/env bash
# Verify the control-plane seams on a real built box: structured output (ls/doctor/egress --json),
# the egress audit record, and the SLUICE_POLICY_URL allowlist-fetch hook. Heavy (builds an image) -
# manual, not the PR gate. Needs python3 (JSON validation).
#
#   ./test/verify-seams.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
valid_json() { printf '%s' "$1" | python3 -m json.tool >/dev/null 2>&1; }

base="$(mktemp -d)"; work="$base/seams"; mkdir -p "$work"
cat > "$work/sluice.config.sh" <<'CFG'
SLUICE_NAME="seamstest"
SLUICE_DESC="seams test box"
SLUICE_ALLOW_DOMAINS="pypi.org"
SLUICE_RUN_CMD='curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; true'
CFG
container="sluice-seamstest"
export SLUICE_NO_BANNER=1

echo "== control-plane seams =="
if ! ( cd "$work" && "$SLUICE" build ) >/tmp/verify-seams-build.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-seams-build.log; rm -rf "$base"
  echo "== $PASS passed, $FAIL failed =="; exit 1
fi
ok "build"

# Run so the proxy logs a reached host (pypi.org) + a blocked one (files.pythonhosted.org).
( cd "$work" && "$SLUICE" ) >/dev/null 2>&1 || true

# 1. ls --json: valid JSON, contains the box, marked current from inside its dir.
ls_json="$( cd "$work" && "$SLUICE" ls --json 2>/dev/null )"
valid_json "$ls_json" && ok "ls --json is valid JSON" || bad "ls --json invalid: $ls_json"
printf '%s' "$ls_json" | python3 -c "import sys,json
d=json.load(sys.stdin); b=[x for x in d if x['name']=='$container']
sys.exit(0 if b and b[0]['current'] and b[0]['description']=='seams test box' else 1)" \
  && ok "ls --json has the box (current + description)" || bad "ls --json box/fields wrong"

# 2. doctor --json: valid JSON, expected name + image.built.
dj="$( cd "$work" && "$SLUICE" doctor --json 2>/dev/null )"
valid_json "$dj" && ok "doctor --json is valid JSON" || bad "doctor --json invalid: $dj"
printf '%s' "$dj" | python3 -c "import sys,json
d=json.load(sys.stdin)
sys.exit(0 if d['name']=='$container' and d['image']['built'] and 'pypi.org' in d['allowlist'] else 1)" \
  && ok "doctor --json has name/image/allowlist" || bad "doctor --json fields wrong"

# 3. egress --json: valid JSON, pypi.org reached, files.pythonhosted.org blocked.
ej="$( cd "$work" && "$SLUICE" egress --json 2>/dev/null )"
valid_json "$ej" && ok "egress --json is valid JSON" || bad "egress --json invalid: $ej"
printf '%s' "$ej" | python3 -c "import sys,json
d=json.load(sys.stdin)
sys.exit(0 if 'pypi.org' in d['allowed'] and 'files.pythonhosted.org' in d['blocked'] else 1)" \
  && ok "egress --json: pypi reached, pythonhosted blocked" || bad "egress --json record wrong (got: $ej)"

# 4. SLUICE_POLICY_URL: a local-file policy adds a host to the box's live allowlist on the next run.
polfile="$base/policy.txt"
printf '# org egress policy\nfiles.pythonhosted.org\n' > "$polfile"
( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1 || true
( cd "$work" && SLUICE_POLICY_URL="file://$polfile" "$SLUICE" run true ) >/tmp/verify-seams-policy.log 2>&1 || true
if "$ENG" exec "$container" cat /etc/squid/allowlist.txt 2>/dev/null | grep -qx 'files.pythonhosted.org'; then
  ok "SLUICE_POLICY_URL merged the policy host into the box allowlist"
else
  bad "policy host not in the box allowlist"; tail -5 /tmp/verify-seams-policy.log
fi

# Teardown: chown the mount back, then remove container + image.
"$ENG" exec --user root "$container" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
"$ENG" rmi -f "$container" >/dev/null 2>&1 || true
rm -rf "$base" 2>/dev/null || true

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
