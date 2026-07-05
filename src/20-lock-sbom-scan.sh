cmd_egress() {
  local mode="${1:-}" rows TAB
  running || die "no running sandbox. Start it ('sluice'), exercise it, then run 'sluice egress'."
  rows="$(egress_rows 2>/dev/null || true)"
  # Empty rows mean "no egress" OR a FAILED in-box read (uid 1000 filled the pids cgroup so the audit
  # exec couldn't fork). Never let a failed read pass as a clean zero - fail closed so a CI byte gate
  # can't go green on an un-audited run.
  if [ -z "$rows" ] && ! _audit_readable; then
    if [ "$mode" = --json ]; then
      printf '{"schema":"sluice.egress/v1","box":"%s","unavailable":true}\n' "$(_json_esc "$container")"
    else
      echo "[sluice] ${E_YEL:-}egress audit unavailable${E_RST:-} - could not read the in-box log (pids limit?); failing closed." >&2
    fi
    return 2
  fi
  TAB="$(printf '\t')"
  # SLUICE_EGRESS_MAX_BYTES: a volume budget on what LEFT the box (tx to reached hosts). Over the cap,
  # this command exits non-zero so CI can gate it - bounds how much can be laundered through an
  # allowed host. Unset -> no gate (always exit 0, unchanged).
  local cap="${SLUICE_EGRESS_MAX_BYTES:-}" tx over=0
  case "$cap" in *[!0-9]*) cap="";; esac   # non-numeric (or empty) -> no budget
  tx="$(egress_tx_total 2>/dev/null || echo 0)"; case "$tx" in ''|*[!0-9]*) tx=0;; esac
  [ -n "$cap" ] && [ "$tx" -gt "$cap" ] && over=1
  # SLUICE_EGRESS_HOST_BUDGETS: a PER-HOST tx budget (bounds laundering through one allowed host more
  # tightly than the whole-box cap). Any single reached host over its cap makes this command exit
  # non-zero too - the same CI gate. Detective, boot-scoped (like the total cap). hb_tx_table is the
  # per-host tx tally, computed once and reused by the human + JSON renders below.
  local hb_over=0 hb_tx_table="" hb_host hb_tx hb_cap
  if [ -n "${SLUICE_EGRESS_HOST_BUDGETS:-}" ]; then
    hb_tx_table="$(egress_tx_by_host 2>/dev/null || true)"
    while IFS="$TAB" read -r hb_host hb_tx; do
      [ -n "$hb_host" ] || continue
      hb_cap="$(_host_budget_for "$hb_host")"; [ -n "$hb_cap" ] || continue
      case "$hb_tx" in ''|*[!0-9]*) hb_tx=0 ;; esac
      [ "$hb_tx" -gt "$hb_cap" ] && hb_over=1
    done <<EOF
$hb_tx_table
EOF
  fi
  [ "$hb_over" = 1 ] && over=1
  if [ "$mode" = --json ]; then
    # Back-compat host arrays + a detailed hosts array (class/requests/bytes) for the control plane.
    local allowed blocked hosts_json="" first=1 cls host cnt byt over_json=false
    [ "$over" = 1 ] && over_json=true
    allowed="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="reached"{print $2}')"
    blocked="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="blocked"{print $2}')"
    local _bud _ovb _htx
    while IFS="$TAB" read -r cls host cnt byt; do
      [ -n "$host" ] || continue
      [ "$first" = 1 ] && first=0 || hosts_json="$hosts_json,"
      _bud=null; _ovb=false
      if [ -n "$hb_tx_table" ] && [ "$cls" = reached ]; then
        _bud="$(_host_budget_for "$host")"
        if [ -n "$_bud" ]; then
          _htx="$(printf '%s\n' "$hb_tx_table" | awk -F"$TAB" -v h="$host" '$1==h{print $2; exit}')"
          case "$_htx" in ''|*[!0-9]*) _htx=0 ;; esac
          [ "$_htx" -gt "$_bud" ] && _ovb=true
        else _bud=null; fi
      fi
      hosts_json="$hosts_json{\"host\":\"$(_json_esc "$host")\",\"class\":\"$cls\",\"requests\":$cnt,\"bytes\":$byt,\"budget\":$_bud,\"over_budget\":$_ovb}"
    done <<EOF
$rows
EOF
    # window=boot: unlike the at-exit receipt (run-scoped), this command reads the whole-boot egress
    # window - so does its SLUICE_EGRESS_MAX_BYTES gate. Surfaced for the control plane (see docs/operations.md).
    printf '{"schema":"sluice.egress/v1","box":"%s","window":"boot","allowed":%s,"blocked":%s,"tx_bytes":%s,"budget":%s,"over_budget":%s,"hosts":[%s]}\n' \
      "$(_json_esc "$container")" \
      "$(printf '%s\n' "$allowed" | _json_arr)" "$(printf '%s\n' "$blocked" | _json_arr)" \
      "$tx" "${cap:-null}" "$over_json" "$hosts_json"
    return "$over"
  fi
  if [ -n "$rows" ]; then
    # Summary header (reached/blocked tally + total bytes) then host | verdict | requests | bytes
    # (reached): reached first (by bytes desc), then blocked. Counts/total computed in the same awk pass.
    local nblocked; nblocked="$(printf '%s\n' "$rows" | awk -F"$TAB" '$1=="blocked"' | grep -c . || true)"
    printf '%s\n' "$rows" | sort -t"$TAB" -k1,1r -k4,4nr -k2,2 \
      | awk -F"$TAB" -v box="$container" -v grn="$C_GRN" -v red="$C_RED" -v dim="$C_DIM" -v bld="$C_BLD" -v rst="$C_RST" '
          function human(b){ if(b<1024) return b" B"; else if(b<1048576) return sprintf("%.1f KB",b/1024); else return sprintf("%.1f MB",b/1048576) }
          { c[NR]=$1; h[NR]=$2; n[NR]=$3; b[NR]=$4; total+=$4; if($1=="reached") nr++; else nb++; if(length($2)>w) w=length($2) }
          END { printf "%s%s egress%s   %d reached, %d blocked, %s\n", bld, box, rst, nr, nb, human(total);
                for(i=1;i<=NR;i++){
                  if(c[i]=="reached") printf "  %-*s  %s[reached]%s  %3d req   %s\n", w, h[i], grn, rst, n[i], human(b[i]);
                  else                printf "  %-*s  %s[blocked]%s  %3d req\n",        w, h[i], red, rst, n[i];
                } }'
    # C1: blocked rows carry no next step here (unlike the receipt's per-row annotation) - one trailing nudge.
    [ "${nblocked:-0}" -gt 0 ] && echo "  ${C_DIM}${nblocked} host(s) blocked - allow with 'sluice learn'${C_RST}"
  else
    echo "${C_BLD}$container egress${C_RST}"
    echo "  ${C_DIM}(nothing yet - exercise the app, then re-run)${C_RST}"
  fi
  if [ -n "$cap" ]; then
    if [ "$tx" -gt "$cap" ]; then echo "  ${C_RED}egress budget EXCEEDED${C_RST}: $(_human_bytes "$tx") sent > $(_human_bytes "$cap") cap (SLUICE_EGRESS_MAX_BYTES)"
    else echo "  ${C_DIM}egress budget: $(_human_bytes "$tx") sent / $(_human_bytes "$cap") cap${C_RST}"; fi
  fi
  # Per-host budget breaches (SLUICE_EGRESS_HOST_BUDGETS): one line per host over its own cap.
  if [ "$hb_over" = 1 ]; then
    printf '%s\n' "$hb_tx_table" | while IFS="$TAB" read -r hb_host hb_tx; do
      [ -n "$hb_host" ] || continue
      hb_cap="$(_host_budget_for "$hb_host")"; [ -n "$hb_cap" ] || continue
      case "$hb_tx" in ''|*[!0-9]*) hb_tx=0 ;; esac
      [ "$hb_tx" -gt "$hb_cap" ] && echo "  ${C_RED}host budget EXCEEDED${C_RST}: $hb_host sent $(_human_bytes "$hb_tx") > $(_human_bytes "$hb_cap") cap (SLUICE_EGRESS_HOST_BUDGETS)"
    done
  fi
  # C2: make the tamper-evident audit log discoverable (has-rows human path only; the empty case stays quiet).
  [ -n "$rows" ] && echo "  ${C_DIM}audit log: sluice egress --export | --verify${C_RST}"
  return "$over"
}

# `sluice egress --export`: emit the append-only egress audit log (JSONL, one record per run with
# egress) for SIEM/CI ingestion. Reads the host-side store, so it works even when the box is down.
cmd_egress_export() {
  local log="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug/egress-log.jsonl"
  [ -f "$log" ] || { echo "[sluice] no egress log yet at $(_tilde "$log") - run the box first." >&2; return 0; }
  cat "$log"
}

# Walk ONE egress-log.jsonl hash chain. Sets _VCF_RECORDS / _VCF_BROKEN / _VCF_REASON and returns 0 if
# intact, 1 on the first break (self-hash / prev-link) or an unreadable file. Byte-identical chain
# semantics to the old inline loop - the `|| [ -n "$line" ]` unterminated-tail catch and the blank-line
# continue are both pinned by test/verify-receipt-unit.bats (which must pass unmodified). Shared by the
# single-box `egress --verify` and the fleet `egress --verify --all`; M3's rotation adds a `rotation-link`
# reason on top of this walker.
_verify_chain_file() {
  local log="$1"
  _VCF_RECORDS=0; _VCF_BROKEN=""; _VCF_REASON=""
  # A file we cannot read (perms) reports unreadable, never a silent pass (fail closed, like the audit reads).
  [ -r "$log" ] || { _VCF_REASON=unreadable; return 1; }
  local n=0 prev="0000000000000000000000000000000000000000000000000000000000000000" line payload self pfield
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue   # tolerate blank lines (don't hash "" into a bogus TAMPERED); count only real records
    n=$((n+1))
    self="$(printf '%s' "$line"   | sed -n 's/.*,"self":"\([0-9a-f]*\)"}$/\1/p')"
    payload="$(printf '%s' "$line" | sed 's/,"self":"[0-9a-f]*"}$/}/')"
    pfield="$(printf '%s' "$line"  | sed -n 's/.*,"prev":"\([0-9a-f]*\)".*/\1/p')"
    if [ -z "$self" ] || [ "$(printf '%s' "$payload" | _sha256)" != "$self" ]; then
      _VCF_RECORDS="$n"; _VCF_BROKEN="$n"; _VCF_REASON="self-hash"; return 1
    fi
    if [ "$pfield" != "$prev" ]; then
      _VCF_RECORDS="$n"; _VCF_BROKEN="$n"; _VCF_REASON="prev-link"; return 1
    fi
    prev="$self"
  done < "$log"
  _VCF_RECORDS="$n"; return 0
}

# `sluice egress --verify`: walk the hash chain of the egress audit log; OK only if every line's
# self-hash recomputes and its prev links to the previous line's self (genesis = 64 zeros). Exits
# non-zero on the first break (tamper / reorder / truncation) - a CI integrity gate on the receipts.
cmd_egress_verify() {
  # Parse the one optional flag strictly (mirrors cmd_scan/_drift_report): a typo'd gate flag must die,
  # not silently downgrade to the human path at exit 0 (a CI 'egress --verify --jsonn' would lose its JSON).
  local json=0
  case "${1:-}" in
    --json) json=1 ;;
    "")     ;;
    *)      die "usage: sluice egress --verify [--json]" ;;
  esac
  local log="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug/egress-log.jsonl"
  # No log = an empty chain: trivially intact (0 records), exit 0 - unchanged.
  if [ ! -f "$log" ]; then
    if [ "$json" = 1 ]; then echo '{"schema":"sluice.egress-verify/v1","verified":true,"records":0,"broken_line":null,"reason":null}'
    else echo "[sluice] no egress log yet at $(_tilde "$log")." >&2; fi
    return 0
  fi
  if _verify_chain_file "$log"; then
    if [ "$json" = 1 ]; then printf '{"schema":"sluice.egress-verify/v1","verified":true,"records":%d,"broken_line":null,"reason":null}\n' "$_VCF_RECORDS"
    else echo "[sluice] ${C_GRN}egress log verified${C_RST}: $_VCF_RECORDS record(s), hash chain intact ($(_tilde "$log"))"; fi
    return 0
  fi
  if [ "$json" = 1 ]; then
    local _bl="$_VCF_BROKEN"; [ -n "$_bl" ] || _bl=null
    printf '{"schema":"sluice.egress-verify/v1","verified":false,"records":%d,"broken_line":%s,"reason":"%s"}\n' "$_VCF_RECORDS" "$_bl" "$_VCF_REASON"
  else
    case "$_VCF_REASON" in
      prev-link) echo "[sluice] ${E_RED}egress log TAMPERED${E_RST}: line $_VCF_BROKEN prev-link broken - reordered or dropped ($(_tilde "$log"))" >&2 ;;
      unreadable) echo "[sluice] ${E_RED}egress log unreadable${E_RST}: $(_tilde "$log")" >&2 ;;
      *)          echo "[sluice] ${E_RED}egress log TAMPERED${E_RST}: line $_VCF_BROKEN self-hash mismatch ($(_tilde "$log"))" >&2 ;;
    esac
  fi
  return 1
}

# `sluice egress --verify --all [--json]`: walk EVERY box's egress chain in one pass - the fleet-wide
# integrity gate. Pure host-side file reads (no engine, no per-box config), so it covers orphaned boxes
# and runs with the daemon down. Exit 1 if any chain is broken/unreadable, 0 on an intact or empty fleet.
cmd_egress_verify_all() {
  local json=0
  case "${1:-}" in --json) json=1 ;; "") ;; *) die "usage: sluice egress --verify --all [--json]" ;; esac
  local store="${XDG_STATE_HOME:-$HOME/.local/state}/sluice" logs
  # LC_ALL=C slug order; the */ glob skips the dot-prefixed .policy-cache dir + the .mask-empty stub.
  logs="$(for _l in "$store"/*/egress-log.jsonl; do [ -f "$_l" ] && printf '%s\n' "$_l"; done | LC_ALL=C sort)"
  if [ -z "$logs" ]; then
    if [ "$json" = 1 ]; then echo '{"schema":"sluice.fleet-verify/v1","verified":true,"boxes_total":0,"boxes_broken":0,"boxes":[]}'
    else echo "[sluice] no egress logs yet under $(_tilde "$store")." >&2; fi
    return 0
  fi
  local total=0 broken=0 first=1 boxes_json="" log s bslug bok bl reason
  while IFS= read -r log; do
    [ -n "$log" ] || continue
    s="${log%/egress-log.jsonl}"; bslug="${s##*/}"
    total=$((total+1))
    if _verify_chain_file "$log"; then bok=true; bl=null; reason=null
    else bok=false; broken=$((broken+1)); bl="$_VCF_BROKEN"; [ -n "$bl" ] || bl=null; reason="\"$_VCF_REASON\""; fi
    if [ "$json" = 1 ]; then
      [ "$first" = 1 ] && first=0 || boxes_json="$boxes_json,"
      boxes_json="$boxes_json{\"box\":\"sluice-$(_json_esc "$bslug")\",\"slug\":\"$(_json_esc "$bslug")\",\"state_dir\":\"$(_json_esc "$s")\",\"records\":$_VCF_RECORDS,\"verified\":$bok,\"broken_line\":$bl,\"reason\":$reason}"
    elif [ "$bok" = true ]; then
      printf '  %-24s  %s record(s)  %sintact%s\n' "sluice-$bslug" "$_VCF_RECORDS" "$C_GRN" "$C_RST"
    elif [ "$_VCF_REASON" = unreadable ]; then
      printf '  %-24s  %sunreadable%s\n' "sluice-$bslug" "$C_RED" "$C_RST"
    else
      printf '  %-24s  %sTAMPERED%s  line %s (%s)\n' "sluice-$bslug" "$C_RED" "$C_RST" "$_VCF_BROKEN" "$_VCF_REASON"
    fi
  done <<EOF
$logs
EOF
  if [ "$json" = 1 ]; then
    local verified=true; [ "$broken" -gt 0 ] && verified=false
    printf '{"schema":"sluice.fleet-verify/v1","verified":%s,"boxes_total":%d,"boxes_broken":%d,"boxes":[%s]}\n' "$verified" "$total" "$broken" "$boxes_json"
  elif [ "$broken" -gt 0 ]; then
    echo "[sluice] ${E_RED}$broken of $total box(es) TAMPERED / unreadable${E_RST}" >&2
  else
    echo "[sluice] ${C_GRN}all $total box(es) intact${C_RST}"
  fi
  if [ "$broken" -gt 0 ]; then return 1; fi
  return 0
}

# `sluice egress --export --all`: concatenate every box's append-only JSONL log, slug-sorted, for a
# SIEM/CI to ingest the whole fleet at once. Each record carries its own `box`, so a consumer regroups
# by `.box` regardless of order. Host-side reads only (works with the daemon down / on orphans).
cmd_egress_export_all() {
  local store="${XDG_STATE_HOME:-$HOME/.local/state}/sluice" logs log
  logs="$(for _l in "$store"/*/egress-log.jsonl; do [ -f "$_l" ] && printf '%s\n' "$_l"; done | LC_ALL=C sort)"
  [ -n "$logs" ] || { echo "[sluice] no egress logs yet under $(_tilde "$store")." >&2; return 0; }
  while IFS= read -r log; do [ -n "$log" ] && cat "$log"; done <<EOF
$logs
EOF
}

# sluice.lock: a committable inventory of the built image. base ref + every apk
# (name/version/checksum) + global npm pkg, introspected from the image (awk/jq run in-image via a
# heredoc), sorted for stable diffs. Defined above cmd_doctor for the early `doctor` dispatch.
current_inventory() {
  local baseref bdig
  baseref="${SLUICE_BASE_IMAGE:-cgr.dev/chainguard/wolfi-base}"
  bdig="$("$ENGINE" image inspect "$baseref" --format '{{ if .RepoDigests }}{{ index .RepoDigests 0 }}{{ end }}' 2>/dev/null || true)"
  printf 'base  %s\n' "${bdig:-$baseref}"
  "$ENGINE" run --rm -i --entrypoint sh "$tag" 2>/dev/null <<'INTROSPECT' | LC_ALL=C sort -u
awk 'BEGIN{RS="";FS="\n"}{p=v=c="";for(i=1;i<=NF;i++){t=substr($i,1,2);if(t=="P:")p=substr($i,3);else if(t=="V:")v=substr($i,3);else if(t=="C:")c=substr($i,3)}if(p!="")printf "apk  %s %s %s\n",p,v,c}' /lib/apk/db/installed
npm ls -g --depth=0 --json 2>/dev/null | jq -r '(.dependencies // {})|to_entries[]|"npm  \(.key) \(.value.version)"' 2>/dev/null
command -v pip3 >/dev/null 2>&1 && su -s /bin/sh sluice -c 'HOME=/home/sluice pip3 list --format=json 2>/dev/null' 2>/dev/null | jq -r '.[]|"pip  \(.key//.name|ascii_downcase) \(.value//.version)"' 2>/dev/null   # as sluice: system + the project's --user site (root pip3 misses it)
command -v pipx >/dev/null 2>&1 && su -s /bin/sh sluice -c 'HOME=/home/sluice pipx list --json 2>/dev/null' 2>/dev/null | jq -r '(.venvs//{})|to_entries[]|.value.metadata.main_package|"pip  \(.package|ascii_downcase) \(.package_version)"' 2>/dev/null   # pipx apps live in isolated venvs
command -v gem  >/dev/null 2>&1 && gem list --local --quiet 2>/dev/null | awk '{name=$1;rest=$0;sub(/^[^(]*\(/,"",rest);sub(/\).*$/,"",rest);n=split(rest,vs,/, */);for(i=1;i<=n;i++){v=vs[i];sub(/^default: */,"",v);if(v!="")printf "gem  %s %s\n",name,v}}'
command -v go   >/dev/null 2>&1 && { gb=""; for d in "$(go env GOBIN 2>/dev/null)" "$(go env GOPATH 2>/dev/null)/bin" /home/sluice/go/bin; do [ -n "$d" ] && [ -d "$d" ] || continue; case " $gb " in *" $d "*) ;; *) gb="$gb $d";; esac; done; for d in $gb; do for f in "$d"/*; do [ -f "$f" ] && [ -x "$f" ] || continue; go version -m "$f" 2>/dev/null | awk '$1=="mod"{print "go  "$2" "$3; exit}'; done; done; }
command -v cargo >/dev/null 2>&1 && { for ch in "${CARGO_HOME:-$HOME/.cargo}" /home/sluice/.cargo /root/.cargo; do [ -f "$ch/.crates2.json" ] || continue; jq -r '.installs|keys[]|split(" ")|"cargo  \(.[0]) \(.[1])"' "$ch/.crates2.json" 2>/dev/null; break; done; }
true
INTROSPECT
}

# Build (if needed) and write ./sluice.lock from the image inventory.
write_lock() {
  maybe_build
  local lock="$PROJECT_DIR/sluice.lock" inv na nn np ng ngo nc parts deltarows="" had_lock=0
  inv="$(current_inventory)"
  # Fail CLOSED: current_inventory's in-image read is masked by a `sort -u` pipe and consumed via a
  # command substitution, so a failed engine read can't trip set -e - it returns base-ref only. A real
  # Wolfi box always has apks, so a missing apk line means the read failed; refuse to write a hollow lock
  # (a base-only artifact reported as success, then --check flags every real package as drift).
  printf '%s\n' "$inv" | grep -q '^apk ' || die "could not read the image inventory - refusing to write a hollow sluice.lock"
  # Capture the supply-chain delta vs the existing lock BEFORE overwriting (reuse $inv; no re-introspect).
  [ -f "$lock" ] && { had_lock=1; deltarows="$(classify_drift "$(lock_drift "$inv")")"; }
  {
    printf "# sluice.lock - inventory of the built sandbox image (%s).\n" "$tag"
    printf "# Audit/drift artifact, NOT a reproducibility guarantee (Wolfi apk is a rolling repo).\n"
    printf "# Generated by 'sluice lock'; refresh with 'sluice update'.\n"
    printf '%s\n' "$inv"
  } > "$lock"
  na="$(printf '%s\n' "$inv" | grep -c '^apk ' || true)"   # grep -c exits 1 on zero matches; tolerate
  nn="$(printf '%s\n' "$inv" | grep -c '^npm ' || true)"   # (a box with no global npm packages)
  np="$(printf '%s\n' "$inv" | grep -c '^pip ' || true)"
  ng="$(printf '%s\n' "$inv" | grep -c '^gem ' || true)"
  ngo="$(printf '%s\n' "$inv" | grep -c '^go ' || true)"
  nc="$(printf '%s\n' "$inv" | grep -c '^cargo ' || true)"
  parts="$na apk"
  [ "$nn" -gt 0 ]  && parts="$parts + $nn npm"
  [ "$np" -gt 0 ]  && parts="$parts + $np pip"
  [ "$ng" -gt 0 ]  && parts="$parts + $ng gem"
  [ "$ngo" -gt 0 ] && parts="$parts + $ngo go"
  [ "$nc" -gt 0 ]  && parts="$parts + $nc cargo"
  echo "[sluice] wrote $lock ($parts packages)"
  if [ "$had_lock" = 1 ] && [ -n "$deltarows" ]; then
    echo "[sluice] supply-chain delta since last lock: +$(printf '%s\n' "$deltarows" | grep -c '^add' || true) -$(printf '%s\n' "$deltarows" | grep -c '^del' || true) ~$(printf '%s\n' "$deltarows" | grep -c '^chg' || true)"
    printf '%s\n' "$deltarows" | render_drift_human
  elif [ "$had_lock" = 1 ]; then
    # C4: an unchanged re-lock is silent otherwise - confirm it, mirroring --check's "lock in sync".
    echo "[sluice] ${C_GRN}no supply-chain change since last lock${C_RST}"
  fi
}

# Pin inventory: current_inventory's package set (apk/npm/pip/gem/go/cargo, with the frozen
# `apk name ver checksum` shape) but with the base line replaced by a DIGEST-checked one. The pin's
# whole point is a rebuildable coordinate, so it fails closed if the base can't be resolved to a
# @sha256 digest - pulling the base once if the local engine has no RepoDigests yet.
_pin_inventory() {
  local baseref bdig
  baseref="${SLUICE_BASE_IMAGE:-cgr.dev/chainguard/wolfi-base}"
  bdig="$("$ENGINE" image inspect "$baseref" --format '{{ if .RepoDigests }}{{ index .RepoDigests 0 }}{{ end }}' 2>/dev/null || true)"
  if [ -z "$bdig" ]; then
    echo "[sluice] resolving the base image digest (pulling $baseref) ..." >&2
    "$ENGINE" pull "$baseref" >/dev/null 2>&1 || true
    bdig="$("$ENGINE" image inspect "$baseref" --format '{{ if .RepoDigests }}{{ index .RepoDigests 0 }}{{ end }}' 2>/dev/null || true)"
  fi
  printf 'base  %s\n' "${bdig:-$baseref}"
  current_inventory | grep -v '^base '   # drop current_inventory's own (maybe-digestless) base line
}

# `sluice lock --pin`: write ./sluice.pin, a committable replay manifest - the base pinned by digest
# plus every apk/npm/pip/gem/go/cargo name+version. `SLUICE_PIN=1` (M2) rebuilds converging on exactly
# these versions. Also refreshes sluice.lock from the same built image (they read one image, so they
# never disagree; the extra introspection is a no-op build + a second read). Fails closed on a hollow
# inventory or an unresolvable base digest - a pin that can't freeze its base is worse than none.
write_pin() {
  maybe_build
  local pin="$PROJECT_DIR/sluice.pin" inv base na
  inv="$(_pin_inventory)"
  printf '%s\n' "$inv" | grep -q '^apk ' || die "could not read the image inventory - refusing to write a hollow sluice.pin"
  base="$(printf '%s\n' "$inv" | awk '$1=="base"{print $2; exit}')"
  case "$base" in *@sha256:*) ;; *) die "could not resolve a base image digest - refusing to write a pin that cannot freeze its base (is the base image pullable?)" ;; esac
  {
    printf "# sluice.pin - pinned replay manifest for %s.\n" "$tag"
    printf "# Rebuild with SLUICE_PIN=1 to converge on these exact versions. Honest scope: an apk pin\n"
    printf "# fails CLOSED once Wolfi stops serving that version (rolling repo) - see docs/supply-chain.md.\n"
    printf "# 'base' pins the image by @sha256 digest; each '<eco>  <name>  <version>' line pins a package.\n"
    printf 'base  %s\n' "$base"
    printf '%s\n' "$inv" | grep -v '^base ' | LC_ALL=C sort
  } > "$pin"
  na="$(printf '%s\n' "$inv" | grep -c '^apk ' || true)"
  echo "[sluice] wrote $pin (base pinned by digest + $na apk + npm/pip/gem/go/cargo versions)"
  write_lock   # keep sluice.lock in lockstep (same image, so the two agree)
}

# Drifted lines between ./sluice.lock and the live image inventory ("< lock / > current"); empty =
# in sync. Optional $1 = a pre-computed inventory (so doctor doesn't introspect the image twice).
lock_drift() {
  local inv="${1:-$(current_inventory 2>/dev/null || true)}"
  diff <(grep -vE '^#' "$PROJECT_DIR/sluice.lock" 2>/dev/null || true) \
       <(printf '%s\n' "$inv") 2>/dev/null | grep -E '^[<>]' || true
}

# Classify raw lock_drift ("< old" / "> new") into sorted structured rows:
# "<op>\t<type>\t<name>\t<old>\t<new>", op = add|del|chg. $1 = pre-computed raw drift (else read fresh).
# Key = type+name+version so one name at two versions is del+add, not a bogus single chg (A7); apk
# carries its checksum into the value so a same-version rebuild renders a legible chg, not "1.0 -> 1.0" (A6).
classify_drift() {
  local raw TAB; TAB="$(printf '\t')"
  if [ $# -ge 1 ]; then raw="$1"; else raw="$(lock_drift)"; fi
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | awk '
    { type=$2;
      if (type=="base")    { key="base"; name="base"; val=$3 }
      else if (type=="apk"){ key=type SUBSEP $3 SUBSEP $4; name=$3; val=$4 ($5==""?"":" " $5) }
      else                 { key=type SUBSEP $3 SUBSEP $4; name=$3; val=$4 }
      if ($1=="<") { oldv[key]=val; haveo[key]=1 } else { newv[key]=val; haven[key]=1 }
      t[key]=type; nm[key]=name; seen[key]=1 }
    END{ for (k in seen) {
      if (haveo[k] && !haven[k])      printf "del\t%s\t%s\t%s\t\n",  t[k],nm[k],oldv[k];
      else if (!haveo[k] && haven[k]) printf "add\t%s\t%s\t\t%s\n",  t[k],nm[k],newv[k];
      else                            printf "chg\t%s\t%s\t%s\t%s\n",t[k],nm[k],oldv[k],newv[k] } }' \
  | LC_ALL=C sort -t"$TAB" -k2,2 -k3,3 -k4,4 -k5,5
}

# Render structured drift rows (stdin) as aligned, colored +/-/~ lines. $1=err -> stderr-gated colors
# (the --check path renders to stderr; write_lock/--diff render to stdout).
render_drift_human() {
  local g="$C_GRN" r="$C_RED" y="$C_YEL" x="$C_RST"
  [ "${1:-}" = err ] && { g="$E_GRN"; r="$E_RED"; y="$E_YEL"; x="$E_RST"; }
  awk -F"$(printf '\t')" -v g="$g" -v r="$r" -v y="$y" -v x="$x" '
    { op[NR]=$1; ty[NR]=$2; nm[NR]=$3; ov[NR]=$4; nv[NR]=$5;
      if(length($2)>wt)wt=length($2); if(length($3)>wn)wn=length($3) }
    END{ for(i=1;i<=NR;i++){
      sym=(op[i]=="add")?"+":(op[i]=="del")?"-":"~";
      col=(op[i]=="add")?g:(op[i]=="del")?r:y;
      if(op[i]=="chg")      printf "  %s%s%s %-*s %-*s %s  ->  %s\n", col,sym,x, wt,ty[i], wn,nm[i], ov[i], nv[i];
      else if(op[i]=="add") printf "  %s%s%s %-*s %-*s %s\n",          col,sym,x, wt,ty[i], wn,nm[i], nv[i];
      else                  printf "  %s%s%s %-*s %-*s %s\n",          col,sym,x, wt,ty[i], wn,nm[i], ov[i] } }'
}

# Render structured drift rows (stdin) as {in_sync,added,removed,changed[]} for CI.
render_drift_json() {
  awk -F"$(printf '\t')" '
    function j(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
    { if($1=="add")      a=a (a==""?"":",") sprintf("{\"type\":\"%s\",\"name\":\"%s\",\"version\":\"%s\"}",j($2),j($3),j($5));
      else if($1=="del") d=d (d==""?"":",") sprintf("{\"type\":\"%s\",\"name\":\"%s\",\"version\":\"%s\"}",j($2),j($3),j($4));
      else               c=c (c==""?"":",") sprintf("{\"type\":\"%s\",\"name\":\"%s\",\"from\":\"%s\",\"to\":\"%s\"}",j($2),j($3),j($4),j($5));
      n++ }
    END{ printf "{\"in_sync\":%s,\"added\":[%s],\"removed\":[%s],\"changed\":[%s]}\n", (n==0?"true":"false"), a, d, c }'
}

# Shared drift report for --check (exit 1 on drift), --diff (exit 0), and --enforce (strict). $1 =
# exit-on-drift, $2 = strict|"" (refuse to build/tolerate a stale image - a pure verifier); the REST are
# the user's flags (only --json), parsed strictly so a typo'd gate flag can't silently run a plain check.
_drift_report() {
  local on_drift="$1" strict=0 json=0; [ "${2:-}" = strict ] && strict=1; shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      *)      die "usage: sluice lock [--check|--diff|--enforce] [--json]" ;;
    esac
    shift
  done
  [ -f "$PROJECT_DIR/sluice.lock" ] || die "no sluice.lock to check against - run 'sluice lock' first"
  # A check verifies the artifact as built: build only if no image exists; if the image predates a
  # config edit, note it (on stderr, so --json stays clean) but still report against what's built -
  # a gate shouldn't silently rebuild (that's `sluice build`/`sluice lock`). --enforce is stricter
  # still: it refuses to build or to report against a stale image (a CI gate must not mutate).
  if image_missing; then [ "$strict" = 1 ] && die "no built image to enforce against - run 'sluice build' first"; build
  elif image_stale; then [ "$strict" = 1 ] && die "image predates config edits - rebuild before 'sluice lock --enforce'"; echo "[sluice] ${E_YEL}note${E_RST}: image predates config edits - run 'sluice build' to refresh" >&2; fi
  local rows; rows="$(classify_drift)"
  if [ "$json" = 1 ]; then
    [ -z "$rows" ] && { echo '{"in_sync":true,"added":[],"removed":[],"changed":[]}'; return 0; }
    printf '%s\n' "$rows" | render_drift_json; return "$on_drift"
  fi
  [ -z "$rows" ] && { echo "[sluice] ${C_GRN}lock in sync${C_RST}"; return 0; }
  if [ "$on_drift" = 1 ]; then
    echo "[sluice] ${E_RED}DRIFT${E_RST}: the built image differs from sluice.lock (+added -removed ~changed):" >&2
    printf '%s\n' "$rows" | render_drift_human err >&2
    # C2: don't dead-end on the rows - point at the fix (re-record the intended state, or rebuild if the image drifted).
    echo "[sluice] ${E_DIM}remedy${E_RST}: re-record with 'sluice lock' (accept this image), or 'sluice build' then re-check (rebuild to the locked state)." >&2
  else
    echo "[sluice] drift from sluice.lock (+added -removed ~changed):"
    printf '%s\n' "$rows" | render_drift_human
  fi
  return "$on_drift"
}

# `sluice lock --check [--json]`: fail (exit 1) if the built image drifted from the committed sluice.lock.
cmd_lock_check() { _drift_report 1 "" "$@"; }
# `sluice lock --diff [--json]`: same drift view, read-only (exit 0) - a local review, not a CI gate.
cmd_lock_diff()  { _drift_report 0 "" "$@"; }
# `sluice lock --enforce [--json]`: a strict CI gate - like --check, but refuses to build or to tolerate
# a stale image (verify the committed lock against the image as-built, no side effects). Gates against
# the committed lock, not bit-reproducibility (Wolfi apk is a rolling repo).
cmd_lock_enforce() { _drift_report 1 strict "$@"; }

# `sluice lock --sbom [--format cyclonedx|spdx]`: a deterministic SBOM (apk + npm + pip + gem + go +
# cargo purls) to stdout. Assembled in-image (jq lives there); apk components carry their SHA-1 integrity
# hash (the db's Q1 checksum, hex-decoded). No timestamp/serial + purl-sorted so it's byte-stable;
# base/toolver/tag via env. Default CycloneDX 1.6; --format spdx emits the same package set as SPDX 2.3.
cmd_sbom() {
  local fmt=cyclonedx
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --format)   fmt="${2:-}"; [ -n "$fmt" ] || die "usage: sluice lock --sbom [--format cyclonedx|spdx]"; shift ;;
      --format=*) fmt="${1#--format=}" ;;
      *)          die "usage: sluice lock --sbom [--format cyclonedx|spdx]" ;;
    esac
    shift
  done
  case "$fmt" in cyclonedx|spdx) ;; *) die "invalid --sbom format '$fmt' (cyclonedx|spdx)" ;; esac
  maybe_build; _sbom_for "$tag" "$fmt"
}

# Emit the CycloneDX SBOM for an arbitrary image ref (introspected in-image). cmd_sbom passes the built
# project $tag; the hidden __sbom arm passes the base ref (so CI can attest the base's own SBOM).
_sbom_for() {
  local img="$1" baseref bdig
  baseref="${SLUICE_BASE_IMAGE:-cgr.dev/chainguard/wolfi-base}"
  bdig="$("$ENGINE" image inspect "$baseref" --format '{{ if .RepoDigests }}{{ index .RepoDigests 0 }}{{ end }}' 2>/dev/null || true)"
  "$ENGINE" run --rm -i -e "SBOM_BASE=${bdig:-$baseref}" -e "SBOM_TOOLVER=$SLUICE_VERSION" -e "SBOM_IMAGE=$img" \
    -e "SBOM_FORMAT=${2:-cyclonedx}" --entrypoint sh "$img" 2>/dev/null <<'SBOM'
SBOM_ARCH="$(apk --print-arch 2>/dev/null || uname -m)"; export SBOM_ARCH
{
  # apk: name, version, and the Q1<base64-sha1> checksum decoded to hex (4th field; empty if undecodable).
  awk 'BEGIN{RS="";FS="\n"}{p=v=c="";for(i=1;i<=NF;i++){t=substr($i,1,2);if(t=="P:")p=substr($i,3);else if(t=="V:")v=substr($i,3);else if(t=="C:")c=substr($i,3)}if(p!="")printf "%s\t%s\t%s\n",p,v,c}' /lib/apk/db/installed \
  | while IFS="$(printf '\t')" read -r p v c; do
      h=""; case "$c" in Q1*) h="$(printf '%s' "${c#Q1}" | base64 -d 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')";; esac
      printf 'apk\t%s\t%s\t%s\n' "$p" "$v" "$h"
    done
  npm ls -g --depth=0 --json 2>/dev/null | jq -r '(.dependencies // {})|to_entries[]|"npm\t\(.key)\t\(.value.version)\t"' 2>/dev/null
  command -v pip3 >/dev/null 2>&1 && su -s /bin/sh sluice -c 'HOME=/home/sluice pip3 list --format=json 2>/dev/null' 2>/dev/null | jq -r '.[]|"pip\t\(.key//.name|ascii_downcase)\t\(.value//.version)\t"' 2>/dev/null   # as sluice: system + --user site
  command -v pipx >/dev/null 2>&1 && su -s /bin/sh sluice -c 'HOME=/home/sluice pipx list --json 2>/dev/null' 2>/dev/null | jq -r '(.venvs//{})|to_entries[]|.value.metadata.main_package|"pip\t\(.package|ascii_downcase)\t\(.package_version)\t"' 2>/dev/null   # pipx venvs
  command -v gem  >/dev/null 2>&1 && gem list --local --quiet 2>/dev/null | awk '{name=$1;rest=$0;sub(/^[^(]*\(/,"",rest);sub(/\).*$/,"",rest);n=split(rest,vs,/, */);for(i=1;i<=n;i++){v=vs[i];sub(/^default: */,"",v);if(v!="")printf "gem\t%s\t%s\t\n",name,v}}'
  command -v go   >/dev/null 2>&1 && { gb=""; for d in "$(go env GOBIN 2>/dev/null)" "$(go env GOPATH 2>/dev/null)/bin" /home/sluice/go/bin; do [ -n "$d" ] && [ -d "$d" ] || continue; case " $gb " in *" $d "*) ;; *) gb="$gb $d";; esac; done; for d in $gb; do for f in "$d"/*; do [ -f "$f" ] && [ -x "$f" ] || continue; go version -m "$f" 2>/dev/null | awk '$1=="mod"{printf "go\t%s\t%s\t\n",$2,$3; exit}'; done; done; }
  command -v cargo >/dev/null 2>&1 && { for ch in "${CARGO_HOME:-$HOME/.cargo}" /home/sluice/.cargo /root/.cargo; do [ -f "$ch/.crates2.json" ] || continue; jq -r '.installs|keys[]|split(" ")|"cargo\t\(.[0])\t\(.[1])\t"' "$ch/.crates2.json" 2>/dev/null; break; done; }
  true
} | jq -R -s '
  ( [ split("\n")[] | select(length>0) | split("\t")
      | { eco:.[0], name:.[1], version:.[2], hash:.[3] }
      | .purl = ( if   .eco=="apk"   then "pkg:apk/wolfi/"+.name+"@"+.version+"?arch="+env.SBOM_ARCH+"&distro=wolfi"
                  elif .eco=="npm"   then "pkg:npm/"+.name+"@"+.version
                  elif .eco=="pip"   then "pkg:pypi/"+.name+"@"+.version
                  elif .eco=="go"    then "pkg:golang/"+.name+"@"+.version
                  elif .eco=="cargo" then "pkg:cargo/"+.name+"@"+.version
                  else                    "pkg:gem/"+.name+"@"+.version end ) ]
    | unique_by(.purl) ) as $pkgs
  | if env.SBOM_FORMAT=="spdx"
    then { spdxVersion:"SPDX-2.3", dataLicense:"CC0-1.0", SPDXID:"SPDXRef-DOCUMENT",
           name:env.SBOM_IMAGE, documentNamespace:("https://sluice.invalid/"+env.SBOM_IMAGE),
           creationInfo:{ created:"1970-01-01T00:00:00Z", creators:[ "Tool: sluice-"+env.SBOM_TOOLVER ] },
           annotations:[ { annotationType:"OTHER", annotationDate:"1970-01-01T00:00:00Z",
                           annotator:("Tool: sluice-"+env.SBOM_TOOLVER), comment:("sluice:base "+env.SBOM_BASE) } ],
           packages:[ $pkgs[] | { SPDXID:("SPDXRef-Package-"+(.purl|gsub("[^A-Za-z0-9.-]";"-"))),
                                  name:.name, versionInfo:.version, downloadLocation:"NOASSERTION",
                                  externalRefs:[ { referenceCategory:"PACKAGE-MANAGER", referenceType:"purl", referenceLocator:.purl } ] }
                              + ( if (.hash // "") != "" then { checksums:[ { algorithm:"SHA1", checksumValue:.hash } ] } else {} end ) ],
           relationships:[ $pkgs[] | { spdxElementId:"SPDXRef-DOCUMENT", relationshipType:"DESCRIBES",
                                       relatedSpdxElement:("SPDXRef-Package-"+(.purl|gsub("[^A-Za-z0-9.-]";"-"))) } ] }
    else { bomFormat:"CycloneDX", specVersion:"1.6", version:1,
           metadata:{
             tools:{ components:[ { type:"application", name:"sluice", version:env.SBOM_TOOLVER } ] },
             component:{ type:"container", name:env.SBOM_IMAGE,
                         properties:[ { name:"sluice:base", value:env.SBOM_BASE } ] } },
           components: [ $pkgs[] | { type:"library", "bom-ref":.purl, name:.name, version:.version, purl:.purl }
                                   + ( if (.hash // "") != "" then { hashes:[ { alg:"SHA-1", content:.hash } ] } else {} end ) ] }
    end'
SBOM
}

# `sluice lock --scan [--json] [--fail-on <sev>]`: vuln-scan the box's SBOM with a HOST scanner (grype,
# else trivy - never baked, same as cosign-verify). Report-only by default; --fail-on <severity>
# (negligible|low|medium|high|critical) makes it a CI gate.
# Exit contract (normalized across scanners, since grype/trivy disagree on raw codes - grype exits 2 on
# a gated finding but 1 on a DB error, trivy exits 1 on a gated finding): 0 = clean, 3 = gate tripped
# (a finding at/above --fail-on), 4 = scanner failed to run (DB/catalog/parse error). Documented in
# docs/supply-chain.md.
cmd_scan() {
  local json=0 failon=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)      json=1 ;;
      --fail-on)   failon="${2:-}"; [ -n "$failon" ] || die "usage: sluice lock --scan [--json] [--fail-on <severity>]"; shift ;;
      --fail-on=*) failon="${1#--fail-on=}" ;;
      *)           die "usage: sluice lock --scan [--json] [--fail-on <negligible|low|medium|high|critical>]" ;;
    esac
    shift
  done
  if [ -n "$failon" ]; then
    case "$failon" in negligible|low|medium|high|critical) ;; *) die "invalid --fail-on '$failon' (negligible|low|medium|high|critical)" ;; esac
  fi

  # Prefer grype (CycloneDX-native); trivy had a 2026 supply-chain compromise, so only as a fallback.
  local scanner=""
  if   command -v grype >/dev/null 2>&1; then scanner=grype
  elif command -v trivy >/dev/null 2>&1; then scanner=trivy; fi
  if [ -z "$scanner" ]; then
    if [ -n "$failon" ]; then die "no vulnerability scanner found but --fail-on was given - install grype to gate on CVEs (https://github.com/anchore/grype)"; fi
    echo "[sluice] ${E_YEL}note${E_RST}: no scanner found - install grype to enable 'lock --scan' (https://github.com/anchore/grype)" >&2
    return 0
  fi

  maybe_build
  local tmp rc; tmp="$(mktemp)"
  # A8: trap the temp NOW so a cmd_sbom failure under pipefail (which aborts before the trailing rm)
  # can't leak it - the lock arm arms no receipt, so this EXIT trap has nothing to clobber.
  # shellcheck disable=SC2064  # expand $tmp NOW: the local is gone when the trap fires
  trap "rm -f '$tmp'" EXIT
  cmd_sbom > "$tmp"   # reuse the CycloneDX SBOM; the inner maybe_build is a no-op now, so $tmp is clean
  # C3: report-only (no --fail-on) prints the bare scanner table with nothing signalling it did NOT gate;
  # frame it on stderr (exit 0 regardless; --fail-on <sev> turns it into a gate). --json stays a clean passthrough.
  if [ -z "$failon" ] && [ "$json" = 0 ]; then
    echo "[sluice] ${E_DIM}report-only scan (exit 0 regardless) - add --fail-on <negligible|low|medium|high|critical> to gate the build.${E_RST}" >&2
  fi
  if [ "$scanner" = grype ]; then
    local ga=(sbom:"$tmp")
    if [ "$json" = 1 ]; then ga+=(-o json); else ga+=(-o table); fi
    if [ -n "$failon" ]; then ga+=(--fail-on "$failon"); fi
    grype "${ga[@]}" && rc=0 || rc=$?
  else
    local sev=""
    case "$failon" in
      critical)   sev=CRITICAL ;;
      high)       sev=HIGH,CRITICAL ;;
      medium)     sev=MEDIUM,HIGH,CRITICAL ;;
      low)        sev=LOW,MEDIUM,HIGH,CRITICAL ;;
      negligible) sev=UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL ;;
    esac
    local ta=(sbom)
    if [ "$json" = 1 ]; then ta+=(--format json); else ta+=(--format table); fi
    # --exit-code 3 (not 1) so trivy's gate-trip is distinguishable from its generic error exit (1).
    if [ -n "$failon" ]; then ta+=(--severity "$sev" --exit-code 3); fi
    trivy "${ta[@]}" "$tmp" && rc=0 || rc=$?
  fi
  rm -f "$tmp"
  # Normalize the raw scanner rc to the sluice contract: 0 clean, 3 gate tripped, 4 scanner failed.
  # grype: 2 = fail-on matched. trivy: 3 = our --exit-code on a finding. Any OTHER non-zero = the
  # scanner broke (DB/catalog/parse), which must read differently from "a CVE gate tripped".
  case "$scanner/$rc" in
    */0)     rc=0 ;;
    grype/2) rc=3 ;;
    trivy/3) rc=3 ;;
    *)       rc=4 ;;
  esac
  return "$rc"
}

# `sluice doctor`: one-shot health + why-egress-is-blocked report
