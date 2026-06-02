#!/usr/bin/env bash
# Verify each coding-agent preset as far as possible WITHOUT credentials (the live API round-trip is
# the only cred-gated step). Per preset, cred-free: the CLI binary installs from its npm package and
# runs, every declared API host is reachable through the proxy, a non-allowlisted host is blocked,
# the auth env var is forwarded. With a real key set, also probes a live call + greps the proxy log
# for the API tunnel. Heavy (real agent CLIs) - nightly/manual, not the PR gate.
#
#   ./test/verify-agents.sh                                     # all presets (cred-free)
#   AGENTS=claude CURSOR_API_KEY=... ./test/verify-agents.sh    # one preset + a live round-trip
set -u

. "$(dirname "$0")/lib.sh"

# Best-guess non-interactive invocation per agent (this spelling is the genuinely-unverified
# bit; the proxy-log check below is what actually confirms the round-trip). Override per agent
# with <NAME>_PROBE (e.g. CURSOR_PROBE='cursor-agent ...').
probe_cmd() {
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

AGENTS="${AGENTS:-claude codex gemini aider cursor opencode amp qwen crush}"

echo "== sluice agent preset verification (cred-free + optional live probe) =="
for name in $AGENTS; do
  preset="$ROOT/agents/$name.config.sh"
  [ -f "$preset" ] || { bad "$name: no preset"; continue; }
  echo "-- $name --"
  bin="$(. "$preset"; printf '%s' "${SLUICE_RUN_CMD%% *}")"
  hosts="$(. "$preset"; printf '%s' "${SLUICE_ALLOW_DOMAINS:-}")"
  envvars="$(. "$preset"; printf '%s' "${SLUICE_ENV:-}")"
  firstvar="${envvars%% *}"
  echo "    bin=$bin  api=[${hosts}]  auth=[${envvars}]"

  work="$(mktemp -d)/$name"; mkdir -p "$work"; cp "$preset" "$work/sluice.config.sh"
  container="sluice-$name"
  if ! ( cd "$work" && "$SLUICE" build ) >"/tmp/verify-agent-$name.log" 2>&1; then
    bad "$name: build failed (npm package '$(. "$preset"; printf '%s' "${SLUICE_EXTRA_NPM:-}")'?)"
    tail -20 "/tmp/verify-agent-$name.log"; rm -rf "$(dirname "$work")"; continue
  fi

  # 1. The CLI binary actually installs from the npm package and runs.
  if ( cd "$work" && "$SLUICE" run sh -lc "command -v $bin >/dev/null && timeout 30 $bin --version" ) >/tmp/agentver-$name.log 2>&1; then
    ok "$name: '$bin' installs + runs ($(tr '\n' ' ' </tmp/agentver-$name.log | cut -c1-44))"
  elif ( cd "$work" && "$SLUICE" run sh -lc "command -v $bin" ) >/dev/null 2>&1; then
    ok "$name: '$bin' on PATH (--version unsupported/needs auth)"
  else
    bad "$name: '$bin' NOT found after installing the preset's npm package"
  fi

  # 2. Every declared API host is reachable through the proxy.
  for h in $hosts; do
    code="$( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 https://$h" 2>/dev/null )"
    if [ -n "$code" ] && [ "$code" != 000 ]; then ok "$name: allow $h (HTTP $code through proxy)"
    else bad "$name: allow $h UNREACHABLE (allowlisted host blocked?)"; fi
  done

  # 3. A non-allowlisted host is blocked.
  if ( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null --max-time 8 https://example.com" ) >/dev/null 2>&1; then
    bad "$name: deny example.com NOT blocked"
  else ok "$name: deny example.com blocked"; fi

  # 4. The auth env var is forwarded into the box.
  if [ -n "$firstvar" ]; then
    got="$( cd "$work" && env "$firstvar=__sluice_sentinel__" "$SLUICE" run printenv "$firstvar" 2>/dev/null | tr -d '\r\n' )"
    [ "$got" = "__sluice_sentinel__" ] && ok "$name: \$$firstvar forwarded" \
                                       || bad "$name: \$$firstvar NOT forwarded (got '${got:-<empty>}')"
  fi

  # 5. (cred-gated) Live API round-trip - only if a real auth var is set on the host.
  realset=0; for v in $envvars; do [ -n "${!v:-}" ] && realset=1; done
  if [ "$realset" = 1 ]; then
    ov="$(echo "$name" | tr '[:lower:]' '[:upper:]')_PROBE"; pc="${!ov:-$(probe_cmd "$name")}"
    if [ -n "$pc" ]; then
      ( cd "$work" && "$SLUICE" run sh -lc "timeout 45 $pc" ) >/tmp/agentprobe-$name.log 2>&1 || true
      log="$("$ENG" exec "$container" sh -c 'cat /var/log/squid/access.log' 2>/dev/null)"
      reached=""; for h in $hosts; do printf '%s' "$log" | grep -q "TCP_TUNNEL/200.*ssl_sni=$h" && { reached="$h"; break; }; done
      [ -n "$reached" ] && ok "$name: LIVE - ran YOLO + reached $reached through the proxy (key forwarded)" \
                        || bad "$name: live probe ran but no API tunnel in the proxy log (invocation? see /tmp/agentprobe-$name.log)"
    else skip "$name: no probe command for live round-trip"; fi
  else
    skip "$name: live round-trip (set \$$firstvar on the host to verify the authenticated call)"
  fi

  # Teardown: chown the mount back, stop (keep the agent image cached across presets).
  host_own "$container" "$work"
  ( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
  rm -rf "$(dirname "$work")" 2>/dev/null || true
done

finish
