#!/usr/bin/env bats
# examples/nix.config.sh (Nix composed inside a sluice): builds it (~1.5GB), then checks the baked
# tool runs, the box is non-root, Nix works offline in-box, and runtime egress stays locked. Heavy -
# nightly, not the PR gate. Ported from verify-nix.sh. The ~1.5GB image is kept (not rmi'd).
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/nix"
  cp "$ROOT/examples/nix.config.sh" "$WORK/nix/sluice.config.sh"
  ( cd "$WORK/nix" && "$SLUICE" build ) >/tmp/verify-nix-build.log 2>&1 || true
  ( cd "$WORK/nix" && "$SLUICE" run true ) >/dev/null 2>&1 || true   # bring the box up
}

teardown_file() {
  host_own sluice-nix "$WORK/nix"
  ( cd "$WORK/nix" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  rm -rf "$WORK"   # keep the ~1.5GB Nix image cached (don't rmi)
}

@test "nix: example image built (Nix installed + tool baked)" {
  run "$ENG" image inspect sluice-nix
  assert_success
}

@test "nix: the baked tool runs (no runtime egress)" {
  run bash -c "cd '$WORK/nix' && '$SLUICE' run sh -lc 'export PATH=\"\$HOME/.nix-profile/bin:\$PATH\"; hello' 2>/dev/null"
  assert_output --partial "Hello, world!"
}

@test "nix: the box is non-root (uid 1000)" {
  run bash -c "cd '$WORK/nix' && '$SLUICE' run id -u 2>/dev/null | tr -d '[:space:]'"
  assert_output "1000"
}

@test "nix: nix itself works in the box (offline, baked store)" {
  run bash -c "cd '$WORK/nix' && '$SLUICE' run sh -lc '\"\$HOME/.nix-profile/bin/nix\" --version' 2>/dev/null"
  assert_output --partial "nix"
}

@test "nix: runtime egress is still locked (example.com blocked)" {
  run bash -c "cd '$WORK/nix' && '$SLUICE' run sh -lc 'curl -sS -o /dev/null --max-time 8 https://example.com'"
  assert_failure
}
