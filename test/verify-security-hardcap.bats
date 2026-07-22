#!/usr/bin/env bats
# SLUICE_EGRESS_HARD_CAP_BYTES: a PREVENTIVE in-box byte ceiling on proxied egress, enforced with an
# xt_quota rule on squid's uid followed by a DROP - so exhaustion severs even established flows. This
# suite asserts the rule SHAPE, the ordering (the pair precedes the ESTABLISHED accept), the host-side
# <1MiB refusal, and - in the final test - that the cap ACTUALLY FIRES against live traffic.
#
# Do NOT assert on the byte value printed by `iptables -S`: it is the CONFIGURED quota, not the
# remaining one. Verified on Docker Desktop's LinuxKit kernel - after 123K of real proxied egress the
# printed value was still the full 1258291. Enforcement is observable through the RULE COUNTERS
# (`iptables -L -v`) instead: bytes on the quota ACCEPT, packets on the following DROP once exhausted.
# xt_quota is absent on some kernels; the box then fails closed (refuses to boot), so the enforcement
# tests skip on such a runner rather than false-fail. Needs Docker (engine lane).
load test_helper/common

setup_file() {
  # cap at the 1 MiB floor + one allowlisted host: the exhaustion test drives real bytes through
  # squid, and the floor keeps the traffic it must generate to the minimum.
  make_box hardcap hc 'SLUICE_EGRESS_HARD_CAP_BYTES="1048576"' 'SLUICE_ALLOW_DOMAINS="example.com"' \
    'SLUICE_RUN_CMD="bash"'
  "${SLUICE_ENGINE:-docker}" logs sluice-sectest-hardcap > "$WORK/hclog" 2>&1 || true
}
teardown_file() { destroy_box hardcap hc; }

_skip_if_no_xtquota() {
  # if...fi (not `&& skip`): a bare `grep -q ... && skip` returns grep's exit 1 when the pattern is
  # ABSENT (xt_quota present, box booted), failing the test at the guard instead of letting it run.
  if grep -q "lacks xt_quota" "$WORK/hclog" 2>/dev/null; then
    skip "runner kernel lacks xt_quota - the hard cap cannot be enforced here (box fails closed)"
  fi
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

# _uid999_rule <kind>: the live counters for squid's quota ACCEPT ("accept") or the DROP that follows
# it ("drop"), as "<packets> <bytes>". Reads `iptables -L -v` (counters), not `-S` (configured value).
_uid999_rule() {
  local want="$1" line
  line="$("$ENG" exec --user root sluice-sectest-hardcap iptables -L OUTPUT -v -n 2>/dev/null \
    | grep -E "owner UID match 999" | grep -vE "dpt:3128")"
  case "$want" in
    accept) printf '%s\n' "$line" | grep    -F "quota:" | awk '{print $1, $2}' ;;
    drop)   printf '%s\n' "$line" | grep -v -F "quota:" | awk '{print $1, $2}' ;;
  esac
}

# The behavioural end of the suite: every test above proves the rule is INSTALLED; this one proves it
# BITES. Without it the only evidence the cap ever stopped a byte was a demo GIF whose "killed
# mid-flight by the cap" line was a hardcoded string that printed even when curl exited 0.
#
# Not gated on the upstream's cooperation: example.com 405s a PUT, but the rejected body still
# crosses the wire through squid and debits the quota, so the DROP fires regardless of status code.
@test "hardcap: the cap FIRES - egress past the ceiling is dropped, not merely rule-shaped" {
  _skip_if_no_xtquota
  "$ENG" ps --filter "name=sluice-sectest-hardcap" --filter status=running --format '{{.Names}}' \
    | grep -qx sluice-sectest-hardcap || skip "box not up"

  local before_drop; before_drop="$(_uid999_rule drop | awk '{print $1}')"
  [ -n "$before_drop" ] || skip "no uid-999 DROP rule found (cap not installed on this runner)"

  # drive > the 1 MiB cap through the proxy; each PUT is refused at ~170 KB, so several are needed.
  "$ENG" exec sluice-sectest-hardcap sh -c '
    i=0; while [ $i -lt 12 ]; do
      head -c 1048576 /dev/urandom \
        | curl -sS --max-time 15 -o /dev/null -T - https://example.com/ >/dev/null 2>&1
      i=$((i+1))
    done' >/dev/null 2>&1 || true

  local after_drop after_bytes
  after_drop="$(_uid999_rule drop  | awk '{print $1}')"
  after_bytes="$(_uid999_rule accept | awk '{print $2}')"

  # the ACCEPT must have carried real traffic (guards against a vacuous pass when egress never left)
  [ "$after_bytes" != "0" ] || skip "no proxied egress recorded - runner has no outbound network"

  # and past the ceiling, packets must land on the DROP
  [ "$after_drop" -gt "$before_drop" ]
}
