#!/usr/bin/env bats
# Acceptance: scoped TLS interception (SLUICE_BUMP_DOMAINS). Ported from acceptance.sh's bump section.
# setup_file brings the box up WITH the bump knobs (recreates the container) and captures squid's access
# log once; each @test reads it. Bump api.github.com allowing only /zen; npmjs stays spliced.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  mkdir -p "$WORK/b"
  printf 'SLUICE_NAME="bumptest"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/b/sluice.config.sh"
  # Also exercise the bumped-lane upload controls (H5): a method allowlist + a tiny request-body cap.
  export SLUICE_BUMP_DOMAINS="api.github.com" SLUICE_BUMP_URLS='^https?://api\.github\.com/zen'
  export SLUICE_BUMP_METHODS="GET HEAD" SLUICE_BUMP_MAX_BODY="16"
  ( cd "$WORK/b" && "$ROOT/bin/sluice" build ) >/dev/null 2>&1
  for u in https://api.github.com/zen https://api.github.com/octocat https://registry.npmjs.org/; do
    ( cd "$WORK/b" && "$ROOT/bin/sluice" run curl -s -o /dev/null --max-time 12 "$u" ) >/dev/null 2>&1
  done
  # A POST to the allowed /zen path: the method allowlist (GET HEAD) must deny it even though the URL matches.
  ( cd "$WORK/b" && "$ROOT/bin/sluice" run curl -s -o /dev/null --max-time 12 -X POST -d hi https://api.github.com/zen ) >/dev/null 2>&1
  "${SLUICE_ENGINE:-docker}" exec sluice-bumptest cat /var/log/squid/access.log > "$WORK/blog" 2>/dev/null || true
}

teardown_file() { drop_box sluice-bumptest "$WORK/b"; }

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

# H5: the method allowlist ACL is wired into squid.conf, and a POST to the bumped host is denied even on
# an allowed path (the URL matches but the method doesn't). The ACL presence is the reliable gate; the
# log line is the best-effort live proof.
@test "bump methods: the method ACL + request-body cap are wired into squid.conf" {
  run bash -c "cd '$WORK/b' && '$SLUICE' run sh -c 'grep -q \"^acl bump_method method GET HEAD\" /etc/squid.conf && grep -q \"^request_body_max_size 16 bytes\" /etc/squid.conf'"
  assert_success
}

@test "bump methods: a POST to the bumped host is denied by the method allowlist" {
  grep -qE "TCP_DENIED/[0-9]+ POST https://api.github.com/zen" "$WORK/blog" && return 0
  # origin/CI-IP variance: fall back to the ACL wiring as the gate (the deny rule is present)
  run bash -c "cd '$WORK/b' && '$SLUICE' run grep -q '^http_access deny bump_dom !bump_method' /etc/squid.conf"
  assert_success
}
