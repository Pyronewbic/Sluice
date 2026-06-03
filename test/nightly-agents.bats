#!/usr/bin/env bats
# Each coding-agent preset, verified as far as possible WITHOUT credentials (one @test per preset):
# the CLI binary installs from its npm package + lands on PATH, every declared API host is reachable
# through the proxy, a non-allowlisted host is blocked, and the auth env var is forwarded. If a real
# key is set on the host, it also probes a live round-trip and greps the proxy log for the API tunnel.
# Heavy (real agent CLIs) - nightly/manual, not the PR gate. AGENTS="claude codex" subsets.
load test_helper/common

_want() { [ -z "${AGENTS:-}" ] && return 0; case " ${AGENTS} " in *" $1 "*) return 0;; *) return 1;; esac; }

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
    *)        echo '' ;;
  esac
}

_agent_teardown() {
  host_own "$1" "$2"
  ( cd "$2" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  rm -rf "$(dirname "$2")" 2>/dev/null || true
}

_verify_agent() {
  local name="$1" preset="$ROOT/agents/$1.config.sh" work c bin hosts envvars firstvar h code got
  [ -f "$preset" ] || { echo "no preset for $name"; return 1; }
  bin="$(. "$preset"; printf '%s' "${SLUICE_RUN_CMD%% *}")"
  hosts="$(. "$preset"; printf '%s' "${SLUICE_ALLOW_DOMAINS:-}")"
  envvars="$(. "$preset"; printf '%s' "${SLUICE_ENV:-}")"
  firstvar="${envvars%% *}"
  work="$(mktemp -d)/$name"; mkdir -p "$work"; cp "$preset" "$work/sluice.config.sh"
  c="sluice-$name"

  ( cd "$work" && "$SLUICE" build ) >"$BATS_TEST_TMPDIR/$name.log" 2>&1 \
    || { echo "build failed for $name"; cat "$BATS_TEST_TMPDIR/$name.log" >&3 2>/dev/null || true; rm -rf "$(dirname "$work")"; return 1; }

  # 1. the CLI binary installed from the npm package + is on PATH
  ( cd "$work" && "$SLUICE" run sh -lc "command -v $bin >/dev/null" ) >/dev/null 2>&1 \
    || { echo "$bin NOT on PATH after installing the preset's npm package"; _agent_teardown "$c" "$work"; return 1; }

  # 2. every declared API host is reachable through the proxy
  for h in $hosts; do
    code="$( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 https://$h" 2>/dev/null )"
    { [ -n "$code" ] && [ "$code" != 000 ]; } || { echo "allow $h UNREACHABLE (got '$code')"; _agent_teardown "$c" "$work"; return 1; }
  done

  # 3. a non-allowlisted host is blocked
  if ( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null --max-time 8 https://example.com" ) >/dev/null 2>&1; then
    echo "deny example.com NOT blocked"; _agent_teardown "$c" "$work"; return 1
  fi

  # 4. the auth env var is forwarded into the box
  if [ -n "$firstvar" ]; then
    got="$( cd "$work" && env "$firstvar=__sluice_sentinel__" "$SLUICE" run printenv "$firstvar" 2>/dev/null | tr -d '[:space:]' )"
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

@test "agent: claude preset (cred-free + optional live)"   { _want claude   || skip "not in AGENTS"; _verify_agent claude; }
@test "agent: codex preset (cred-free + optional live)"    { _want codex    || skip "not in AGENTS"; _verify_agent codex; }
@test "agent: gemini preset (cred-free + optional live)"   { _want gemini   || skip "not in AGENTS"; _verify_agent gemini; }
@test "agent: aider preset (cred-free + optional live)"    { _want aider    || skip "not in AGENTS"; _verify_agent aider; }
@test "agent: cursor preset (cred-free + optional live)"   { _want cursor   || skip "not in AGENTS"; _verify_agent cursor; }
@test "agent: opencode preset (cred-free + optional live)" { _want opencode || skip "not in AGENTS"; _verify_agent opencode; }
@test "agent: amp preset (cred-free + optional live)"      { _want amp      || skip "not in AGENTS"; _verify_agent amp; }
@test "agent: qwen preset (cred-free + optional live)"     { _want qwen     || skip "not in AGENTS"; _verify_agent qwen; }
@test "agent: crush preset (cred-free + optional live)"    { _want crush    || skip "not in AGENTS"; _verify_agent crush; }
