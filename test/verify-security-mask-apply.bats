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
