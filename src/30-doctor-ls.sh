_doc() { printf '  %-10s %s\n' "$1" "$2"; }
cmd_doctor() {
  [ "${1:-}" = --json ] && { cmd_doctor_json; return $?; }
  local eng="" v blocked
  printf '%ssluice doctor%s\n' "$C_BLD" "$C_RST"
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  if [ -n "$eng" ] && command -v "$eng" >/dev/null 2>&1; then
    ENGINE="$eng"; resolve_runner
    if "$eng" info >/dev/null 2>&1; then
      _doc engine "$("$eng" --version 2>/dev/null | head -1)"
    else
      _doc engine "${C_RED}$("$eng" --version 2>/dev/null | head -1) - daemon not responding${C_RST} (is $eng running?)"
      eng=""   # daemon down: skip the engine-dependent checks below
    fi
  else
    eng=""; _doc engine "${C_RED}none${C_RST} - install docker or podman"
  fi

  if ! PROJECT_CONFIG="$(find_config)"; then
    _doc config "${C_RED}none${C_RST} - run 'sluice init' to scaffold one"; return 0
  fi
  _doc config "$PROJECT_CONFIG"
  PROJECT_DIR="$(cd "$(dirname "$PROJECT_CONFIG")" && pwd)"
  # shellcheck disable=SC1090
  . "$PROJECT_CONFIG"
  derive_names
  [ -n "${SLUICE_DESC:-}" ] && _doc desc "$SLUICE_DESC"
  if [ -n "${SLUICE_MOUNTS:-}" ]; then _doc mount "$PROJECT_DIR ${C_DIM}(+ extra mounts)${C_RST}"; else _doc mount "$PROJECT_DIR"; fi

  if [ -n "$eng" ]; then
    if "$eng" image inspect "$tag" >/dev/null 2>&1; then
      if [ "$("$eng" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)" = "$(config_hash)" ]; then
        _doc image "$tag built (${C_GRN}config current${C_RST})"
      else
        _doc image "$tag built (${C_YEL}config stale${C_RST} - run 'sluice rebuild')"
      fi
    else
      _doc image "$tag ${C_DIM}not built${C_RST} - run 'sluice build'"
    fi
  fi

  if [ -f "$PROJECT_DIR/sluice.lock" ]; then
    if [ -n "$eng" ] && "$eng" image inspect "$tag" >/dev/null 2>&1; then
      local curinv drift npkgs
      curinv="$(current_inventory 2>/dev/null || true)"
      drift="$(lock_drift "$curinv")"
      npkgs="$(printf '%s\n' "$curinv" | grep -cE '^(apk|npm|pip|gem|go|cargo) ' || true)"
      if [ -z "$drift" ]; then
        _doc lock "${C_GRN}in sync${C_RST} ($npkgs pkgs)"
      else
        _doc lock "${C_YEL}drifted${C_RST} - $(printf '%s\n' "$drift" | grep -c .) line(s) changed since sluice.lock (run 'sluice update')"
      fi
    else
      _doc lock "${C_DIM}sluice.lock present - build to compare${C_RST}"
    fi
  else
    _doc lock "${C_DIM}none${C_RST} - run 'sluice lock' to record installed versions"
  fi

  if [ -n "${SLUICE_STATE_DIRS:-}" ]; then
    local nsd=0 _sd
    for _sd in ${SLUICE_STATE_DIRS}; do nsd=$((nsd+1)); done
    _doc state "$nsd dir(s) persisted at ${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug"
  fi

  [ -n "${SLUICE_PORTS:-}" ] && _doc ports "$SLUICE_PORTS ${C_DIM}(published on 127.0.0.1)${C_RST}"
  _doc allowlist "${SLUICE_ALLOW_DOMAINS:-(none beyond base)}"
  _doc "" "base: $(base_domains)"
  local _risky="" _doh="" _h
  for _h in ${SLUICE_ALLOW_DOMAINS:-}; do
    laundering_host "$_h" && _risky="$_risky $_h"
    doh_listed "$_h" && _doh="$_doh $_h"
  done
  [ -n "$_risky" ] && _doc "" "${C_YEL}note${C_RST}: shared host(s) an attacker can also write to -${_risky} - data can be laundered out (splice, not decrypt); keep the allowlist tight"
  if [ -n "$_doh" ]; then
    if [ "${SLUICE_ALLOW_DOH:-}" = 1 ]; then _doc "" "${C_YEL}note${C_RST}: DoH resolver(s) allowed AND SLUICE_ALLOW_DOH=1 -${_doh} - DNS-over-HTTPS exfil is possible"
    else _doc "" "${C_DIM}note: DoH resolver(s) on the allowlist -${_doh} - still BLOCKED (DoH exfil channel); SLUICE_ALLOW_DOH=1 to permit${C_RST}"; fi
  fi
  [ -n "${SLUICE_ALLOW_IPS:-}" ] && _doc "" "ips:  $SLUICE_ALLOW_IPS ${C_DIM}(direct egress, bypasses the hostname filter; bare ip = any port, ip:port scopes it)${C_RST}"
  [ -n "${SLUICE_POLICY_URL:-}" ] && _doc policy "$SLUICE_POLICY_URL"

  if [ -n "${SLUICE_ENV:-}" ]; then
    for v in $SLUICE_ENV; do
      if [ -n "${!v:-}" ]; then _doc auth "$v ${C_GRN}set${C_RST}"; else _doc auth "$v ${C_RED}unset${C_RST} - export it on the host"; fi
    done
  fi

  if [ -n "$eng" ] && running; then
    local _RCPT_OFFSET; _RCPT_OFFSET="$(last_run_offset)"   # scope to last run (matches 'sluice learn'); empty -> full log
    blocked="$(blocked_new 2>/dev/null || true)"
    if [ -n "$blocked" ]; then
      _doc egress "${C_RED}$(printf '%s\n' "$blocked" | grep -c .) host(s) blocked${C_RST} (last run) - run 'sluice learn' to allow:"
      # shellcheck disable=SC2086
      printf "             ${C_RED}%s${C_RST}\n" $blocked
    else
      _doc egress "${C_GRN}no blocked egress needs allowing${C_RST}"
    fi
  else
    _doc egress "${C_DIM}sandbox not running${C_RST} - start it, exercise the app, re-run 'sluice doctor'"
  fi
}

# `sluice doctor --json`: the machine-readable posture (kept separate so the human path above is
# untouched; only one branch runs per invocation, so the shared gathering isn't double-work).
cmd_doctor_json() {
  local eng="" engine_ver="" daemon=false
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  if [ -n "$eng" ] && command -v "$eng" >/dev/null 2>&1; then
    ENGINE="$eng"; engine_ver="$("$eng" --version 2>/dev/null | head -1)"
    "$eng" info >/dev/null 2>&1 && daemon=true || eng=""
  else eng=""; fi

  if ! PROJECT_CONFIG="$(find_config)"; then
    printf '{"engine":"%s","daemon":%s,"config":null}\n' "$(_json_esc "$engine_ver")" "$daemon"; return 0
  fi
  PROJECT_DIR="$(cd "$(dirname "$PROJECT_CONFIG")" && pwd)"
  # shellcheck disable=SC1090
  . "$PROJECT_CONFIG"
  derive_names

  local img_built=false img_stale=false
  if [ -n "$eng" ] && "$eng" image inspect "$tag" >/dev/null 2>&1; then
    img_built=true
    [ "$("$eng" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)" = "$(config_hash)" ] || img_stale=true
  fi

  local lock="none"
  if [ -f "$PROJECT_DIR/sluice.lock" ]; then
    if [ -n "$eng" ] && "$eng" image inspect "$tag" >/dev/null 2>&1; then
      [ -z "$(lock_drift 2>/dev/null || true)" ] && lock="in-sync" || lock="drifted"
    else lock="present-unbuilt"; fi
  fi

  local running_b=false blocked=""
  if [ -n "$eng" ] && running; then running_b=true; local _RCPT_OFFSET; _RCPT_OFFSET="$(last_run_offset)"; blocked="$(blocked_new 2>/dev/null || true)"; fi

  local nsd=0 _sd; for _sd in ${SLUICE_STATE_DIRS:-}; do nsd=$((nsd+1)); done

  local auth_json="[" first=1 v setv
  for v in ${SLUICE_ENV:-}; do
    [ "$first" = 1 ] && first=0 || auth_json="$auth_json,"
    setv=false; [ -n "${!v:-}" ] && setv=true
    auth_json="$auth_json{\"var\":\"$(_json_esc "$v")\",\"set\":$setv}"
  done
  auth_json="$auth_json]"

  # shellcheck disable=SC2086
  printf '{"engine":"%s","daemon":%s,"config":"%s","project_dir":"%s","name":"%s","desc":"%s","image":{"tag":"%s","built":%s,"stale":%s},"lock":"%s","allowlist":%s,"base":%s,"ports":%s,"allow_ips":%s,"base_image":"%s","policy_url":"%s","state_dirs":%s,"auth":%s,"egress":{"running":%s,"blocked":%s}}\n' \
    "$(_json_esc "$engine_ver")" "$daemon" "$(_json_esc "$PROJECT_CONFIG")" "$(_json_esc "$PROJECT_DIR")" "$(_json_esc "$tag")" "$(_json_esc "${SLUICE_DESC:-}")" \
    "$(_json_esc "$tag")" "$img_built" "$img_stale" "$lock" \
    "$(printf '%s\n' ${SLUICE_ALLOW_DOMAINS:-} | _json_arr)" "$(base_domains | tr ' ' '\n' | _json_arr)" \
    "$(printf '%s\n' ${SLUICE_PORTS:-} | _json_arr)" "$(printf '%s\n' ${SLUICE_ALLOW_IPS:-} | _json_arr)" "$(_json_esc "${SLUICE_BASE_IMAGE:-}")" \
    "$(_json_esc "${SLUICE_POLICY_URL:-}")" "$nsd" "$auth_json" "$running_b" "$(printf '%s\n' $blocked | _json_arr)"
}

# `sluice ls`: a derived, read-only table of every built sluice box on this machine
# Boxes are identified by the sluice.confighash label (baked since early versions); path/stack/desc
# come from labels baked at build, so nothing is sourced here. The box matching $PWD is marked '*'.
cmd_ls() {
  local mode="" only_running="" only_orphans="" stack_filter="" egress="" imgs here=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)    mode=--json ;;
      --running) only_running=1 ;;
      --orphans) only_orphans=1 ;;
      --egress)  egress=1 ;;
      --stack)   [ -n "${2:-}" ] || die "usage: sluice ls --stack <name>"; stack_filter="$2"; shift ;;
      --stack=*) stack_filter="${1#--stack=}" ;;
      *)         die "usage: sluice ls [--running] [--orphans] [--stack <name>] [--egress] [--json]" ;;
    esac
    shift
  done

  imgs="$("$ENGINE" image ls --filter label=sluice.confighash --format '{{.Repository}}' 2>/dev/null | grep -v '^<none>$' | sort -u || true)"   # grep exits 1 on no-match; tolerate it so the empty-state branch is reachable under set -e
  if [ -z "$imgs" ]; then
    if ! "$ENGINE" info >/dev/null 2>&1; then   # binary exists (dispatch checked), so empty == daemon down
      [ "$mode" = --json ] && { echo '[]'; return 0; }
      echo "[sluice] ${C_RED}${ENGINE} daemon not responding${C_RST} - is it running?"
      return 0
    fi
    [ "$mode" = --json ] && { echo '[]'; return 0; }
    echo "[sluice] no sluice boxes built yet - run 'sluice' in a project."
    return 0
  fi
  # Current box = the project dir for $PWD's config (no sourcing), matched on the sluice.project label.
  if here="$(find_config 2>/dev/null)"; then here="$(cd "$(dirname "$here")" && pwd)"; else here=""; fi

  # Gather labels + container state into parallel arrays, applying filters as we go. (Kept as a plain
  # while-loop, NOT a $(...) capture: a case pattern's ) inside command substitution mis-parses on bash 3.2.)
  local names=() stats=() projs=() stacks=() descs=() curs=() orphs=() allows=() ports_=() locks=() blocks=()
  local name proj stack desc status cur orphan allowcount portslbl lock blocked
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    proj="$( "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.project" }}' "$name" 2>/dev/null || true)"
    stack="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.stack" }}'   "$name" 2>/dev/null || true)"
    desc="$( "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.desc" }}'    "$name" 2>/dev/null || true)"
    allowcount="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.allowcount" }}' "$name" 2>/dev/null || true)"
    portslbl="$(  "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.ports" }}'      "$name" 2>/dev/null || true)"
    case "$proj"       in "<no value>") proj=""       ;; esac
    case "$stack"      in "<no value>") stack=""      ;; esac
    case "$desc"       in "<no value>") desc=""       ;; esac
    case "$allowcount" in "<no value>") allowcount="" ;; esac
    case "$portslbl"   in "<no value>") portslbl=""   ;; esac
    orphan=false; [ -n "$proj" ] && [ ! -d "$proj" ] && orphan=true
    if   "$RUNNER" ps    --filter "name=$name" --filter status=running --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then status=running
    elif "$RUNNER" ps -a --filter "name=$name" --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then status=stopped
    elif [ "$orphan" = true ]; then status=orphan
    else status=built; fi
    cur=false; [ -n "$here" ] && [ "$proj" = "$here" ] && cur=true
    [ -n "$only_running" ] && [ "$status" != running ] && continue
    [ -n "$only_orphans" ] && [ "$orphan" != true ]    && continue
    [ -n "$stack_filter" ] && case "$stack" in *"$stack_filter"*) ;; *) continue ;; esac
    lock="-"; [ -n "$proj" ] && [ -f "$proj/sluice.lock" ] && lock=locked
    blocked=""; [ -n "$egress" ] && [ "$status" = running ] && blocked="$(box_blocked_count "$name")"   # opt-in: execs into the box
    names+=("$name"); stats+=("$status"); projs+=("$proj"); stacks+=("$stack"); descs+=("$desc"); curs+=("$cur"); orphs+=("$orphan")
    allows+=("$allowcount"); ports_+=("$portslbl"); locks+=("$lock"); blocks+=("$blocked")
  done <<EOF
$imgs
EOF

  if [ "${#names[@]}" -eq 0 ]; then
    [ "$mode" = --json ] && { echo '[]'; return 0; }
    echo "[sluice] no sluice boxes match the given filters."
    return 0
  fi

  # Render order: current first, then running, then name. Build "ckey<TAB>rkey<TAB>name<TAB>idx",
  # sort, read the indices back (this $(...) holds no case pattern, so it's bash-3.2-safe).
  local TAB; TAB="$(printf '\t')"
  local order=() ckey rkey idx sorted
  sorted="$(
    for idx in "${!names[@]}"; do
      ckey=1; [ "${curs[$idx]}" = true ]     && ckey=0
      rkey=1; [ "${stats[$idx]}" = running ] && rkey=0
      printf '%s\t%s\t%s\t%s\n' "$ckey" "$rkey" "${names[$idx]}" "$idx"
    done | sort -t"$TAB" -k1,1 -k2,2 -k3,3
  )"
  while IFS="$TAB" read -r ckey rkey name idx; do
    [ -n "$idx" ] && order+=("$idx")
  done <<EOF
$sorted
EOF

  local i j ac lk pjson bjson
  if [ "$mode" = --json ]; then
    printf '['
    for j in "${!order[@]}"; do
      i="${order[$j]}"
      [ "$j" -gt 0 ] && printf ','
      ac="${allows[$i]}"; [ -n "$ac" ] || ac=null              # null = un-rebuilt box (label absent), not 0
      lk=false; [ "${locks[$i]}" = locked ] && lk=true
      # shellcheck disable=SC2086
      pjson="$(printf '%s\n' ${ports_[$i]} | _json_arr)"
      bjson=""; if [ -n "$egress" ]; then
        if [ "${stats[$i]}" = running ]; then bjson=",\"blocked\":${blocks[$i]:-0}"; else bjson=',"blocked":null'; fi
      fi
      printf '{"name":"%s","status":"%s","stack":"%s","path":"%s","description":"%s","current":%s,"orphan":%s,"allow_count":%s,"ports":%s,"locked":%s%s}' \
        "$(_json_esc "${names[$i]}")" "$(_json_esc "${stats[$i]}")" "$(_json_esc "${stacks[$i]}")" \
        "$(_json_esc "${projs[$i]}")" "$(_json_esc "${descs[$i]}")" "${curs[$i]}" "${orphs[$i]}" \
        "$ac" "$pjson" "$lk" "$bjson"
    done
    printf ']\n'; return 0
  fi

  # human table: compute display values + column widths (indexed by original position)
  local wname=4 wstat=6 wstack=5 wallow=5 wports=5 wlock=4 wblk=7 wpath=4
  local vpaths=() cpaths=() dstacks=() ddescs=() marks=() dallows=() dports=() dlocks=() dblks=()
  local dpath vpath cpath dstack ddesc mark dallow dport dlock dblk
  for i in "${!names[@]}"; do
    dpath="${projs[$i]}"; case "$dpath" in "$HOME"/*) dpath="~${dpath#"$HOME"}";; "$HOME") dpath="~";; esac
    [ -n "$dpath" ] || dpath="-"
    if [ "${orphs[$i]}" = true ]; then vpath="$dpath (gone)"; cpath="$dpath ${C_DIM}(gone)${C_RST}"; else vpath="$dpath"; cpath="$dpath"; fi
    dstack="${stacks[$i]}"; [ -n "$dstack" ] || dstack="-"
    ddesc="${descs[$i]}";   [ -n "$ddesc" ]  || ddesc="-"
    dallow="${allows[$i]}"; [ -n "$dallow" ] || dallow="-"
    dport="${ports_[$i]}";  [ -n "$dport" ]  || dport="-"
    dlock="${locks[$i]}"
    dblk="${blocks[$i]}";   [ -n "$dblk" ]   || dblk="-"
    mark=" "; [ "${curs[$i]}" = true ] && mark="*"
    vpaths[$i]="$vpath"; cpaths[$i]="$cpath"; dstacks[$i]="$dstack"; ddescs[$i]="$ddesc"; marks[$i]="$mark"
    dallows[$i]="$dallow"; dports[$i]="$dport"; dlocks[$i]="$dlock"; dblks[$i]="$dblk"
    [ ${#names[$i]} -gt "$wname"  ] && wname=${#names[$i]}
    [ ${#stats[$i]} -gt "$wstat"  ] && wstat=${#stats[$i]}
    [ ${#dstack}    -gt "$wstack" ] && wstack=${#dstack}
    [ ${#dallow}    -gt "$wallow" ] && wallow=${#dallow}
    [ ${#dport}     -gt "$wports" ] && wports=${#dport}
    [ ${#dlock}     -gt "$wlock"  ] && wlock=${#dlock}
    [ ${#dblk}      -gt "$wblk"   ] && wblk=${#dblk}
    [ ${#vpath}     -gt "$wpath"  ] && wpath=${#vpath}
  done

  echo "${C_BLD}sluice boxes${C_RST}"
  printf '  %s' "$C_DIM"
  printf '%-*s  %-*s  %-*s  %-*s  %-*s  %-*s' "$wname" NAME "$wstat" STATUS "$wstack" STACK "$wallow" ALLOW "$wports" PORTS "$wlock" LOCK
  [ -n "$egress" ] && printf '  %-*s' "$wblk" BLOCKED
  printf '  %-*s  %s%s\n' "$wpath" PATH DESCRIPTION "$C_RST"
  local st sc stcol pad pcell
  for j in "${!order[@]}"; do
    i="${order[$j]}"
    st="${stats[$i]}"; case "$st" in running) sc="$C_GRN";; *) sc="$C_DIM";; esac
    stcol="${sc}$(printf '%-*s' "$wstat" "$st")${C_RST}"   # pad first, then color, so columns stay aligned
    pad=$(( wpath - ${#vpaths[$i]} )); [ "$pad" -lt 0 ] && pad=0
    pcell="${cpaths[$i]}$(printf '%*s' "$pad" '')"         # color the (gone) suffix, then pad on visible width
    printf '%s %-*s  %s  %-*s  %-*s  %-*s  %-*s' "${marks[$i]}" \
      "$wname" "${names[$i]}" "$stcol" "$wstack" "${dstacks[$i]}" "$wallow" "${dallows[$i]}" "$wports" "${dports[$i]}" "$wlock" "${dlocks[$i]}"
    [ -n "$egress" ] && printf '  %-*s' "$wblk" "${dblks[$i]}"
    printf '  %s  %s\n' "$pcell" "${ddescs[$i]}"
  done
}

# sluice-gate mark on human entries; stderr + TTY-only + SLUICE_NO_BANNER-suppressible.
