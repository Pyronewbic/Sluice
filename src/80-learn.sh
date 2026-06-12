# Persist one run's receipt host-side (outside the box the workload can reach): a "latest" snapshot
# (egress-receipt.json, back-compat) AND an append-only, hash-chained audit log (egress-log.jsonl).
# Each log line carries prev = the previous line's `self`, and self = sha256 of the line up to `self`
# (genesis prev = 64 zeros), so editing/reordering/dropping any line breaks the chain -> `sluice egress
# --verify`. $1 = the egress rows (may be empty), $2 = status (ok | unavailable).
_persist_receipt() {
  local rows="$1" rstatus="$2" TAB _dir _log _inner _hj="" _first=1 _cls _host _cnt _byt \
        _reached _blocked _tot _ts _run _prev _self _payload
  TAB="$(printf '\t')"
  _dir="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug"
  mkdir -p "$_dir" 2>/dev/null || return 0
  _log="$_dir/egress-log.jsonl"
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; _run="${_ts}-$$"
  while IFS="$TAB" read -r _cls _host _cnt _byt; do
    [ -n "$_host" ] || continue
    [ "$_first" = 1 ] && _first=0 || _hj="$_hj,"
    _hj="$_hj{\"host\":\"$(_json_esc "$_host")\",\"class\":\"$_cls\",\"requests\":$_cnt,\"bytes\":$_byt}"
  done <<EOF
$rows
EOF
  _reached="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="reached"' | grep -c . || true)"
  _blocked="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="blocked"' | grep -c . || true)"
  _tot="$(printf '%s\n' "$rows" | awk -F"$TAB" '{t+=$4} END{print t+0}')"
  # record body (no chain fields), versioned. box/totals/hosts/confighash/allowlist stay back-compat.
  _inner="$(printf '"schema":"sluice.egress/v1","run":"%s","ts":"%s","box":"%s","status":"%s","confighash":"%s","allowlist":%s,"totals":{"reached":%s,"blocked":%s,"bytes":%s},"hosts":[%s]' \
    "$_run" "$_ts" "$(_json_esc "$container")" "$rstatus" "$(config_hash 2>/dev/null || true)" \
    "$(allowed_domains | tr ' ' '\n' | _json_arr)" "${_reached:-0}" "${_blocked:-0}" "${_tot:-0}" "$_hj")"
  printf '{%s}\n' "$_inner" > "$_dir/egress-receipt.json" 2>/dev/null || true
  # prev = the previous record's self (genesis = 64 zeros). Guard the read: a first-run tail on the
  # not-yet-existing log exits non-zero, which under the launcher's set -e/pipefail would abort here.
  _prev=""
  [ -f "$_log" ] && _prev="$(tail -n 1 "$_log" 2>/dev/null | sed -n 's/.*,"self":"\([0-9a-f]*\)"}$/\1/p')"
  [ -n "$_prev" ] || _prev="0000000000000000000000000000000000000000000000000000000000000000"
  _payload="{${_inner},\"prev\":\"${_prev}\"}"
  _self="$(printf '%s' "$_payload" | _sha256)"
  printf '%s,"self":"%s"}\n' "${_payload%\}}" "$_self" >> "$_log" 2>/dev/null || true
}

show_egress_receipt() {
  local rows TAB reached_rows blocked_rows ordered grn="" red="" dim="" bld="" rst=""
  rows="$(egress_rows 2>/dev/null || true)"
  if [ -z "$rows" ]; then
    # Box gone before capture (concurrent stop / crash / host OOM): record the gap explicitly so a
    # missing receipt can't read as a clean zero-egress run. A live box with no egress stays silent.
    if ! running; then
      _persist_receipt "" unavailable
      echo "[sluice] ${E_YEL:-}egress receipt unavailable${E_RST:-} - box exited before capture" >&2
    fi
    return 0
  fi
  TAB="$(printf '\t')"
  reached_rows="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="reached"' | sort -t"$TAB" -k4,4nr)"
  blocked_rows="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="blocked"' | sort -t"$TAB" -k2,2)"
  ordered="$(printf '%s\n%s\n' "$reached_rows" "$blocked_rows" | awk 'NF')"
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    grn=$'\033[32m'; red=$'\033[31m'; dim=$'\033[2m'; bld=$'\033[1m'; rst=$'\033[0m'
  fi
  # Render summary header + aligned rows on stderr (so it never pollutes the app's stdout).
  printf '%s\n' "$ordered" | awk -F"$TAB" \
    -v box="$container" -v grn="$grn" -v red="$red" -v dim="$dim" -v bld="$bld" -v rst="$rst" '
    function human(b){ if(b<1024) return b" B"; else if(b<1048576) return sprintf("%.1f KB",b/1024); else return sprintf("%.1f MB",b/1048576) }
    { cls[NR]=$1; host[NR]=$2; cnt[NR]=$3; byt[NR]=$4; total+=$4;
      if($1=="reached"){ nr++; if(nr<=10 && length($2)>w) w=length($2) } else { nb++; if(length($2)>w) w=length($2) } }
    END {
      printf "%s[sluice] egress receipt: %s%s   %d reached, %d blocked, %s\n", bld, box, rst, nr, nb, human(total);
      sr=0;
      for(i=1;i<=NR;i++){
        if(cls[i]=="reached"){
          sr++;
          if(sr==11){ printf "  %s+%d more (sluice egress)%s\n", dim, nr-10, rst; }
          if(sr>10) continue;
          printf "  %sreached%s   %-*s  %3d req   %s\n", grn, rst, w, host[i], cnt[i], human(byt[i]);
        } else {
          printf "  %sblocked%s   %-*s  %3d req   %snot allowlisted (sluice learn)%s\n", red, rst, w, host[i], cnt[i], dim, rst;
        }
      }
      if(nb==0) printf "  %sall egress was allowlisted%s\n", grn, rst;
    }' >&2

  _persist_receipt "$rows" ok   # latest snapshot + append to the hash-chained audit log

  # SLUICE_EGRESS_MAX_BYTES: loud warning when this run sent more than the cap (bounds laundering
  # through an allowed host). `sluice egress` is the CI gate (exits non-zero); the receipt just nudges.
  case "${SLUICE_EGRESS_MAX_BYTES:-}" in
    ''|*[!0-9]*) ;;
    *) local _tx; _tx="$(egress_tx_total 2>/dev/null || echo 0)"; case "$_tx" in ''|*[!0-9]*) _tx=0;; esac
       [ "$_tx" -gt "$SLUICE_EGRESS_MAX_BYTES" ] && \
         printf '%s[sluice] egress budget exceeded:%s %s sent > %s cap - `sluice egress` will fail CI.\n' \
           "$red" "$rst" "$(_human_bytes "$_tx")" "$(_human_bytes "$SLUICE_EGRESS_MAX_BYTES")" >&2 ;;
  esac
}

# Write/replace the SLUICE_ALLOW_DOMAINS line in the project config (interactive + --apply share this).
apply_allowlist() {
  local val="$1" tmp
  if grep -q '^SLUICE_ALLOW_DOMAINS=' "$PROJECT_CONFIG"; then
    tmp="$(mktemp)"
    awk -v v="$val" '/^SLUICE_ALLOW_DOMAINS=/ && !seen {print "SLUICE_ALLOW_DOMAINS=\"" v "\""; seen=1; next} {print}' \
      "$PROJECT_CONFIG" > "$tmp" && mv "$tmp" "$PROJECT_CONFIG"
  else
    printf 'SLUICE_ALLOW_DOMAINS="%s"\n' "$val" >> "$PROJECT_CONFIG"
  fi
  chmod 0644 "$PROJECT_CONFIG" 2>/dev/null || true   # mktemp is 0600; the build sources it as the sluice user
}

# Merged allowlist value: existing SLUICE_ALLOW_DOMAINS + the given (newline) entries, unique.
merge_allow() {
  printf '%s %s\n' "${SLUICE_ALLOW_DOMAINS:-}" "$(printf '%s' "$1" | tr '\n' ' ')" \
    | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# Append entries to the box's squid allowlist + SIGHUP squid (reconfigure: re-reads the acl files) so
# picks go live with no rebuild. squid runs `squid -N` (no pid file, so `squid -k` can't signal it),
# hence pkill. Also regenerate the DNS servers-file from the new allowlist + SIGHUP dnsmasq, so a
# newly-allowed host resolves too (resolution is allowlist-scoped). Non-zero if the box is down or the
# reload fails; the DNS step is best-effort (no-op on SLUICE_DNS_OPEN boxes / older images).
reload_allowlist() {
  [ "$#" -gt 0 ] || return 0
  running || return 1
  printf '%s\n' "$@" | _root_exec -i "$container" sh -c \
    'cat >> /etc/squid/allowlist.txt && sort -u /etc/squid/allowlist.txt -o /etc/squid/allowlist.txt && pkill -HUP -x squid && { [ -x /usr/local/bin/sluice-dns-allow ] && /usr/local/bin/sluice-dns-allow && pkill -HUP -x dnsmasq; true; }' \
    >/dev/null 2>&1
}

# Persist chosen entries to the project config AND make them live on the running box (no rebuild).
# Before either, filter the picks the same way the boot path does (core/entrypoint.sh drop_doh):
# a DoH/DoT resolver is an exfil channel blocked even when allowlisted, so learn must NOT add it -
# to config or live - unless SLUICE_ALLOW_DOH=1. Without this the live squid reload (which appends
# straight to the post-filter allowlist) would re-open DoH while a rebuilt box re-blocks it, so the
# running box would silently diverge from its own config. Laundering hosts are allowed (boot allows
# them too) but warned, matching the session-start gate.
learn_apply() {   # $1 = newline-separated entries (hosts and/or .domains)
  local entries="$1" keep="" doh="" launder="" pden="" pdeny="" e h
  # A central policy can DENY a host; learn must not re-add it via the live reload (which appends
  # straight to the running box's allowlist, bypassing the run-time policy gate). Fail-open on an
  # unfetchable policy here - the run-time gate (apply_policy) is the fail-closed enforcement.
  policy_configured && pdeny="$(_policy_raw 2>/dev/null | awk '$1=="deny"{print $2}' || true)"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    h="${e#.}"   # a .domain wildcard matches by its bare host
    if [ "${SLUICE_ALLOW_DOH:-}" != 1 ] && doh_listed "$h"; then doh="$doh $e"; continue; fi
    if [ -n "$pdeny" ] && _policy_denied_host "$h" "$pdeny"; then pden="$pden $e"; continue; fi
    laundering_host "$h" && launder="$launder $e"
    keep="$keep $e"
  done <<EOF
$entries
EOF
  keep="${keep# }"

  if [ -n "$pden" ]; then
    echo "[sluice] ${E_YEL}not allowing (denied by central policy):${E_RST}$pden" >&2
  fi
  if [ -n "$doh" ]; then
    echo "[sluice] ${E_YEL}not allowing DoH/DoT resolver(s):${E_RST}$doh" >&2
    echo "         these tunnel DNS over HTTPS past the SNI filter - blocked even when allowlisted." >&2
    echo "         set SLUICE_ALLOW_DOH=1 (weakens the guarantee) and re-run 'sluice learn' to permit." >&2
  fi
  if [ -z "$keep" ]; then
    echo "[sluice] ${C_DIM}nothing added.${C_RST}"
    return 0
  fi
  [ -n "$launder" ] && echo "[sluice] ${E_YEL}note:${E_RST} allowlisted host(s) an attacker can also write to -$launder - data can be laundered out (splice, not decrypt); keep the list tight." >&2

  apply_allowlist "$(merge_allow "$keep")"
  # shellcheck disable=SC2086
  echo "[sluice] ${C_GRN}allowing:${C_RST} $(printf '%s ' $keep | sed 's/  */ /g; s/ *$//')"
  echo "[sluice] wrote $(_tilde "$PROJECT_CONFIG")"
  # shellcheck disable=SC2086
  if reload_allowlist $keep; then
    echo "[sluice] reloaded the running box (squid reconfigure) - ${C_GRN}live now, no rebuild.${C_RST}"
  else
    echo "[sluice] config saved - run 'sluice rebuild' to apply (couldn't hot-reload)."
  fi
}

# Interactive review of candidate "<host>\t<count>\t<bytes>" rows: offer `.parent` wildcard collapses,
# then per-host allow/skip/domain, then persist + hot-reload. Shared by learn + learn --audit; falls
# back to a plain list when there's no tty.
_learn_review() {
  local rows="$1" label="$2" TAB; TAB="$(printf '\t')"
  if [ ! -t 0 ] && [ ! -t 1 ]; then
    echo "[sluice] $label:"
    printf '%s\n' "$rows" | while IFS="$TAB" read -r h c b; do [ -n "$h" ] && printf '    %s  (%s req, %s)\n' "$h" "$c" "$(_human_bytes "$b")"; done
    echo "[sluice] non-interactive: 'sluice learn --apply' to allow all, or '--print' to emit the list."
    return 0
  fi
  echo "[sluice] $label - allow which? ('s' leaves a host blocked)"; echo
  local hosts; hosts="$(printf '%s\n' "$rows" | cut -d"$TAB" -f1 | sed '/^$/d')"
  local -a selected=() handled=()
  # Wildcard offers: parents with >=2 blocked subdomains.
  local parents p subs ya; parents="$(printf '%s\n' "$hosts" | while read -r h; do [ -n "$h" ] && parent_of "$h"; done | sort | uniq -c | awk '$1>=2{print $2}')"
  for p in $parents; do
    _collapsible "$p" || continue   # never offer a wildcard equal to a public suffix (foo.github.io -> .github.io)
    subs="$(printf '%s\n' "$hosts" | while read -r h; do [ "$(parent_of "$h")" = "$p" ] && echo "$h"; done)"
    # shellcheck disable=SC2086
    printf '  %s subdomains of %s: %s\n' "$(printf '%s\n' "$subs" | awk 'END{print NR}')" "$p" "$(printf '%s ' $subs)"
    printf '  collapse to .%s (matches all its subdomains)? [y/N] ' "$p"
    read -r ya </dev/tty || ya=""
    # shellcheck disable=SC2206
    case "$ya" in y|Y|yes|YES) selected+=(".$p"); handled+=($subs); echo ;; *) echo ;; esac
  done
  # Per-host loop for anything not covered by an accepted wildcard.
  local h c b ans pd
  while IFS="$TAB" read -r h c b; do
    [ -n "$h" ] || continue
    case " ${handled[*]:-} " in *" $h "*) continue ;; esac
    printf '  %-28s %3s req %9s   [a]llow / [s]kip / [d]omain(.%s) / [q]uit? ' "$h" "$c" "$(_human_bytes "$b")" "$(parent_of "$h")"
    read -r ans </dev/tty || ans=""
    case "$ans" in
      a|A|y|Y) selected+=("$h") ;;
      d|D)     pd="$(parent_of "$h")"; if _collapsible "$pd"; then selected+=(".$pd"); else selected+=("$h"); fi ;;
      q|Q)     break ;;
      *)       ;;
    esac
  done <<EOF
$rows
EOF
  echo
  if [ "${#selected[@]}" -eq 0 ]; then
    echo "[sluice] ${C_DIM}nothing added - all hosts left blocked.${C_RST}"
    return 0
  fi
  learn_apply "$(printf '%s\n' "${selected[@]}")"
}

# `sluice learn [--all] [--print | --apply]`: review the hosts squid BLOCKED and allowlist the ones
# you choose. Scoped to the last run by default (--all = since boot). The example.* canary + raw IPs are
# already dropped by egress_rows. --print emits the merged list (CI); --apply allows all (no prompts).
cmd_learn() {
  local scope=run mode=interactive a
  for a in "$@"; do
    case "$a" in
      --all)   scope=all ;;
      --print) mode=print ;;
      --apply) mode=apply ;;
      *) die "usage: sluice learn [--all] [--print | --apply | --audit]" ;;
    esac
  done
  running || die "no running sandbox. Start your app ('sluice'), exercise it so it makes its network calls, then run 'sluice learn'."
  [ "$scope" = all ] || _RCPT_OFFSET="$(last_run_offset)"

  local TAB; TAB="$(printf '\t')"
  local rows; rows="$(egress_rows 2>/dev/null | awk -F"$TAB" '$1=="blocked"{print $2 FS $3 FS $4}' | sort -t"$TAB" -k3,3nr -k1,1 || true)"
  local label; [ "$scope" = all ] && label="blocked since the box booted" || label="blocked during the last run"

  if [ -z "$rows" ]; then
    echo "[sluice] ${C_GRN}nothing $label - every host your app reached is already allowed.${C_RST}"
    [ "$scope" = run ] && echo "[sluice] (try 'sluice learn --all' for everything since boot.)"
    return 0
  fi

  local hosts; hosts="$(printf '%s\n' "$rows" | cut -d"$TAB" -f1 | sed '/^$/d')"
  [ "$mode" = print ] && { printf '%s\n' "$(merge_allow "$hosts")"; return 0; }
  [ "$mode" = apply ] && { learn_apply "$hosts"; return 0; }
  _learn_review "$rows" "$label"
}

# `sluice learn --audit`: one-shot OPEN-egress discovery (the warned escape hatch). Runs SLUICE_RUN_CMD
# once in an ephemeral, credential-stripped container with egress opened to ALL HTTP/HTTPS hosts
# (non-HTTP + IPv6 stay blocked), then proposes the allowlist from every host it reached - for trusted
# code whose fetcher aborts on the first block. No creds forwarded, nothing to exfiltrate.
cmd_learn_audit() {
  cat >&2 <<EOF
[sluice] ${E_YEL}WARNING:${E_RST} 'learn --audit' opens egress to ALL HTTP/HTTPS hosts for one run.
         It runs SLUICE_RUN_CMD with NO forwarded credentials (SLUICE_ENV, prelaunch, and
         persisted auth are stripped) in a throwaway container, then tears it down - but while
         it runs, this project's code can reach any host. Use it only on code you trust.
EOF
  if [ -t 0 ] && [ -t 1 ]; then
    printf '[sluice] open egress and run SLUICE_RUN_CMD once to discover reached hosts? [y/N] '
    local a; read -r a 2>/dev/null || a=""
    case "$a" in y|Y|yes|YES) ;; *) echo "[sluice] ${C_DIM}aborted - egress not opened.${C_RST}"; return 0 ;; esac
  elif [ "${SLUICE_YES:-}" != 1 ]; then
    echo "[sluice] non-interactive: re-run with SLUICE_YES=1 to confirm opening egress for the audit pass."
    return 0
  fi

  maybe_build
  local audit_container="$container-audit"
  "$RUNNER" rm -f "$audit_container" >/dev/null 2>&1 || true
  # Bake the names into the trap now (the local is gone by the time EXIT fires) so the ephemeral
  # container is always torn down - normal exit, die, or Ctrl-C. It never leaves audit mode.
  # shellcheck disable=SC2064  # expand $audit_container/$RUNNER NOW: the local is gone when the trap fires
  trap "'$RUNNER' rm -f '$audit_container' >/dev/null 2>&1 || true" EXIT

  # Credential-stripped run args: project mount + git common dir + the proxy sysctls + SLUICE_AUDIT.
  # Deliberately NO prelaunch, state-dir mounts, SLUICE_ENV, or published ports (see start()).
  local run_args=(--cap-drop ALL
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETUID --cap-add SETGID
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE --cap-add KILL
    --security-opt no-new-privileges
    --pids-limit "${SLUICE_PIDS_LIMIT:-4096}"
    --sysctl net.ipv4.conf.all.route_localnet=1
    --sysctl net.ipv6.conf.all.disable_ipv6=1
    --sysctl net.ipv6.conf.default.disable_ipv6=1
    -e SLUICE_AUDIT=1
    -v "$PROJECT_DIR":"$PROJECT_DIR" -e "SLUICE_WORKDIR=$PROJECT_DIR")
  [ -n "${SLUICE_MEMORY:-}" ] && run_args+=(--memory "$SLUICE_MEMORY")
  selinux_enforcing && run_args+=(--security-opt label=disable)   # see the main run path
  if git -C "$PROJECT_DIR" rev-parse --git-common-dir >/dev/null 2>&1; then
    local common; common="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir)"
    case "$common" in /*) ;; *) common="$PROJECT_DIR/$common";; esac
    common="$(cd "$common" 2>/dev/null && pwd || true)"
    if [ -n "$common" ]; then
      case "$common/" in "$PROJECT_DIR"/*) ;; *) run_args+=(-v "$common":"$common" -e "SLUICE_GITDIR=$common");; esac
    fi
  fi

  # Egress is OPEN for this run - keep SLUICE_MASK shadowing in force so in-repo secrets stay unreadable.
  mask_build_args
  if [ "${#MASK_ARGS[@]}" -gt 0 ]; then
    run_args+=("${MASK_ARGS[@]}")
    echo "[sluice] masking (unreadable in the box): $MASKED_PATHS" >&2
  fi

  echo "[sluice] starting ephemeral audit container $audit_container ..."
  runtime_sync_image
  runtime_run --name "$audit_container" "${run_args[@]}" "$tag" >/dev/null
  local up="" tries=60; [ "$RUNNER" != "$ENGINE" ] && tries=120
  for _ in $(seq 1 "$tries"); do
    "$RUNNER" logs "$audit_container" 2>&1 | grep -q "\[sluice\] ready" && { up=1; break; }
    sleep 0.5
  done
  [ -n "$up" ] || die "audit container failed to come up - see: $RUNNER logs $audit_container"

  # Run the command with NO credential forwarding (no -e for SLUICE_ENV vars).
  local exec_args=(-i --user sluice -w "$PROJECT_DIR")
  [ -t 0 ] && [ -t 1 ] && exec_args+=(-t)
  echo "[sluice] running SLUICE_RUN_CMD with egress open (discovering reached hosts)..."
  "$RUNNER" exec "${exec_args[@]}" "$audit_container" sh -lc "${SLUICE_RUN_CMD:-true}" || true

  # Review the hosts it reached (egress was open), minus base/allowlist + the example.* canary, with
  # per-host selection - then persist + hot-reload onto the real (enforcing) box.
  local TAB; TAB="$(printf '\t')"
  local rows; rows="$(egress_rows "$audit_container" 2>/dev/null \
    | awk -F"$TAB" -v allow=" $(allowed_domains) " '
        function allowed(h,   n,i,t,tl,toks){ if(index(allow," "h" "))return 1; n=split(allow,toks," "); for(i=1;i<=n;i++){t=toks[i]; if(substr(t,1,1)=="."){tl=length(t); if(h==substr(t,2)||(length(h)>tl&&substr(h,length(h)-tl+1)==t))return 1}} return 0 }
        $1=="reached" && !allowed($2){print $2 FS $3 FS $4}' \
    | sort -t"$TAB" -k3,3nr -k1,1 || true)"
  echo
  if [ -z "$rows" ]; then
    echo "[sluice] ${C_GRN}the audit run reached no new hosts beyond the base/allowlist - nothing to add.${C_RST}"
    return 0
  fi
  _learn_review "$rows" "reached during the audit run (egress was open)"
}

