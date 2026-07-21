#!/usr/bin/env bats
# Each coding-agent preset, verified as far as possible WITHOUT credentials (one @test per preset):
# the CLI binary installs from its npm package + lands on PATH, every declared API host is reachable
# through the proxy, a non-allowlisted host is blocked, and the auth env var is forwarded. If a real
# key is set on the host, it also probes a live round-trip and greps the proxy log for the API tunnel.
# Heavy (real agent CLIs) - nightly/manual, not the PR gate. AGENTS="claude codex" subsets.
load test_helper/common

_want() { [ -z "${AGENTS:-}" ] && return 0; case " ${AGENTS} " in *" $1 "*) return 0;; *) return 1;; esac; }

# The agent binary out of a preset's SLUICE_RUN_CMD. Not `${cmd%% *}`: a preset may carry a shell
# prelude (`export PATH=...; aider ...`) or an env prefix (`PLANDEX_SKIP_UPGRADE=1 plandex ...`), and
# taking the first word yielded `export` / `PLANDEX_SKIP_UPGRADE=1` - the former silently PASSES the
# on-PATH check (a shell builtin), so aider/qwen were never really probed. Drop everything up to the
# last `;`, then skip leading VAR=VAL assignments.
_run_bin() {
  local c="${1##*;}" tok IFS=$' \t\n'   # pin IFS: word-splitting here must not follow the caller's
  for tok in $c; do
    case "$tok" in
      *=*) ;;                                  # env assignment prefix - keep looking
      *) printf '%s' "$tok"; return 0 ;;
    esac
  done
  printf '%s' "${c%% *}"
}

# best-guess non-interactive invocation per agent (override with <NAME>_PROBE).
_agent_probe() {
  case "$1" in
    cursor)   echo 'cursor-agent --force -p "reply with the single word OK"' ;;
    amp)      echo 'echo "reply with the single word OK" | amp -x' ;;
    opencode) echo 'opencode run "reply with the single word OK"' ;;
    claude)   echo 'claude --dangerously-skip-permissions -p "reply with the single word OK"' ;;
    codex)    echo 'codex exec "reply with the single word OK"' ;;
    gemini)   echo 'gemini -p "reply with the single word OK"' ;;
    aider)    echo 'aider --yes-always --no-auto-commits --message "reply with OK"' ;;
    qwen)     echo 'qwen --yolo -p "reply with the single word OK"' ;;
    crush)    echo 'crush run --yolo "reply with the single word OK"' ;;
    # plandex has no entry on purpose: Cloud auth is an in-terminal email-pin sign-in that cannot
    # complete headless, so there is no cred-gated round-trip to probe (steps 1-4 still run). An empty
    # probe skips step 5 rather than failing it.
    *)        echo '' ;;
  esac
}

_agent_teardown() {
  host_own "$1" "$2"
  ( cd "$2" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  rm -rf "$(dirname "$2")" 2>/dev/null || true
}

_verify_agent() {
  local name="$1" preset="$ROOT/agents/$1.config.sh" work c bin hosts envvars firstvar h nc got
  [ -f "$preset" ] || { echo "no preset for $name"; return 1; }
  bin="$(. "$preset"; _run_bin "$SLUICE_RUN_CMD")"
  hosts="$(. "$preset"; printf '%s' "${SLUICE_ALLOW_DOMAINS:-}")"
  envvars="$(. "$preset"; printf '%s' "${SLUICE_ENV:-}")"
  firstvar="${envvars%% *}"
  work="$(mktemp -d)/$name"; mkdir -p "$work"; cp "$preset" "$work/sluice.config.sh"
  c="sluice-$name"

  # SLUICE_BUILD_RETRIES rides over the npm-registry TLS-reset flake at build; a real break still fails.
  ( cd "$work" && SLUICE_BUILD_RETRIES=2 "$SLUICE" build ) >"$BATS_TEST_TMPDIR/$name.log" 2>&1 \
    || { echo "build failed for $name"; cat "$BATS_TEST_TMPDIR/$name.log" >&3 2>/dev/null || true; rm -rf "$(dirname "$work")"; return 1; }

  # 1. the CLI binary installed from the npm package + is on PATH
  ( cd "$work" && "$SLUICE" run sh -lc "command -v $bin >/dev/null" ) >/dev/null 2>&1 \
    || { echo "$bin NOT on PATH after installing the preset's npm package"; _agent_teardown "$c" "$work"; return 1; }

  # 2. every declared API host is reachable through the proxy.
  #    Reachable == a connection was established (num_connects>=1): DNS resolved AND the TCP/TLS
  #    handshake completed at least once. We key off %{num_connects}, NOT the HTTP code: telemetry /
  #    worker / statsig backends complete TLS but answer a bare unauthenticated GET with no body (curl
  #    exit 52, http 000) - that host IS reachable. NXDOMAIN / refused / timeout leave num_connects=0
  #    (curl exit 6/7/28) and MUST still fail - that drift is exactly what this test exists to catch.
  #    A leading-dot wildcard entry (.x.y) names a zone, not a host: its apex is usually NXDOMAIN (only
  #    *.x.y resolves), so there is no well-defined apex to GET - we strip the dot then skip the literal
  #    probe. The wildcard's egress is still covered by squid dstdomain (egress-helpers units) + the
  #    cred-gated live probe in step 5 (which greps the proxy log for ssl_sni over a real subdomain).
  for h in $hosts; do
    case "$h" in .*) continue ;; esac   # wildcard: strip leaves no probeable apex host
    h="${h#.}"                          # (defensive) drop a leading dot before interpolating into the URL
    # `|| true`: the harness runs under errexit, so a connect failure (curl exit 6/7/28) or a no-body
    # TLS connect (52) must NOT abort the test - let it fall through to the UNREACHABLE handler below
    # so the drifted host is named (was a bare "failed with status 6" that hid which host drifted).
    nc="$( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{num_connects}' --max-time 12 https://$h" 2>/dev/null || true )"
    { [ -n "$nc" ] && [ "$nc" != 0 ]; } || { echo "allow $h UNREACHABLE (num_connects='$nc')"; _agent_teardown "$c" "$work"; return 1; }
  done

  # 3. a non-allowlisted host is blocked
  if ( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null --max-time 8 https://example.com" ) >/dev/null 2>&1; then
    echo "deny example.com NOT blocked"; _agent_teardown "$c" "$work"; return 1
  fi

  # 4. the auth env var is forwarded into the box
  if [ -n "$firstvar" ]; then
    got="$( cd "$work" && env "$firstvar=__sluice_sentinel__" "$SLUICE" run printenv "$firstvar" 2>/dev/null | tr -d '[:space:]' || true )"   # || true: errexit-safe so the handler below names a forwarding failure
    [ "$got" = "__sluice_sentinel__" ] || { echo "\$$firstvar NOT forwarded (got '$got')"; _agent_teardown "$c" "$work"; return 1; }
  fi

  # 5. (cred-gated) live round-trip - only if a real auth var is set on the host
  local realset=0 v ov pc log reached
  for v in $envvars; do [ -n "${!v:-}" ] && realset=1; done
  if [ "$realset" = 1 ]; then
    ov="$(echo "$name" | tr '[:lower:]' '[:upper:]')_PROBE"; pc="${!ov:-$(_agent_probe "$name")}"
    if [ -n "$pc" ]; then
      ( cd "$work" && "$SLUICE" run sh -lc "timeout 45 $pc" ) >"$BATS_TEST_TMPDIR/$name-probe.log" 2>&1 || true
      log="$("$ENG" exec "$c" sh -c 'cat /var/log/squid/access.log' 2>/dev/null)"
      reached=""; for h in $hosts; do printf '%s' "$log" | grep -q "TCP_TUNNEL/200.*ssl_sni=$h" && { reached="$h"; break; }; done
      [ -n "$reached" ] || { echo "live probe ran but no API tunnel in the proxy log (see $BATS_TEST_TMPDIR/$name-probe.log)"; _agent_teardown "$c" "$work"; return 1; }
    fi
  fi

  _agent_teardown "$c" "$work"
}

# `sluice agent` listing reports (set) when ANY of a preset's SLUICE_ENV vars is set, not just the
# first (B6): claude accepts ANTHROPIC_API_KEY OR CLAUDE_CODE_OAUTH_TOKEN.
@test "agent: listing shows (set) for a non-first auth var" {
  run env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN=demo "$SLUICE" agent
  assert_output --partial "CLAUDE_CODE_OAUTH_TOKEN (set)"   # claude's row, only its second var
}
@test "agent: listing shows (unset) for the first var when none is set" {
  run env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN "$SLUICE" agent
  assert_output --partial "ANTHROPIC_API_KEY (unset)"
}

@test "agent: claude preset (cred-free + optional live)"   { _want claude   || skip "not in AGENTS"; _verify_agent claude; }
@test "agent: codex preset (cred-free + optional live)"    { _want codex    || skip "not in AGENTS"; _verify_agent codex; }
@test "agent: gemini preset (cred-free + optional live)"   { _want gemini   || skip "not in AGENTS"; _verify_agent gemini; }
@test "agent: aider preset (cred-free + optional live)"    { _want aider    || skip "not in AGENTS"; _verify_agent aider; }
@test "agent: cursor preset (cred-free + optional live)"   { _want cursor   || skip "not in AGENTS"; _verify_agent cursor; }
@test "agent: opencode preset (cred-free + optional live)" { _want opencode || skip "not in AGENTS"; _verify_agent opencode; }
@test "agent: amp preset (cred-free + optional live)"      { _want amp      || skip "not in AGENTS"; _verify_agent amp; }
@test "agent: qwen preset (cred-free + optional live)"     { _want qwen     || skip "not in AGENTS"; _verify_agent qwen; }
@test "agent: crush preset (cred-free + optional live)"    { _want crush    || skip "not in AGENTS"; _verify_agent crush; }
@test "agent: plandex preset (cred-free)"                  { _want plandex  || skip "not in AGENTS"; _verify_agent plandex; }
