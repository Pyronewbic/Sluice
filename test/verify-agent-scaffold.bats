#!/usr/bin/env bats
# `sluice agent <name>` scaffolding (no engine: a stub docker that always fails sits first on PATH,
# so the flow dies at the image build AFTER the config is written - the writes are what's tested).
load test_helper/common

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/proj"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/docker"
  chmod +x "$WORK/bin/docker"
}
teardown() { rm -rf "$WORK"; }

# Run `sluice agent <name>` in $WORK/proj behind the stub engine; the build die is expected.
_agent() { run bash -c "cd '$WORK/proj' && PATH='$WORK/bin:$PATH' SLUICE_ENGINE=docker '$SLUICE' agent $1 2>&1"; }

@test "agent scaffold: python repo unions pypi hosts into the preset allowlist" {
  printf 'fastapi\n' > "$WORK/proj/requirements.txt"
  _agent claude
  run grep -E '^SLUICE_ALLOW_DOMAINS=' "$WORK/proj/sluice.config.sh"
  assert_output --partial "api.anthropic.com"
  assert_output --partial "pypi.org"
  assert_output --partial "files.pythonhosted.org"
  run grep -c '^SLUICE_ALLOW_DOMAINS=' "$WORK/proj/sluice.config.sh"
  assert_output "1"
  run grep '# from stack detection' "$WORK/proj/sluice.config.sh"
  assert_output --partial "python"
}

@test "agent scaffold: yarn repo adds registry.yarnpkg.com, labeled node/yarn" {
  printf '{"name":"x"}\n' > "$WORK/proj/package.json"
  : > "$WORK/proj/yarn.lock"
  _agent claude
  run grep -E '^SLUICE_ALLOW_DOMAINS=' "$WORK/proj/sluice.config.sh"
  assert_output --partial "registry.yarnpkg.com"
  run grep '# from stack detection' "$WORK/proj/sluice.config.sh"
  assert_output --partial "node/yarn"
}

@test "agent scaffold: go repo adds the proxy hosts even with a lockfile (no prefetch at agent runtime)" {
  printf 'module x\ngo 1.22\n' > "$WORK/proj/go.mod"
  : > "$WORK/proj/go.sum"
  _agent claude
  run grep -E '^SLUICE_ALLOW_DOMAINS=' "$WORK/proj/sluice.config.sh"
  assert_output --partial "proxy.golang.org"
  assert_output --partial "sum.golang.org"
}

@test "agent scaffold: no recognized stack -> config is the preset verbatim" {
  _agent claude
  run cmp -s "$WORK/proj/sluice.config.sh" "$ROOT/agents/claude.config.sh"
  assert_success
  run grep '# from stack detection' "$WORK/proj/sluice.config.sh"
  assert_failure
}

@test "agent scaffold: the preset's default SLUICE_MASK survives the scaffold" {
  printf 'fastapi\n' > "$WORK/proj/requirements.txt"
  _agent claude
  run grep '^SLUICE_MASK=' "$WORK/proj/sluice.config.sh"
  assert_output 'SLUICE_MASK=".env*"'
}

@test "agent scaffold: cross-agent note still fires on a stack-edited config" {
  printf 'fastapi\n' > "$WORK/proj/requirements.txt"
  _agent claude
  _agent codex
  assert_output --partial "set up for the 'claude' agent"
}

@test "agent scaffold: preset files themselves stay tool-only (repo check)" {
  run grep -l 'from stack detection' "$ROOT"/agents/*.config.sh
  assert_failure
}

# PR6 #3: the gemini preset allowlists only generativelanguage.googleapis.com (the AI Studio /
# USE_GEMINI path). gemini-cli reads GOOGLE_API_KEY only under USE_VERTEX_AI - a different, non-
# allowlisted endpoint - so forwarding it is inert and misleading (`sluice agent` would show it set).
# Source the preset and assert SLUICE_ENV carries GEMINI_API_KEY but NOT GOOGLE_API_KEY.
@test "agent preset: gemini forwards GEMINI_API_KEY only, not the inert GOOGLE_API_KEY" {
  run sh -c '. "$1"; printf "%s" "$SLUICE_ENV"' _ "$ROOT/agents/gemini.config.sh"
  assert_success
  assert_output --partial "GEMINI_API_KEY"
  refute_output --partial "GOOGLE_API_KEY"
}
