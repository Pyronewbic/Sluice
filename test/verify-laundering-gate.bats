#!/usr/bin/env bats
# Laundering-host gate: an allowlisted host an attacker can also write to (S3/gists/pastebins/LLM
# APIs) lets data leak out even though it's allowlisted (we splice, never decrypt). The gate runs at
# session start, BEFORE any engine call, so these are fast + Docker-free: SLUICE_ENGINE=false makes
# the (irrelevant) build fail instantly while we assert on the gate's own stderr.
load test_helper/common

setup() { WORK="$(mktemp -d)"; mkdir -p "$WORK/p"; }
teardown() { rm -rf "$WORK"; }

cfg() { printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS="gist.github.com"\n%b\nSLUICE_RUN_CMD="true"\n' "$1" > "$WORK/p/sluice.config.sh"; }

@test "laundering: strict mode refuses a write-capable allowlisted host (no build)" {
  cfg 'SLUICE_STRICT_LAUNDERING=1'
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_failure
  assert_output --partial "refusing"
  assert_output --partial "gist.github.com"
}

@test "laundering: plain mode warns (non-fatal) and names the host" {
  cfg ''
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  assert_output --partial "gist.github.com"
  refute_output --partial "refusing"
}

@test "laundering: SLUICE_LAUNDERING_OK=1 acknowledges and silences" {
  cfg 'SLUICE_STRICT_LAUNDERING=1\nSLUICE_LAUNDERING_OK=1'
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  refute_output --partial "laundered"
  refute_output --partial "refusing"
}

@test "laundering: raw.githubusercontent.com is flagged (write-capable via any repo)" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS="raw.githubusercontent.com"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  assert_output --partial "raw.githubusercontent.com"
  refute_output --partial "refusing"
}

@test "laundering: a non-laundering allowlist is silent" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS="api.example.com"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  refute_output --partial "laundered"
  refute_output --partial "refusing"
}

# A PARENT wildcard `sluice learn` can write by collapsing a non-storage sibling (e.g. play.googleapis.com)
# covers storage.googleapis.com - a cloud-storage exfil host - so it must trip the gate, not slip past.
@test "laundering: parent wildcard .googleapis.com is flagged (covers storage.googleapis.com)" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS=".googleapis.com"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  assert_output --partial ".googleapis.com"
  refute_output --partial "refusing"
}

@test "laundering: strict mode refuses the covering wildcard .googleapis.com" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS=".googleapis.com"\nSLUICE_STRICT_LAUNDERING=1\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_failure
  assert_output --partial "refusing"
  assert_output --partial ".googleapis.com"
}

@test "laundering: parent wildcard .amazonaws.com is flagged (covers s3.amazonaws.com)" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS=".amazonaws.com"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  refute_output --partial "refusing"
}

# Precision guard: the bare apex (exact host, no leading dot) matches ONLY googleapis.com itself in squid
# dstdomain - it cannot reach storage.googleapis.com - so it must NOT be over-flagged as a launderer.
@test "laundering: bare apex googleapis.com (exact, no subdomains) is NOT flagged" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS="googleapis.com"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  refute_output --partial "laundered"
  refute_output --partial "refusing"
}

# The shipped cursor/amp/qwen/crush presets allow a model/agent-stream host that accepts POST bodies -
# a laundering surface just like api.anthropic.com, so their users must get the same session-start nudge.
@test "laundering: cursor/amp/qwen/crush model-stream hosts are flagged" {
  local h
  for h in ampcode.com dashscope-intl.aliyuncs.com dashscope.aliyuncs.com api2.cursor.sh catwalk.charm.land; do
    printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS="%s"\nSLUICE_RUN_CMD="true"\n' "$h" > "$WORK/p/sluice.config.sh"
    run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
    assert_output --partial "laundered"
    assert_output --partial "$h"
  done
}

@test "laundering: cursor's .api5.cursor.sh leading-dot wildcard is flagged" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS=".api5.cursor.sh"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  assert_output --partial ".api5.cursor.sh"
}

# The shipped plandex preset allowlists api-v2.plandex.ai (Plandex Cloud's model-proxy backend) - a
# POST-capable stream host of the same class as the cursor/amp/crush hosts, so plandex users get the nudge.
@test "laundering: plandex's api-v2.plandex.ai model-proxy host is flagged" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS="api-v2.plandex.ai"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  assert_output --partial "api-v2.plandex.ai"
}

@test "laundering: a .plandex.ai parent wildcard covering api-v2.plandex.ai is flagged" {
  printf 'SLUICE_NAME="sectest-laundering"\nSLUICE_ALLOW_DOMAINS=".plandex.ai"\nSLUICE_RUN_CMD="true"\n' > "$WORK/p/sluice.config.sh"
  run bash -c "cd '$WORK/p' && SLUICE_ENGINE=false '$SLUICE' run true"
  assert_output --partial "laundered"
  assert_output --partial ".plandex.ai"
}
