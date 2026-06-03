#!/usr/bin/env bats
# Read-only control-plane surface on real boxes (ls / doctor / egress / policy / rm). setup_file
# builds two boxes (A started + exercised, B merely built) and captures the human + --json outputs;
# read-only @tests assert the captures, then ordered @tests exercise the mutating flows (orphan
# lifecycle, policy merge, rm). Needs python3 (JSON validation). Ported from verify-control-plane.sh.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/a" "$WORK/b"
  cat > "$WORK/a/sluice.config.sh" <<'CFG'
SLUICE_NAME="control-a"
SLUICE_DESC="alpha control-plane box"
SLUICE_ALLOW_DOMAINS="pypi.org"
SLUICE_RUN_CMD='curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; true'
CFG
  cat > "$WORK/b/sluice.config.sh" <<'CFG'
SLUICE_NAME="control-b"
SLUICE_DESC="beta control-plane box"
SLUICE_RUN_CMD=true
CFG
  ( cd "$WORK/a" && "$SLUICE" build ) >/tmp/verify-cp-a.log 2>&1 || true
  ( cd "$WORK/b" && "$SLUICE" build ) >/tmp/verify-cp-b.log 2>&1 || true
  ( "$ENG" image inspect sluice-control-a && "$ENG" image inspect sluice-control-b ) >/dev/null 2>&1 && echo ok > "$WORK/build.ok" || echo no > "$WORK/build.ok"

  # Start + exercise A (reaches pypi, blocked on files.pythonhosted); B stays merely built.
  ( cd "$WORK/a" && "$SLUICE" ) >/dev/null 2>&1 || true

  # Capture the control-plane feeds (egress capture must precede the policy @test, which allowlists
  # pythonhosted on A and drops the blocked count).
  "$SLUICE" ls > "$WORK/ls.human" 2>/dev/null || true
  ( cd "$WORK/a" && "$SLUICE" ls ) > "$WORK/ls.human.a" 2>/dev/null || true
  ( cd "$WORK/a" && "$SLUICE" ls --json ) > "$WORK/ls.json" 2>/dev/null || true
  ( cd "$WORK/a" && "$SLUICE" doctor --json ) > "$WORK/doctor.json" 2>/dev/null || true
  ( cd "$WORK/a" && "$SLUICE" egress --json ) > "$WORK/egress.json" 2>/dev/null || true
  "$SLUICE" ls --egress --json > "$WORK/ls-egress.json" 2>/dev/null || true
}

teardown_file() {
  host_own sluice-control-a "$WORK/a"
  ( cd "$WORK/a" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f sluice-control-b sluice-control-orphan >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-control-a sluice-control-b sluice-control-orphan >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

_pyjson() { python3 -c "$1"; }   # exits non-zero (fails the @test) if the assertion is false

@test "control-plane: both boxes built" { [ "$(cat "$WORK/build.ok")" = ok ]; }

# --- ls human table ---
@test "ls: lists both boxes with their descriptions" {
  grep -q 'sluice-control-a' "$WORK/ls.human"
  grep -q 'sluice-control-b' "$WORK/ls.human"
  grep -q 'alpha control-plane' "$WORK/ls.human"
  grep -q 'beta control-plane' "$WORK/ls.human"
}
@test "ls: started box reads 'running', unstarted reads 'built'" {
  grep 'sluice-control-a' "$WORK/ls.human" | grep -q 'running'
  grep 'sluice-control-b' "$WORK/ls.human" | grep -q 'built'
}
@test "ls: box A row shows its project path" {
  grep 'sluice-control-a' "$WORK/ls.human" | grep -qF "$WORK/a"
}
@test "ls: current box (A) is marked '*' from inside its dir; B is not" {
  grep 'sluice-control-a' "$WORK/ls.human.a" | grep -q '^\*'
  ! { grep 'sluice-control-b' "$WORK/ls.human.a" | grep -q '^\* '; }
}

# --- structured output ---
@test "ls --json: valid JSON with the box (current + description)" {
  python3 -m json.tool < "$WORK/ls.json" >/dev/null
  _pyjson "import sys,json; d=json.load(open('$WORK/ls.json')); m=[x for x in d if x['name']=='sluice-control-a']; sys.exit(0 if m and m[0]['current'] and m[0]['description']=='alpha control-plane box' else 1)"
}
@test "ls --json: posture fields (allow_count/ports/locked)" {
  _pyjson "import sys,json; d=json.load(open('$WORK/ls.json')); m=[x for x in d if x['name']=='sluice-control-a']; sys.exit(0 if m and m[0]['allow_count']==1 and m[0]['ports']==[] and m[0]['locked']==False else 1)"
}
@test "doctor --json: valid JSON with name/image/allowlist" {
  python3 -m json.tool < "$WORK/doctor.json" >/dev/null
  _pyjson "import sys,json; d=json.load(open('$WORK/doctor.json')); sys.exit(0 if d['name']=='sluice-control-a' and d['image']['built'] and 'pypi.org' in d['allowlist'] else 1)"
}
@test "egress --json: pypi reached, pythonhosted blocked" {
  python3 -m json.tool < "$WORK/egress.json" >/dev/null
  _pyjson "import sys,json; d=json.load(open('$WORK/egress.json')); sys.exit(0 if 'pypi.org' in d['allowed'] and 'files.pythonhosted.org' in d['blocked'] else 1)"
}
@test "ls --egress: box A shows a live blocked-host count" {
  python3 -m json.tool < "$WORK/ls-egress.json" >/dev/null
  _pyjson "import sys,json; d=json.load(open('$WORK/ls-egress.json')); m=[x for x in d if x['name']=='sluice-control-a']; sys.exit(0 if m and isinstance(m[0].get('blocked'), int) and m[0]['blocked']>=1 else 1)"
}

# --- orphan flagging + -b/--box targeting (mutating; ordered) ---
@test "orphan lifecycle: -b targeting, orphan flag, guarded prune, -b rm" {
  mkdir -p "$WORK/orph"
  printf 'SLUICE_NAME="control-orphan"\nSLUICE_RUN_CMD=true\n' > "$WORK/orph/sluice.config.sh"
  ( cd "$WORK/orph" && "$SLUICE" build ) >/tmp/verify-cp-orph.log 2>&1
  # -b targeting from outside any box dir routes doctor --json to the named box
  "$SLUICE" -b control-orphan doctor --json | _pyjson "import sys,json; sys.exit(0 if json.load(sys.stdin)['name']=='sluice-control-orphan' else 1)"
  rm -rf "$WORK/orph"   # delete the project dir -> the box is now an orphan
  "$SLUICE" ls --json | _pyjson "import sys,json; d=json.load(sys.stdin); m=[x for x in d if x['name']=='sluice-control-orphan']; sys.exit(0 if m and m[0]['orphan'] and m[0]['status']=='orphan' else 1)"
  # -b <orphan> shell can't run (no config to source); it dies with the orphan pointer
  ! ( "$SLUICE" -b control-orphan shell ) >/dev/null 2>&1
  # prune --orphans lists it but removes nothing without SLUICE_YES
  "$SLUICE" prune --orphans </dev/null 2>/dev/null | grep -q 'sluice-control-orphan'
  "$ENG" image inspect sluice-control-orphan >/dev/null 2>&1
  # the targeted -b rm does the actual cleanup; the live box A is untouched
  "$SLUICE" -b control-orphan rm >/dev/null 2>&1 || true
  ! "$ENG" image inspect sluice-control-orphan >/dev/null 2>&1
  "$ENG" image inspect sluice-control-a >/dev/null 2>&1
}

# --- SLUICE_POLICY_URL: a local-file policy adds a host to the box's live allowlist ---
@test "policy: SLUICE_POLICY_URL merges a host into the box allowlist on the next run" {
  printf '# org egress policy\nfiles.pythonhosted.org\n' > "$WORK/policy.txt"
  ( cd "$WORK/a" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  ( cd "$WORK/a" && SLUICE_POLICY_URL="file://$WORK/policy.txt" "$SLUICE" run true ) >/tmp/verify-cp-policy.log 2>&1 || true
  "$ENG" exec sluice-control-a cat /etc/squid/allowlist.txt 2>/dev/null | grep -qx 'files.pythonhosted.org'
}

# --- sluice rm removes that box's image only ---
@test "rm: removes box B's image only (A intact)" {
  ( cd "$WORK/b" && "$SLUICE" rm ) >/dev/null 2>&1 || true
  ! "$ENG" image inspect sluice-control-b >/dev/null 2>&1
  "$ENG" image inspect sluice-control-a >/dev/null 2>&1
}
