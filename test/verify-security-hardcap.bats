#!/usr/bin/env bats
# SLUICE_EGRESS_HARD_CAP_BYTES: a PREVENTIVE in-box byte ceiling on proxied egress, enforced with an
# xt_quota rule on squid's uid followed by a DROP - so exhaustion severs even established flows. This
# suite asserts the rule SHAPE (never the byte value - `iptables -S` prints the counting-down remaining
# quota) and the ordering (the pair precedes the ESTABLISHED accept), plus the host-side <1MiB refusal.
# xt_quota is absent on some kernels; the box then fails closed (refuses to boot), so the enforcement
# tests skip on such a runner rather than false-fail. Needs Docker (engine lane).
load test_helper/common

setup_file() {
  make_box hardcap hc 'SLUICE_EGRESS_HARD_CAP_BYTES="2097152"' 'SLUICE_RUN_CMD="bash"'
  "${SLUICE_ENGINE:-docker}" logs sluice-sectest-hardcap > "$WORK/hclog" 2>&1 || true
}
teardown_file() { destroy_box hardcap hc; }

_skip_if_no_xtquota() {
  grep -q "lacks xt_quota" "$WORK/hclog" 2>/dev/null && skip "runner kernel lacks xt_quota - the hard cap cannot be enforced here (box fails closed)"
}

@test "hardcap: box image built" { run "$ENG" image inspect sluice-sectest-hardcap; assert_success; }

@test "hardcap: the squid-uid quota ACCEPT + uid-owner DROP pair is in OUTPUT (shape only)" {
  _skip_if_no_xtquota
  run "$ENG" exec --user root sluice-sectest-hardcap iptables -S OUTPUT
  assert_success
  assert_output --partial "-m quota"
  echo "$output" | grep -qE -- '--uid-owner [0-9]+ -j DROP'
}

@test "hardcap: the quota rule precedes the ESTABLISHED accept (established flows hard-stop)" {
  _skip_if_no_xtquota
  run bash -c "
    out=\$('$ENG' exec --user root sluice-sectest-hardcap iptables -S OUTPUT)
    qln=\$(printf '%s\n' \"\$out\" | grep -n -- '-m quota' | head -1 | cut -d: -f1)
    eln=\$(printf '%s\n' \"\$out\" | grep -nE -- '--state (ESTABLISHED,RELATED|RELATED,ESTABLISHED)' | tail -1 | cut -d: -f1)
    [ -n \"\$qln\" ] && [ -n \"\$eln\" ] && [ \"\$qln\" -lt \"\$eln\" ]
  "
  assert_success
}

@test "hardcap: a box without the knob has no quota rule (no accidental cap)" {
  local d="$WORK/nocap"; mkdir -p "$d"
  printf 'SLUICE_NAME="sectest-hcnocap"\nSLUICE_RUN_CMD="true"\n' > "$d/sluice.config.sh"
  ( cd "$d" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  run "$ENG" exec --user root sluice-sectest-hcnocap iptables -S OUTPUT
  refute_output --partial "-m quota"
  ( cd "$d" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f sluice-sectest-hcnocap >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-hcnocap >/dev/null 2>&1 || true
}

@test "hardcap: a sub-1MiB cap is refused host-side before build" {
  local d="$WORK/tiny"; mkdir -p "$d"
  printf 'SLUICE_NAME="sectest-hctiny"\nSLUICE_EGRESS_HARD_CAP_BYTES="1000"\nSLUICE_RUN_CMD="true"\n' > "$d/sluice.config.sh"
  run bash -c "cd '$d' && '$SLUICE' build"
  assert_failure
  assert_output --partial ">= 1048576"
}

@test "hardcap: the receipt read stays host-side (works even when in-box egress is capped)" {
  _skip_if_no_xtquota
  "$ENG" ps --filter "name=sluice-sectest-hardcap" --filter status=running --format '{{.Names}}' | grep -qx sluice-sectest-hardcap || skip "box not up"
  # `sluice egress` reads the proxy log via a host-side exec, not container egress, so it must succeed
  # regardless of the cap. (Full exhaustion behaviour is asserted structurally above - a live multi-MiB
  # upload is too flaky to gate on in CI.)
  run bash -c "cd '$WORK/hc' && '$SLUICE' egress"
  assert_success
}
