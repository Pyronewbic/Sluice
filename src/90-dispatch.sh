case "${1:-run-default}" in
  build)   build; exit 0 ;;
  diff)    cmd_workspace_diff; exit $? ;;
  apply)   cmd_workspace_apply; exit $? ;;
  rebuild) build; start; exit 0 ;;
  stop)    "$RUNNER" rm -f -v "$container" >/dev/null 2>&1 || true; echo "[sluice] $container removed (image kept - 'sluice' recreates it)"; exit 0 ;;
  rm)
    "$RUNNER" rm -f -v "$container" >/dev/null 2>&1 || true; "$ENGINE" rmi -f "$tag" >/dev/null 2>&1 || true
    _nov="$(remove_box_volumes "$container")"   # SLUICE_OVERLAY_DIRS volumes ride the box's lifecycle
    _ovmsg=""; [ "${_nov:-0}" -gt 0 ] && _ovmsg=" + $_nov overlay volume(s)"
    echo "[sluice] removed $container (container + image$_ovmsg)"; exit 0 ;;
  logs)    "$RUNNER" logs -f "$container" ;;
  smoke)
    maybe_build
    "$ENGINE" run --rm --user sluice --entrypoint bash "$tag" /usr/local/bin/smoke-test.sh
    exit $?
    ;;
  learn)
    shift
    for _a in "$@"; do [ "$_a" = --audit ] && { cmd_learn_audit; exit $?; }; done
    cmd_learn "$@"; exit $?
    ;;
  egress)
    shift
    case "${1:-}" in
      ""|--json) cmd_egress "${1:-}"; exit $? ;;
      *)         die "usage: sluice egress [--json]" ;;
    esac
    ;;
  lock)
    shift
    case "${1:-}" in
      --check)   cmd_lock_check   "${2:-}"; exit $? ;;
      --diff)    cmd_lock_diff    "${2:-}"; exit $? ;;
      --enforce) cmd_lock_enforce "${2:-}"; exit $? ;;
      --sbom)    shift; cmd_sbom "$@"; exit $? ;;
      --scan)    shift; cmd_scan "$@"; exit $? ;;
      "")        write_lock; exit 0 ;;
      *)         die "usage: sluice lock [--check [--json] | --diff [--json] | --enforce [--json] | --sbom [--format cyclonedx|spdx] | --scan [--json] [--fail-on <sev>]]" ;;
    esac
    ;;
  update)  build --no-cache; write_lock; exit 0 ;;
  shell)   banner; ensure_up; exec_in bash ;;
  run)
    shift
    [ "$#" -gt 0 ] || die "usage: sluice run <cmd...>"
    ensure_up; mark_run_start; exec_in "$@"
    ;;
  run-default)
    banner
    # F2: snapshot image freshness BEFORE ensure_up may rebuild, so the plan line can say up-to-date vs rebuilt.
    _fresh=1
    [ "$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)" = "$(config_hash)" ] || _fresh=""
    ensure_up
    _nhosts="$(allowed_domains | wc -w | tr -d ' ')"
    _state="up-to-date"; [ -n "$_fresh" ] || _state="rebuilt"
    # (auth-unset warning already emitted once by warn_auth_unset above; state-aware, no duplicate here)
    # Snapshot the proxy log position so the receipt reports THIS run's egress, not the box's whole
    # boot. Then run SLUICE_RUN_CMD; the EXIT trap prints the receipt (reached + blocked). run_in
    # (not exec_in) so the trap fires after the session, even on Ctrl-C - which is why we capture and
    # re-propagate the command's status ourselves (the trailing hints would otherwise leave $? = 0).
    _RCPT_OFFSET="$("$RUNNER" exec "$container" sh -c 'wc -c < /var/log/squid/access.log' 2>/dev/null | tr -dc 0-9)"
    mark_run_start   # so a later `sluice learn` can scope to this run
    trap show_egress_receipt EXIT
    # F2: one-line plan so the implicit build/run is legible (the no-op case speaks via the status below).
    case "${SLUICE_RUN_CMD:-}" in
      true|:|/bin/true) ;;
      *) echo "${E_DIM}[sluice]${E_RST} box ${_state} (${_nhosts} allowed hosts) - running: ${SLUICE_RUN_CMD:-bash}" >&2 ;;
    esac
    _rc=0
    if [ "${#AGENT_EXTRA_ARGS[@]}" -gt 0 ]; then
      # one-shot agent run: forward trailing args as positional params (no re-quoting needed)
      run_in sh -lc "${SLUICE_RUN_CMD:-bash} \"\$@\"" sh "${AGENT_EXTRA_ARGS[@]}" || _rc=$?
    else
      run_in sh -lc "${SLUICE_RUN_CMD:-bash}" || _rc=$?
    fi
    # F4: a no-op run-cmd (e.g. the lock demo's `true`) would dead-end on a one-line hint; show a
    # compact doctor-lite status instead (box up, image state, allowed-host count) + what to run.
    case "${SLUICE_RUN_CMD:-}" in
      true|:|/bin/true)
        _shell_hint="sluice shell"; [ -n "$SLUICE_BOX_TARGET" ] && _shell_hint="sluice -b $SLUICE_BOX_SLUG shell"
        echo "${E_DIM}[sluice]${E_RST} box ${container} is up (image ${_state}; ${_nhosts} allowed hosts); SLUICE_RUN_CMD='${SLUICE_RUN_CMD}' is a no-op - nothing to run." >&2
        echo "         try '$_shell_hint', 'sluice doctor', or a subcommand (e.g. sluice lock)." >&2 ;;
    esac
    # overlay workspace: nudge with the changeset; the host repo is untouched until `sluice apply`.
    if workspace_is_overlay; then
      _wsa=""; read -r _wsa _wsm _wsd <<EOF
$(workspace_counts)
EOF
      [ "$(( ${_wsa:-0} + ${_wsm:-0} + ${_wsd:-0} ))" -gt 0 ] && \
        echo "${E_DIM}[sluice]${E_RST} workspace: ${_wsa} added, ${_wsm} modified, ${_wsd} deleted (host repo untouched) - review: sluice diff | write back: sluice apply" >&2
    fi
    # F3: complete the onboarding arc on the very first run (config was just scaffolded this invocation).
    [ -n "${_SCAFFOLDED:-}" ] && echo "${E_DIM}[sluice]${E_RST} first run done - next: 'sluice learn' (lock egress to what it needed), 'sluice lock' (pin the supply chain)." >&2
    # F1: propagate SLUICE_RUN_CMD's status. The EXIT trap doesn't call exit, so bash exits with this
    # code; without it the trailing hints/nudges leave $? = 0 (a false green in CI / `sluice && ...`).
    exit "$_rc"
    ;;
  *) die "unknown command: $1 - run 'sluice help' for usage." ;;
esac
