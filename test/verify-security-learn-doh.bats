#!/usr/bin/env bats
# learn must not live-allow a DoH/DoT resolver (an exfil channel the boot path strips via drop_doh):
# the live squid reload appends to the post-filter allowlist, so without the guard a DoH pick would
# go live while a rebuilt box re-blocks it. SLUICE_ALLOW_DOH=1 is the documented opt-in. A normal
# host must still be allowed (the guard doesn't over-block). One box, ad-hoc runs (no rebuilds).
load test_helper/common

setup_file()    { make_box learn-doh box 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box learn-doh box; }

# Block a host, then `learn --apply`; the box's config is read back for the allowlist line.
_allowline() { grep -E '^SLUICE_ALLOW_DOMAINS=' "$WORK/box/sluice.config.sh" 2>/dev/null || true; }

@test "learn: a blocked DoH resolver is refused by --apply (not written, warned)" {
  ( cd "$WORK/box" && "$SLUICE" run sh -c 'curl -sS -m6 -o /dev/null https://dns.google/resolve?name=example.com; true' ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/box' && '$SLUICE' learn --apply 2>&1"
  assert_output --partial "not allowing DoH"
  refute_output --partial "allowing: dns.google"
  run _allowline
  refute_output --partial "dns.google"
}

@test "learn: the refused DoH host is still blocked live" {
  run bash -c "cd '$WORK/box' && '$SLUICE' run sh -c 'curl -sS -m6 -o /dev/null -w \"%{http_code}\" https://dns.google/resolve?name=example.com' 2>/dev/null"
  assert_output --partial "000"
}

@test "learn: a normal blocked host is still allowed by --apply (no over-block)" {
  ( cd "$WORK/box" && "$SLUICE" run sh -c 'curl -sS -m6 -o /dev/null https://pypi.org; true' ) >/dev/null 2>&1 || true
  host_own sluice-sectest-learn-doh "$WORK/box"   # box chowned the dir to uid 1000; let the host rewrite the config (learn --apply)
  run bash -c "cd '$WORK/box' && '$SLUICE' learn --apply 2>&1"
  assert_output --partial "allowing:"
  assert_output --partial "pypi.org"
  run _allowline
  assert_output --partial "pypi.org"
}

@test "learn: the newly-allowed normal host is reachable live (no rebuild)" {
  run bash -c "cd '$WORK/box' && '$SLUICE' run sh -c 'curl -sS -m10 -o /dev/null -w \"%{http_code}\" https://pypi.org' 2>/dev/null"
  assert_output --partial "200"
}
