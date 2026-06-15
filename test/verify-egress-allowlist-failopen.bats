#!/usr/bin/env bats
# Egress-allowlist fail-open closures (unit; no engine). Two host-side guards decide what direct egress
# / laundering risk is let through, so they get isolated coverage extracted from the built launcher:
#   - laundering_host: the leading-dot WILDCARD form (.host) is the documented primary allowlist form
#     and exactly what `sluice learn` writes, so it must flag the same launderers the bare host does.
#   - validate_allow_ips: SLUICE_ALLOW_IPS is a direct-egress hatch (bypasses squid); a too-broad CIDR
#     or an IPv6 literal must be refused, not just the /0 catch-all - while legit narrow entries pass.
load test_helper/common

# Pull just laundering_host out of bin/sluice (don't source it - that runs the whole CLI).
setup() { eval "$(sed -n '/^laundering_host()/,/^}/p' "$ROOT/bin/sluice")"; }

# --- laundering_host: the leading-dot wildcard must match like the bare host ----------------------
@test "laundering: a leading-dot wildcard of an exact-host launderer is flagged (.storage.googleapis.com)" {
  run laundering_host .storage.googleapis.com; assert_success
}
@test "laundering: the bare exact-host launderer is still flagged (storage.googleapis.com)" {
  run laundering_host storage.googleapis.com; assert_success
}
@test "laundering: a leading-dot wildcard of a webhook/LLM launderer is flagged (.hooks.slack.com, .api.openai.com)" {
  run laundering_host .hooks.slack.com; assert_success
  run laundering_host .api.openai.com;  assert_success
}
@test "laundering: subdomain + suffix forms still match (no regression)" {
  run laundering_host x.s3.amazonaws.com;        assert_success   # suffix arm
  run laundering_host my.pastebin.com;           assert_success   # *pastebin.com
  run laundering_host x.blob.core.windows.net;   assert_success
}
@test "laundering: a non-launderer is NOT flagged, bare or wildcard (no false positive)" {
  run laundering_host api.example.com;  assert_failure
  run laundering_host .example.com;     assert_failure
  run laundering_host github.com;       assert_failure
}

# --- validate_allow_ips: build a self-contained script (stub die + the extracted fn) and run it the
# way the launcher does (set -euo pipefail). $1 = the SLUICE_ALLOW_IPS value to feed.
_validate_script() {
  local t="$1"
  cat > "$t" <<'STUBS'
set -euo pipefail
die() { printf 'DIE:%s\n' "$*" >&2; exit 7; }   # record + exit, like the real die
E_YEL=''; E_RST=''
STUBS
  # Pull the floor constant the extracted fn references. `|| true` so a launcher that PREDATES the
  # floor (the var is absent) doesn't abort this builder under bats errexit on grep's no-match - the
  # extracted validate_allow_ips then just exercises whatever guard that launcher actually has. This
  # keeps the _passes cases honest GREEN-only forward assertions (no false-reject in the fixed code),
  # not red-against-old artifacts of a missing var; the _dies closures stay genuinely red against old.
  grep -m1 '^_ALLOW_IPS_MIN_PREFIX=' "$ROOT/bin/sluice" >> "$t" || true
  sed -n '/^validate_allow_ips()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  # The triggering value is EXPORTED by the caller so a space-separated multi-entry list isn't
  # word-split by an `env VAR=val` prefix (0.0.0.0/1 128.0.0.0/1 is two entries in one var).
  printf 'validate_allow_ips && echo "PASS"\n' >> "$t"
}
_dies()   { local t="$BATS_TEST_TMPDIR/v_die.sh";  _validate_script "$t"; run bash "$t"; assert_failure 7; assert_output --partial "DIE:"; refute_output --partial "PASS"; }
_passes() { local t="$BATS_TEST_TMPDIR/v_ok.sh";   _validate_script "$t"; run bash "$t"; assert_success; assert_output --partial "PASS"; refute_output --partial "DIE:"; }

@test "allow-ips: the two-CIDR full-IPv4 cover (0.0.0.0/1 128.0.0.0/1) is refused" {
  export SLUICE_ALLOW_IPS="0.0.0.0/1 128.0.0.0/1"; _dies
}
@test "allow-ips: a broad prefix below the floor (10.0.0.0/4) is refused" {
  export SLUICE_ALLOW_IPS="10.0.0.0/4"; _dies
}
@test "allow-ips: a /7 (one below the /8 floor) is refused" {
  export SLUICE_ALLOW_IPS="10.0.0.0/7"; _dies
}
@test "allow-ips: an IPv6 literal is refused (IPv4-only)" {
  export SLUICE_ALLOW_IPS="2001:db8::1"; _dies
}
@test "allow-ips: a full-form IPv6 literal (no :: shorthand) is refused" {
  export SLUICE_ALLOW_IPS="fe80:1:2:3:4:5:6:7"; _dies
}
@test "allow-ips: the /0 catch-all is still refused (regression on the pre-existing guard)" {
  export SLUICE_ALLOW_IPS="0.0.0.0/0"; _dies
}

@test "allow-ips: a legit ip:port passes (10.0.0.5:5432)" {
  export SLUICE_ALLOW_IPS="10.0.0.5:5432"; _passes
}
@test "allow-ips: a /24 passes" {
  export SLUICE_ALLOW_IPS="192.168.1.0/24"; _passes
}
@test "allow-ips: a /32 passes" {
  export SLUICE_ALLOW_IPS="10.0.0.5/32"; _passes
}
@test "allow-ips: the /8 floor itself passes (inclusive)" {
  export SLUICE_ALLOW_IPS="10.0.0.0/8"; _passes
}
@test "allow-ips: a bare host passes" {
  export SLUICE_ALLOW_IPS="db.internal:5432"; _passes
}
@test "allow-ips: a mixed list of only-legit entries passes" {
  export SLUICE_ALLOW_IPS="10.0.0.5:5432 192.168.1.0/24 10.0.0.6:6379/tcp"; _passes
}
