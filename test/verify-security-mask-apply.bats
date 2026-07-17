#!/usr/bin/env bats
# Overlay + SLUICE_MASK + `sluice apply`: the masked file is an empty read-only bind in the box, so a
# naive write-back would tar that 0-byte file over the host's REAL secret and truncate it (invisibly -
# diff shows it unchanged). apply must exclude every mask match; the legit edit still applies.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ws"
  printf 'SLUICE_NAME="sectest-maskapply"\nSLUICE_WORKSPACE=overlay\nSLUICE_RUN_CMD="bash"\nSLUICE_MASK=".env"\n' > "$WORK/ws/sluice.config.sh"
  printf 'SECRET=super-real-value\n' > "$WORK/ws/.env"
  echo v1 > "$WORK/ws/app.txt"
  # box edits app.txt in the writable copy (never touches the masked .env)
  ( cd "$WORK/ws" && "$SLUICE" run sh -c 'echo v2 > app.txt' ) >/dev/null 2>&1 || true
  ( cd "$WORK/ws" && SLUICE_YES=1 "$SLUICE" apply ) >/dev/null 2>&1 || true
}

teardown_file() { destroy_box maskapply ws; }

@test "mask-apply: the host secret is preserved, not truncated to 0 bytes" {
  [ -s "$WORK/ws/.env" ]
  grep -q "SECRET=super-real-value" "$WORK/ws/.env"
}

@test "mask-apply: the legit edit still applied" {
  grep -q v2 "$WORK/ws/app.txt"
}


# --- coverage gaps surfaced by the test-case review (changed-behavior edge/bad paths) ---
@test "mask-apply: a mask glob matching a DIRECTORY is excluded (host dir contents survive apply)" {
  mkdir -p "$WORK/wsd/secrets"
  printf 'SLUICE_NAME="sectest-maskdir"\nSLUICE_WORKSPACE=overlay\nSLUICE_RUN_CMD="bash"\nSLUICE_MASK="secrets"\n' > "$WORK/wsd/sluice.config.sh"
  printf 'API_KEY=real-dir-secret\n' > "$WORK/wsd/secrets/key.txt"
  echo v1 > "$WORK/wsd/app.txt"
  # box sees secrets/ as an empty tmpfs; it edits only app.txt in the writable copy
  ( cd "$WORK/wsd" && "$SLUICE" run sh -c 'echo v2 > app.txt' ) >/dev/null 2>&1 || true
  ( cd "$WORK/wsd" && SLUICE_YES=1 "$SLUICE" apply ) >/dev/null 2>&1 || true
  # the masked directory's real contents are intact - not truncated or removed by the write-back
  [ -s "$WORK/wsd/secrets/key.txt" ]
  grep -q "API_KEY=real-dir-secret" "$WORK/wsd/secrets/key.txt"
  grep -q v2 "$WORK/wsd/app.txt"   # the legit edit still applied
  destroy_box maskdir wsd
}
