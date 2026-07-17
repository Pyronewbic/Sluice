#!/usr/bin/env bats
# Signed-base verification (SLUICE_BASE_IMAGE + SLUICE_REQUIRE_SIGNED, src/70-build-run.sh verify_base).
# Engine-free: stub docker + cosign on PATH; verify_base runs (and may die) BEFORE any real build, so
# the assertions never reach the engine. This backs the "tampered sandbox core" threat-model guarantee.
load test_helper/common

# Write a project whose base is a ghcr sluice-base ref (the only refs verify_base acts on) and build
# it behind stub docker+cosign. $1 = extra config lines; $2 = cosign stub exit code.
_build_with_stubs() {
  W="$(mktemp -d)"; mkdir -p "$W/bin" "$W/p"
  printf '#!/bin/sh\nexit 1\n' > "$W/bin/docker"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$W/bin/cosign"
  chmod +x "$W/bin/docker" "$W/bin/cosign"
  { printf 'SLUICE_NAME="sb"\nSLUICE_BASE_IMAGE="ghcr.io/pyronewbic/sluice-base:test"\nSLUICE_RUN_CMD="true"\n'; printf '%s\n' "$1"; } > "$W/p/sluice.config.sh"
  run bash -c "cd '$W/p' && PATH='$W/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' build 2>&1"
}

teardown() { rm -rf "$W"; }

@test "signed-base: REQUIRE_SIGNED=1 makes a failed cosign verify fatal" {
  _build_with_stubs 'SLUICE_REQUIRE_SIGNED=1' 1   # cosign exits 1 -> verification fails
  assert_failure
  assert_output --partial "cosign"
  refute_output --partial "image build failed"   # died on the signature, never reached the build
}

@test "signed-base: without REQUIRE_SIGNED a failed verify only warns (build proceeds)" {
  _build_with_stubs 'SLUICE_REQUIRE_SIGNED=' 1
  assert_output --partial "could not verify"     # the warn path
  assert_output --partial "image build failed"   # proceeded to the (stub) build, which then fails
}

@test "signed-base: REQUIRE_SIGNED=1 with a non-official (mirror) base REFUSES (no silent no-op)" {
  # An off-pattern ref (ECR/Harbor mirror) carries no signature sluice can verify; REQUIRE_SIGNED must
  # die, not pass verification by skipping it. cosign stub would succeed - the ref, not cosign, gates.
  W="$(mktemp -d)"; mkdir -p "$W/bin" "$W/p"
  printf '#!/bin/sh\nexit 1\n' > "$W/bin/docker"
  printf '#!/bin/sh\nexit 0\n' > "$W/bin/cosign"
  chmod +x "$W/bin/docker" "$W/bin/cosign"
  printf 'SLUICE_NAME="sb"\nSLUICE_BASE_IMAGE="registry.example.com/mirror/sluice-base:1"\nSLUICE_REQUIRE_SIGNED=1\nSLUICE_RUN_CMD="true"\n' > "$W/p/sluice.config.sh"
  run bash -c "cd '$W/p' && PATH='$W/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' build 2>&1"
  assert_failure
  assert_output --partial "not the official signed base"
  refute_output --partial "image build failed"   # died before the build
}

# verify + FROM must pin the same DIGEST, not the tag (verify-tag / build-tag TOCTOU). resolve_base_digest
# is the primitive; extract it and drive it with a stub engine.
@test "signed-base: resolve_base_digest passes an already-pinned @sha256 ref through unchanged" {
  eval "$(sed -n '/^resolve_base_digest()/,/^}/p' "$ROOT/bin/sluice")"
  run resolve_base_digest "ghcr.io/x/sluice-base@sha256:abc123"
  assert_output "ghcr.io/x/sluice-base@sha256:abc123"
}

@test "signed-base: resolve_base_digest resolves a tag to its RepoDigest" {
  eval "$(sed -n '/^resolve_base_digest()/,/^}/p' "$ROOT/bin/sluice")"
  ENGINE=eng
  eng() { case "$*" in *"image inspect"*) printf 'ghcr.io/x/sluice-base@sha256:deadbeef\n' ;; *) return 0 ;; esac; }
  run resolve_base_digest "ghcr.io/x/sluice-base:latest"
  assert_output "ghcr.io/x/sluice-base@sha256:deadbeef"
}

@test "signed-base: resolve_base_digest falls back to the tag when the image has no RepoDigest" {
  eval "$(sed -n '/^resolve_base_digest()/,/^}/p' "$ROOT/bin/sluice")"
  ENGINE=eng; eng() { return 0; }   # inspect yields nothing (local-only image)
  run resolve_base_digest "local/img:tag"
  assert_output "local/img:tag"
}
