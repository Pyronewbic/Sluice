#!/usr/bin/env bats
# learn must not live-allow a DoH/DoT resolver (an exfil channel the boot path strips via drop_doh):
# the live squid reload appends to the post-filter allowlist, so without the guard a DoH pick would
# go live while a rebuilt box re-blocks it. SLUICE_ALLOW_DOH=1 is the documented opt-in. A normal
# host must still be allowed (the guard doesn't over-block). One box, ad-hoc runs (no rebuilds).
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/box"
  cat > "$WORK/box/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-learn-doh"
SLUICE_RUN_CMD="bash"
CFG
  ( cd "$WORK/box" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  chown_back_tree sluice-sectest-learn-doh "$WORK"
  ( cd "$WORK/box" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-learn-doh >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-learn-doh >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

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
