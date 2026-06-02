#!/usr/bin/env bash
# Verify the read-only control-plane surface on real boxes (formerly verify-ls + verify-seams):
#   - `sluice ls` human table: every box with name/description/path/status, the $PWD box marked '*'.
#   - structured output: ls/doctor/egress `--json` (valid JSON, expected fields, reached vs blocked).
#   - `SLUICE_POLICY_URL`: a host-fetched policy merges into the box's live allowlist.
#   - `sluice rm`: removes that box's image only.
# Two boxes share the run (A started + exercised, B merely built). Heavy - nightly, not the PR gate.
# Needs python3 (JSON validation).   ./test/verify-control-plane.sh
set -u
. "$(dirname "$0")/lib.sh"
valid_json() { printf '%s' "$1" | python3 -m json.tool >/dev/null 2>&1; }

base="$(mktemp -d)"; a="$base/a"; b="$base/b"; mkdir -p "$a" "$b"
cat > "$a/sluice.config.sh" <<'CFG'
SLUICE_NAME="control-a"
SLUICE_DESC="alpha control-plane box"
SLUICE_ALLOW_DOMAINS="pypi.org"
SLUICE_RUN_CMD='curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; true'
CFG
cat > "$b/sluice.config.sh" <<'CFG'
SLUICE_NAME="control-b"
SLUICE_DESC="beta control-plane box"
SLUICE_RUN_CMD=true
CFG
ca="sluice-control-a"; cb="sluice-control-b"

echo "== sluice control plane (ls / doctor / egress / policy) =="
if ! ( cd "$a" && "$SLUICE" build ) >/tmp/verify-cp-a.log 2>&1 \
   || ! ( cd "$b" && "$SLUICE" build ) >/tmp/verify-cp-b.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-cp-a.log /tmp/verify-cp-b.log; rm -rf "$base"; finish; exit 1
fi
ok "build (both boxes)"

# Start + exercise A (reaches pypi, gets blocked on files.pythonhosted); B stays merely built.
( cd "$a" && "$SLUICE" ) >/dev/null 2>&1 || true

# --- `sluice ls` human table -----------------------------------------------------------------------
out="$( "$SLUICE" ls 2>/dev/null )"
{ printf '%s' "$out" | grep -q "$ca" && printf '%s' "$out" | grep -q "$cb"; } \
  && ok "ls lists both boxes" || bad "a box is missing from ls (got: $out)"
{ printf '%s' "$out" | grep -q 'alpha control-plane' && printf '%s' "$out" | grep -q 'beta control-plane'; } \
  && ok "ls shows each box's description" || bad "a description is missing"
printf '%s' "$out" | grep "$ca" | grep -q 'running' && ok "started box reads 'running'" || bad "box A not 'running'"
printf '%s' "$out" | grep "$cb" | grep -q 'built'   && ok "unstarted box reads 'built'"   || bad "box B not 'built'"
printf '%s' "$out" | grep "$ca" | grep -qF "$a"     && ok "box A row shows its project path" || bad "box A path label missing"
out_a="$( cd "$a" && "$SLUICE" ls 2>/dev/null )"
printf '%s' "$out_a" | grep "$ca" | grep -q '^\*'   && ok "current box (A) marked '*' from inside its dir" || bad "current-box marker missing on A"
printf '%s' "$out_a" | grep "$cb" | grep -q '^\* '  && bad "non-current box (B) wrongly marked '*'" || ok "non-current box (B) unmarked"

# --- structured output (the control-plane feed) ----------------------------------------------------
ls_json="$( cd "$a" && "$SLUICE" ls --json 2>/dev/null )"
valid_json "$ls_json" && ok "ls --json is valid JSON" || bad "ls --json invalid: $ls_json"
printf '%s' "$ls_json" | python3 -c "import sys,json
d=json.load(sys.stdin); m=[x for x in d if x['name']=='$ca']
sys.exit(0 if m and m[0]['current'] and m[0]['description']=='alpha control-plane box' else 1)" \
  && ok "ls --json has the box (current + description)" || bad "ls --json box/fields wrong"

dj="$( cd "$a" && "$SLUICE" doctor --json 2>/dev/null )"
valid_json "$dj" && ok "doctor --json is valid JSON" || bad "doctor --json invalid: $dj"
printf '%s' "$dj" | python3 -c "import sys,json
d=json.load(sys.stdin)
sys.exit(0 if d['name']=='$ca' and d['image']['built'] and 'pypi.org' in d['allowlist'] else 1)" \
  && ok "doctor --json has name/image/allowlist" || bad "doctor --json fields wrong"

ej="$( cd "$a" && "$SLUICE" egress --json 2>/dev/null )"
valid_json "$ej" && ok "egress --json is valid JSON" || bad "egress --json invalid: $ej"
printf '%s' "$ej" | python3 -c "import sys,json
d=json.load(sys.stdin)
sys.exit(0 if 'pypi.org' in d['allowed'] and 'files.pythonhosted.org' in d['blocked'] else 1)" \
  && ok "egress --json: pypi reached, pythonhosted blocked" || bad "egress --json record wrong (got: $ej)"

# --- SLUICE_POLICY_URL: a local-file policy adds a host to the box's live allowlist on the next run --
polfile="$base/policy.txt"
printf '# org egress policy\nfiles.pythonhosted.org\n' > "$polfile"
( cd "$a" && "$SLUICE" stop ) >/dev/null 2>&1 || true
( cd "$a" && SLUICE_POLICY_URL="file://$polfile" "$SLUICE" run true ) >/tmp/verify-cp-policy.log 2>&1 || true
"$ENG" exec "$ca" cat /etc/squid/allowlist.txt 2>/dev/null | grep -qx 'files.pythonhosted.org' \
  && ok "SLUICE_POLICY_URL merged the policy host into the box allowlist" \
  || { bad "policy host not in the box allowlist"; tail -5 /tmp/verify-cp-policy.log; }

# --- `sluice rm` removes that box's image only (B is merely built; no mount to chown back) ----------
( cd "$b" && "$SLUICE" rm ) >/dev/null 2>&1
"$ENG" image inspect "$cb" >/dev/null 2>&1 && bad "'sluice rm' did not remove box B's image" || ok "'sluice rm' removed box B's image"
"$ENG" image inspect "$ca" >/dev/null 2>&1 && ok "'sluice rm' on B left box A's image intact" || bad "'sluice rm' on B also removed box A's image"

teardown_box "$ca" "$a"
"$ENG" rm -f "$cb" >/dev/null 2>&1 || true
rm -rf "$base" 2>/dev/null || true
finish
