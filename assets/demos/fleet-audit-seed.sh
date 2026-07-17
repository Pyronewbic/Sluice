#!/bin/bash
# Seed a synthetic-but-byte-valid fleet of egress hash-chains for the fleet-audit demo, WITHOUT a
# container engine. Each record uses sluice's exact _persist_receipt shape (src/80-learn.sh) and
# sluice's own _sha256 (sed-sourced from bin/sluice), so `sluice egress --verify --all` recomputes and
# chains every line for real - the green "intact" is a genuine re-hash, not a claim. The chains live in
# an ISOLATED XDG_STATE_HOME, so the demo never sees (or touches) your real boxes. No box, no config, no
# engine => the purest orphan case the fleet audit is built for. Run from repo root; then vhs the tape.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="${XDG_STATE_HOME:-$ROOT/.demos/fleet-audit/state}/sluice"
# sluice's exact hasher (portable sha256sum||shasum), sourced verbatim from the built launcher.
eval "$(grep -m1 '^_sha256()' "$ROOT/bin/sluice")"

emit_box() {   # $1=slug  $2=host  $3=allowlist-json  $4=n-records
  local slug="$1" host="$2" allow="$3" n="$4" log dir i prev inner payload self bytes ts
  dir="$STATE/$slug"; log="$dir/egress-log.jsonl"
  mkdir -p "$dir"; : > "$log"
  prev="0000000000000000000000000000000000000000000000000000000000000000"
  i=1
  while [ "$i" -le "$n" ]; do
    bytes=$(( 1024 * i + 512 ))
    ts="2026-07-1${i}T09:0${i}:00Z"
    inner="\"schema\":\"sluice.egress/v1\",\"run\":\"${ts}-$((1000+i))\",\"ts\":\"${ts}\",\"box\":\"sluice-${slug}\",\"status\":\"ok\",\"confighash\":\"seed\",\"allowlist\":${allow},\"totals\":{\"reached\":1,\"blocked\":0,\"bytes\":${bytes}},\"hosts\":[{\"host\":\"${host}\",\"class\":\"reached\",\"requests\":1,\"bytes\":${bytes}}],\"fw_dropped\":{\"packets\":0,\"bytes\":0},\"denied_ip_requests\":0"
    payload="{${inner},\"prev\":\"${prev}\"}"
    self="$(printf '%s' "$payload" | _sha256)"
    printf '%s\n' "{${inner},\"prev\":\"${prev}\",\"self\":\"${self}\"}" >> "$log"
    prev="$self"
    i=$((i+1))
  done
  echo "seeded $slug ($n record(s)) -> $log"
}

rm -rf "$STATE"
emit_box api-gateway    api.github.com        '["api.github.com","github.com"]'                3
emit_box billing-worker registry.npmjs.org    '["registry.npmjs.org"]'                         2
emit_box web-frontend   registry.yarnpkg.com  '["registry.yarnpkg.com","registry.npmjs.org"]'  2
