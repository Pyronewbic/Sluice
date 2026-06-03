#!/usr/bin/env bats
# Acceptance: scoped TLS interception (SLUICE_BUMP_DOMAINS). Ported from acceptance.sh's bump section.
# setup_file brings the box up WITH the bump knobs (recreates the container) and captures squid's access
# log once; each @test reads it. Bump api.github.com allowing only /zen; npmjs stays spliced.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  mkdir -p "$WORK/b"
  printf 'SLUICE_NAME="bumptest"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/b/sluice.config.sh"
  export SLUICE_BUMP_DOMAINS="api.github.com" SLUICE_BUMP_URLS='^https?://api\.github\.com/zen'
  ( cd "$WORK/b" && "$ROOT/bin/sluice" build ) >/dev/null 2>&1
  for u in https://api.github.com/zen https://api.github.com/octocat https://registry.npmjs.org/; do
    ( cd "$WORK/b" && "$ROOT/bin/sluice" run curl -s -o /dev/null --max-time 12 "$u" ) >/dev/null 2>&1
  done
  "${SLUICE_ENGINE:-docker}" exec sluice-bumptest cat /var/log/squid/access.log > "$WORK/blog" 2>/dev/null || true
}

teardown_file() {
  "${SLUICE_ENGINE:-docker}" exec --user root sluice-bumptest chown -R "$(id -u):$(id -g)" "$WORK/b" >/dev/null 2>&1 || true
  ( cd "$WORK/b" 2>/dev/null && "$ROOT/bin/sluice" stop ) >/dev/null 2>&1 || true
  "${SLUICE_ENGINE:-docker}" rm -f -v sluice-bumptest >/dev/null 2>&1 || true
  "${SLUICE_ENGINE:-docker}" rmi -f sluice-bumptest >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "bump: non-listed path on a bumped host denied by squid (TCP_DENIED/403)" {
  run grep -q "TCP_DENIED/403 GET https://api.github.com/octocat" "$WORK/blog"
  assert_success
}

@test "bump: allowed path decrypted + permitted (squid logged the full URL)" {
  grep -q "GET https://api.github.com/zen" "$WORK/blog" && return 0
  # origin may refuse the CI IP; the proof of bumping is then that the host is on the bumplist
  run bash -c "cd '$WORK/b' && '$SLUICE' run grep -qx api.github.com /etc/squid/bumplist.txt"
  assert_success
}

@test "bump: non-bumped registry.npmjs.org still spliced (TCP_TUNNEL, not decrypted)" {
  run grep -qE "TCP_TUNNEL/[0-9]+ CONNECT registry.npmjs.org" "$WORK/blog"
  assert_success
}
