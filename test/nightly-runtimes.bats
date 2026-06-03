#!/usr/bin/env bats
# Build-smoke each runtime fixture (build -> serve -> curl from INSIDE its own container, deps pulled
# through the proxy). Ported from verify-runtimes.sh: each fixture is now a self-contained @test, so
# `bats --jobs N` parallelizes them (replacing the old hand-rolled job pool) and a failure points at
# the exact runtime. No host ports are published (SLUICE_PORTS="" ), so parallel fixtures never clash.
# Heavy - nightly, not the PR gate. RUNTIMES="node go" subsets via the _want guard.
load test_helper/common

# run only if RUNTIMES is empty (all) or names this fixture.
_want() { [ -z "${RUNTIMES:-}" ] && return 0; case " ${RUNTIMES} " in *" $1 "*) return 0;; *) return 1;; esac; }

# build + serve the fixture, curl it in-container; return 0 iff it serves HTTP 200. Cleans up its box.
_smoke_runtime() {
  local name="$1" c="sluice-$1" src port work code attempt log="$BATS_TEST_TMPDIR/$1.log"
  src="$ROOT/test/fixtures/$name"
  [ -f "$src/sluice.config.sh" ] || { echo "missing fixture: $name"; return 1; }
  port="$(grep -E '^SLUICE_PORTS=' "$src/sluice.config.sh" | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
  [ -n "$port" ] || { echo "no SLUICE_PORTS in $name config"; return 1; }
  code=000
  for attempt in 1 2; do   # retry once: the dep-fetch through the proxy is an occasional CDN/CI flake
    work="$(mktemp -d)/$name"; mkdir -p "$work"; cp -R "$src"/. "$work/"
    printf '\nSLUICE_PORTS=""\n' >> "$work/sluice.config.sh"   # don't publish a host port (parallel-safe)
    if ( cd "$work" && "$SLUICE" build ) >>"$log" 2>&1; then
      ( cd "$work" && "$SLUICE" ) >>"$log" 2>&1 &   # serve in the background (idle box + RUN_CMD)
      code=000
      local _i
      for _i in $(seq 1 180); do
        code="$("$ENG" exec "$c" curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/" 2>/dev/null || echo 000)"
        [ "$code" = 200 ] && break; sleep 1
      done
    else
      code=build
    fi
    "$ENG" exec --user root "$c" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
    ( cd "$work" && "$SLUICE" stop ) >>"$log" 2>&1 || true
    rm -rf "$(dirname "$work")" 2>/dev/null || true
    [ "$code" = 200 ] && break
  done
  [ "$code" = 200 ] || { echo "serve failed for $name (got $code); see $log"; cat "$log" >&3 2>/dev/null || true; return 1; }
}

@test "runtime: node serves 200 in-container (deps via proxy)"   { _want node   || skip "not in RUNTIMES"; _smoke_runtime node; }
@test "runtime: python serves 200 in-container (deps via proxy)" { _want python || skip "not in RUNTIMES"; _smoke_runtime python; }
@test "runtime: deno serves 200 in-container (deps via proxy)"   { _want deno   || skip "not in RUNTIMES"; _smoke_runtime deno; }
@test "runtime: ruby serves 200 in-container (deps via proxy)"   { _want ruby   || skip "not in RUNTIMES"; _smoke_runtime ruby; }
@test "runtime: rust serves 200 in-container (deps via proxy)"   { _want rust   || skip "not in RUNTIMES"; _smoke_runtime rust; }
@test "runtime: go serves 200 in-container (deps via proxy)"     { _want go     || skip "not in RUNTIMES"; _smoke_runtime go; }
@test "runtime: bun serves 200 in-container (deps via proxy)"    { _want bun    || skip "not in RUNTIMES"; _smoke_runtime bun; }
@test "runtime: poetry serves 200 in-container (deps via proxy)" { _want poetry || skip "not in RUNTIMES"; _smoke_runtime poetry; }
@test "runtime: uv serves 200 in-container (deps via proxy)"     { _want uv     || skip "not in RUNTIMES"; _smoke_runtime uv; }
# F2: deps fetched at BUILD (go mod download); serves with GOPROXY=off and NO go-proxy in the allowlist.
@test "runtime: go-prefetch serves 200 offline (F2: deps baked at build, registry blocked)" { _want go-prefetch || skip "not in RUNTIMES"; _smoke_runtime go-prefetch; }

# Kata micro-VM smoke (SLUICE_RUNTIME=kata): only on a host with a usable nerdctl + the Kata shim;
# proves sluice's firewall/squid stack comes up UNCHANGED under an own-kernel runtime.
@test "runtime: kata micro-VM (own kernel + egress firewall intact)" {
  command -v nerdctl >/dev/null 2>&1 && command -v containerd-shim-kata-v2 >/dev/null 2>&1 && nerdctl info >/dev/null 2>&1 \
    || skip "no usable nerdctl + Kata shim on this host"
  local kwork hk gk nk
  kwork="$(mktemp -d)/kata"; mkdir -p "$kwork"
  printf 'SLUICE_NAME="kata-smoke"\nSLUICE_RUN_CMD="true"\n' > "$kwork/sluice.config.sh"
  ( cd "$kwork" && "$SLUICE" build ) >"$BATS_TEST_TMPDIR/kata.log" 2>&1
  hk="$(uname -r)"
  gk="$( cd "$kwork" && SLUICE_RUNTIME=kata "$SLUICE" run sh -lc 'uname -r' 2>/dev/null | tr -d '[:space:]' )"
  [ -n "$gk" ] && [ "$gk" != "$hk" ] || { echo "guest kernel '$gk' not distinct from host '$hk'"; false; }
  nk="$( cd "$kwork" && SLUICE_RUNTIME=kata "$SLUICE" run sh -lc 'curl -sS -o /dev/null -w %{http_code} --max-time 25 https://registry.npmjs.org/ 2>/dev/null' 2>/dev/null )"
  [ "$nk" = 200 ] || { echo "allowlisted host not reachable under Kata (got '$nk')"; false; }
  ! ( cd "$kwork" && SLUICE_RUNTIME=kata "$SLUICE" run sh -lc 'curl -sS -o /dev/null --max-time 12 https://example.com 2>/dev/null' ) >/dev/null 2>&1
  ( cd "$kwork" && SLUICE_RUNTIME=kata "$SLUICE" rm ) >/dev/null 2>&1 || true
  rm -rf "$(dirname "$kwork")" 2>/dev/null || true
}
