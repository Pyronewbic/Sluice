# --- in-repo protection scans (SLUICE_MASK; read by doctor here and mounted by the run path) ------

# Expand SLUICE_MASK (space-separated, project-root-relative globs) to the paths matching RIGHT NOW,
# one per line. Plain shell glob semantics: a slash-less pattern matches root-level entries only
# ("packages/*/.env" reaches deeper). Symlink matches are skipped - a mount over a link would shadow
# its TARGET, not the link. Invalid patterns (absolute, ..) are skipped here so doctor still reports
# the rest; the run path dies on them (mask_validate).
mask_matches() {
  [ -n "${SLUICE_MASK:-}" ] || return 0
  ( cd "$PROJECT_DIR" 2>/dev/null || exit 0
    set -f   # keep the PATTERNS literal while splitting; glob only in the inner loop
    for pat in ${SLUICE_MASK}; do
      case "$pat" in /*|*..*) continue ;; esac
      set +f
      for m in $pat; do
        [ -L "$m" ] && continue
        if [ -f "$m" ] || [ -d "$m" ]; then printf '%s\n' "$m"; fi
      done
      set -f
    done ) | sort -u
}

# True when some SLUICE_MASK pattern covers $1 (a project-relative path), mirroring the launch
# semantics above: a slash-less pattern only ever matches a root-level entry.
mask_covers() {
  local rel="$1" pat rc=1
  set -f   # the patterns must stay literal (case still glob-MATCHES under set -f)
  for pat in ${SLUICE_MASK:-}; do
    # shellcheck disable=SC2254  # $pat IS a glob - unquoted on purpose
    case "$pat" in
      /*|*..*) continue ;;
      */*) case "$rel" in $pat) rc=0; break ;; esac ;;
      *)   case "$rel" in */*) ;; $pat) rc=0; break ;; esac ;;
    esac
  done
  set +f
  return "$rc"
}

# Secret-looking files in the mount that no SLUICE_MASK pattern covers - doctor warns on these.
# Bounded so doctor stays fast: depth 3, vendor dirs pruned, first 50 WARNED (unmasked) hits.
# .example/.sample/.template variants are scaffolding, not secrets. The mask filter runs BEFORE the
# cap - capping raw find output (filesystem order) would let masked files eat the slots and hide a
# genuinely-unmasked secret past the cap (a false pass). The find is depth-limited + vendor-pruned,
# so the candidate set is small.
unmasked_secrets() {
  find "$PROJECT_DIR" -maxdepth 3 \
      \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv \) -prune \
      -o -type f \( -name '.env*' -o -name '*.pem' -o -name '*key*.json' -o -name 'id_rsa*' \
                    -o -name 'id_ed25519*' -o -name '*.p12' -o -name '*.pfx' \) \
      ! -name '*.example' ! -name '*.sample' ! -name '*.template' -print 2>/dev/null \
    | while IFS= read -r f; do
        f="${f#"$PROJECT_DIR"/}"
        mask_covers "$f" || printf '%s\n' "$f"
      done | head -50
}

# Squash //, /./ and resolve .. TEXTUALLY (no symlink deref - the target may not exist). Enough to
# decide inside-vs-outside the mount; set -f keeps odd path segments from globbing.
_canon_path() {
  local p="$1" out="" seg oldIFS="$IFS"
  set -f; IFS=/
  for seg in $p; do
    case "$seg" in ''|.) ;; ..) out="${out%/*}" ;; *) out="$out/$seg" ;; esac
  done
  IFS="$oldIFS"; set +f
  printf '%s' "${out:-/}"
}

# Symlinks in the project dir whose target resolves OUTSIDE the mounted scope (the project dir, plus
# the git common dir when this is a worktree) - they work on the host but are broken inside the box
# (real case: .claude/CLAUDE.md -> ~/.claude/shared/... dangled silently and the agent ran without
# its instructions). Emits "rel<TAB>target". Bounded so doctor stays fast: depth 6, .git/vendor dirs
# pruned, first 200 links considered.
symlinks_outside_scope() {
  local proj common="" l tgt abs d TAB; TAB="$(printf '\t')"
  # Compare PHYSICAL paths throughout - on macOS /var is itself a symlink, and git reports the
  # common dir in physical form while $PROJECT_DIR/link targets may be logical.
  proj="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P || printf '%s' "$PROJECT_DIR")"
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --git-common-dir >/dev/null 2>&1; then
    common="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir)"
    case "$common" in /*) ;; *) common="$PROJECT_DIR/$common";; esac
    common="$(cd "$common" 2>/dev/null && pwd -P || true)"
    case "$common/" in "$proj"/*) common="" ;; esac   # inside the project: already in scope
  fi
  find "$PROJECT_DIR" -maxdepth 6 \
      \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv \
         -o -name target -o -name dist -o -name build -o -name .next -o -name __pycache__ \) -prune \
      -o -type l -print 2>/dev/null \
    | head -200 | while IFS= read -r l; do
        tgt="$(readlink "$l" 2>/dev/null)" || continue
        [ -n "$tgt" ] || continue
        case "$tgt" in /*) abs="$tgt" ;; *) abs="$(dirname "$l")/$tgt" ;; esac
        # physical resolution when the target's parent exists; textual squash for dangling targets
        if d="$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)"; then abs="$d/$(basename "$abs")"
        else abs="$(_canon_path "$abs")"; fi
        case "$abs/" in "$proj"/*|"$PROJECT_DIR"/*) continue ;; esac
        if [ -n "$common" ]; then case "$abs/" in "$common"/*) continue ;; esac; fi
        printf '%s%s%s\n' "${l#"$PROJECT_DIR"/}" "$TAB" "$tgt"
      done
}

_doc() { printf '  %-10s %s\n' "$1" "$2"; }

# Run a command with a wall-clock bound so doctor never hangs on a black-hole engine (a wedged
# DOCKER_HOST makes `info`/`image inspect` block for 20s+). Uses timeout/gtimeout when present;
# stock macOS has neither, so fall back to a background pid + a killer that SIGKILLs it past the
# bound. Returns the command's status, or 124 on timeout (matching coreutils `timeout`). The killer
# is itself reaped so the fallback can't hang. bash-3.2 safe (no associative arrays, no `wait -n`).
_with_timeout() {
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  local pid kpid rc
  "$@" & pid=$!
  ( sleep "$secs"; kill -KILL "$pid" 2>/dev/null ) & kpid=$!
  if wait "$pid" 2>/dev/null; then rc=$?; else rc=$?; fi
  kill -KILL "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null || true
  # 137 = 128+SIGKILL: the killer fired (timed out) -> normalize to coreutils' 124.
  [ "$rc" -eq 137 ] && rc=124
  return "$rc"
}

cmd_doctor() {
  [ "${1:-}" = --json ] && { cmd_doctor_json; return $?; }
  local eng="" v blocked
  printf '%ssluice doctor%s\n' "$C_BLD" "$C_RST"
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  if [ -n "$eng" ] && command -v "$eng" >/dev/null 2>&1; then
    ENGINE="$eng"; resolve_runner lenient
    if _with_timeout 5 "$eng" info >/dev/null 2>&1; then   # bound the probe: a black-hole DOCKER_HOST blocks 20s+
      _doc engine "$("$eng" --version 2>/dev/null | head -1)"
    else
      _doc engine "${C_RED}$("$eng" --version 2>/dev/null | head -1) - daemon not responding${C_RST} (is $eng running?)"
      eng=""   # daemon down (or wedged/timed out): skip the engine-dependent checks below
    fi
  elif [ -n "${SLUICE_ENGINE:-}" ]; then
    # Explicitly named but absent: "install docker or podman" is the wrong remedy. Mirror resolve_engine's die.
    eng=""; _doc engine "${C_RED}none${C_RST} - SLUICE_ENGINE='$SLUICE_ENGINE' not found on PATH"
  else
    eng=""; _doc engine "${C_RED}none${C_RST} - install docker or podman"
  fi

  if ! PROJECT_CONFIG="$(find_config)"; then
    _doc config "${C_RED}none${C_RST} - run 'sluice init' to scaffold one"; return 0
  fi
  PROJECT_DIR="$(cd "$(dirname "$PROJECT_CONFIG")" && pwd)"
  # Doctor is the command you run BECAUSE the config is broken, so a broken config must not abort it.
  # bash -n catches syntax errors; relaxing errexit around the source keeps a non-zero top-level line
  # from killing doctor. A literal top-level `exit` in the config still escapes (it can't be contained
  # without a subshell that would drop the vars derive_names + the report below need) - known limit.
  if bash -n "$PROJECT_CONFIG" 2>/dev/null; then
    _doc config "$(_tilde "$PROJECT_CONFIG")"
  else
    _doc config "${C_RED}$(_tilde "$PROJECT_CONFIG") (parse error)${C_RST} - 'bash -n' it; report continues with partial config"
  fi
  # shellcheck disable=SC1090
  set +e; . "$PROJECT_CONFIG" 2>/dev/null; set -e
  derive_names
  [ -n "${SLUICE_DESC:-}" ] && _doc desc "$SLUICE_DESC"
  if [ -n "${SLUICE_MOUNTS:-}" ]; then
    _doc mount "$(_tilde "$PROJECT_DIR") ${C_DIM}(+ extra mounts)${C_RST}"
    # List each extra bind + warn on a missing absolute host source (the engine errors on it at run).
    local _m _src
    set -f   # keep mount specs literal while splitting - no pathname expansion against $PWD
    for _m in ${SLUICE_MOUNTS}; do
      set +f
      _src="${_m%%:*}"
      case "$_src" in
        /*) if [ ! -e "$_src" ]; then _doc "" "${C_DIM}$(_term_esc "$_m")${C_RST} ${C_YEL}host path not found - run will fail${C_RST}"
            else _doc "" "${C_DIM}$(_term_esc "$_m")${C_RST}"; fi ;;
        *)  _doc "" "${C_DIM}$(_term_esc "$_m")${C_RST}" ;;
      esac
      set -f
    done
    set +f
  else _doc mount "$(_tilde "$PROJECT_DIR")"; fi

  # SLUICE_MASK posture: what's shadowed now, and secret-looking files the box CAN still read.
  if [ -n "${SLUICE_MASK:-}" ]; then
    local _nm; _nm="$(mask_matches 2>/dev/null | grep -c . || true)"
    _doc mask "$SLUICE_MASK ${C_DIM}($_nm path(s) masked at launch)${C_RST}"
  fi
  local _unm
  _unm="$(unmasked_secrets 2>/dev/null | head -6 | tr '\n' ' ' | sed 's/ *$//' || true)"
  [ -n "$_unm" ] && _doc "" "${C_YEL}note${C_RST}: secret-looking file(s) readable in the box - $(_term_esc "$_unm") - shadow them: SLUICE_MASK=\".env*\" (sluice.config.example.sh)"

  # Symlinks that leave the mounted scope work on the host but dangle inside the box - warn.
  local _links _nl _lp _lt _TAB; _TAB="$(printf '\t')"
  _links="$(symlinks_outside_scope 2>/dev/null || true)"
  if [ -n "$_links" ]; then
    _nl="$(printf '%s\n' "$_links" | grep -c . || true)"
    _doc symlinks "${C_YEL}$_nl link(s) point outside the box mount${C_RST} - will be broken inside the box:"
    printf '%s\n' "$_links" | head -10 | while IFS="$_TAB" read -r _lp _lt; do
      printf '             %s -> %s\n' "$(_term_esc "$_lp")" "$(_term_esc "$_lt")"
    done
    [ "$_nl" -gt 10 ] && _doc "" "${C_DIM}(+ $((_nl - 10)) more)${C_RST}"
  fi

  if [ -n "$eng" ]; then
    if _with_timeout 5 "$eng" image inspect "$tag" >/dev/null 2>&1; then
      if [ "$(_with_timeout 5 "$eng" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)" = "$(config_hash)" ]; then
        _doc image "$tag built (${C_GRN}config current${C_RST})"
      else
        _doc image "$tag built (${C_YEL}config stale${C_RST} - run 'sluice rebuild')"
      fi
    else
      _doc image "$tag ${C_DIM}not built${C_RST} - run 'sluice build'"
    fi
  fi

  if [ -f "$PROJECT_DIR/sluice.lock" ]; then
    if [ -n "$eng" ] && _with_timeout 5 "$eng" image inspect "$tag" >/dev/null 2>&1; then
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
    _doc state "$nsd dir(s) persisted at $(_tilde "${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug")"
  fi

  [ -n "${SLUICE_OVERLAY_DIRS:-}" ] && _doc overlays "$SLUICE_OVERLAY_DIRS ${C_DIM}(box-local volume per dir, host contents untouched; 'sluice rm' deletes)${C_RST}"

  [ -n "${SLUICE_BASE_IMAGE:-}" ] && _doc base "$SLUICE_BASE_IMAGE ${C_DIM}(signed-base build; SLUICE_REQUIRE_SIGNED=${SLUICE_REQUIRE_SIGNED:-0})${C_RST}"
  # Active hardening posture (only the opt-ins that are on), so it's visible at a glance.
  local _hard=""
  [ -n "${SLUICE_SECCOMP:-}" ]          && _hard="$_hard seccomp=$SLUICE_SECCOMP"
  [ "${SLUICE_READONLY_ROOT:-}" = 1 ]   && _hard="$_hard readonly-root"
  [ "${SLUICE_WORKSPACE:-}" = overlay ] && _hard="$_hard workspace=overlay"
  [ -n "${SLUICE_RUNTIME:-}" ]          && _hard="$_hard runtime=$SLUICE_RUNTIME"
  [ -n "${SLUICE_MEMORY:-}" ]           && _hard="$_hard memory=$SLUICE_MEMORY"
  [ -n "${SLUICE_BUMP_DOMAINS:-}" ]     && _hard="$_hard tls-bump"
  [ -n "$_hard" ] && _doc harden "${_hard# }"

  [ -n "${SLUICE_PORTS:-}" ] && _doc ports "$SLUICE_PORTS ${C_DIM}(published on 127.0.0.1)${C_RST}"
  _doc allowlist "${SLUICE_ALLOW_DOMAINS:-(none beyond base)}"
  _doc "" "base: $(base_domains)"
  local _risky="" _doh="" _h
  set -f   # the allowlist entries are not globs - keep a wildcard (e.g. *.s3.amazonaws.com) literal
  for _h in ${SLUICE_ALLOW_DOMAINS:-}; do
    laundering_host "$_h" && _risky="$_risky $_h"
    doh_listed "$_h" && _doh="$_doh $_h"
  done
  set +f
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
  local eng="" engine_ver="" daemon=false engine_found=true
  if   [ -n "${SLUICE_ENGINE:-}" ]; then eng="$SLUICE_ENGINE"
  elif command -v docker >/dev/null 2>&1; then eng=docker
  elif command -v podman >/dev/null 2>&1; then eng=podman; fi
  if [ -n "$eng" ] && command -v "$eng" >/dev/null 2>&1; then
    ENGINE="$eng"; resolve_runner lenient; engine_ver="$("$eng" --version 2>/dev/null | head -1)"
    # Bound the probe (A3): a wedged DOCKER_HOST otherwise blocks doctor 20s+. timeout -> daemon:false.
    _with_timeout 5 "$eng" info >/dev/null 2>&1 && daemon=true || eng=""
  else eng=""; [ -z "${SLUICE_ENGINE:-}" ] || engine_found=false; fi   # explicit-but-missing engine: A9

  if ! PROJECT_CONFIG="$(find_config)"; then
    printf '{"engine":"%s","engine_found":%s,"daemon":%s,"config":null}\n' "$(_json_esc "$engine_ver")" "$engine_found" "$daemon"; return 0
  fi
  PROJECT_DIR="$(cd "$(dirname "$PROJECT_CONFIG")" && pwd)"
  # A broken config must not abort doctor: bash -n catches syntax errors; relaxed errexit around the
  # source keeps a non-zero top-level line from killing it. A literal `exit` in the config still
  # escapes (can't be contained without a subshell that drops the vars below) - known limit. Either
  # way this path ALWAYS prints one valid JSON object (config_error carries the signal), never empty.
  local config_error=false
  bash -n "$PROJECT_CONFIG" 2>/dev/null || config_error=true
  # shellcheck disable=SC1090
  set +e; . "$PROJECT_CONFIG" 2>/dev/null; set -e
  derive_names

  local img_built=false img_stale=false
  if [ -n "$eng" ] && _with_timeout 5 "$eng" image inspect "$tag" >/dev/null 2>&1; then
    img_built=true
    [ "$(_with_timeout 5 "$eng" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)" = "$(config_hash)" ] || img_stale=true
  fi

  local lock="none"
  if [ -f "$PROJECT_DIR/sluice.lock" ]; then
    if [ -n "$eng" ] && _with_timeout 5 "$eng" image inspect "$tag" >/dev/null 2>&1; then
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

  local mask_pats mask_hits mask_unm links_json
  # tr (not word-splitting) keeps the glob patterns literal - no pathname expansion against $PWD
  mask_pats="$(printf '%s' "${SLUICE_MASK:-}" | tr ' \t' '\n\n' | _json_arr)"
  mask_hits="$(mask_matches 2>/dev/null | _json_arr || true)"
  mask_unm="$(unmasked_secrets 2>/dev/null | _json_arr || true)"
  links_json="$(symlinks_outside_scope 2>/dev/null | cut -f1 | _json_arr || true)"
  local overlays_json
  overlays_json="$(printf '%s' "${SLUICE_OVERLAY_DIRS:-}" | tr ' \t' '\n\n' | _json_arr)"

  # Hardening posture: which opt-in layers are active (pure config reads, no engine calls).
  local _ro=false _ws=false _bump=false
  [ "${SLUICE_READONLY_ROOT:-}" = 1 ]   && _ro=true
  [ "${SLUICE_WORKSPACE:-}" = overlay ] && _ws=true
  [ -n "${SLUICE_BUMP_DOMAINS:-}" ]     && _bump=true
  local hardening_json
  hardening_json="$(printf '{"seccomp":"%s","readonly_root":%s,"workspace_overlay":%s,"runtime":"%s","memory":"%s","pids_limit":"%s","tls_bump":%s}' \
    "$(_json_esc "${SLUICE_SECCOMP:-default}")" "$_ro" "$_ws" "$(_json_esc "${SLUICE_RUNTIME:-}")" \
    "$(_json_esc "${SLUICE_MEMORY:-}")" "$(_json_esc "${SLUICE_PIDS_LIMIT:-4096}")" "$_bump")"

  # Exfil-surface risk: allowlisted hosts that are writable laundering channels or DoH resolvers.
  local _risky="" _doh="" _h _allowdoh=false
  set -f   # entries are not globs - keep a wildcard (e.g. *.s3.amazonaws.com) literal, no expansion
  for _h in ${SLUICE_ALLOW_DOMAINS:-}; do
    laundering_host "$_h" && _risky="$_risky$_h
"
    doh_listed "$_h" && _doh="$_doh$_h
"
  done
  set +f
  [ "${SLUICE_ALLOW_DOH:-}" = 1 ] && _allowdoh=true
  local risk_json
  risk_json="$(printf '{"laundering_hosts":%s,"doh_hosts":%s,"allow_doh":%s}' \
    "$(printf '%s' "$_risky" | _json_arr)" "$(printf '%s' "$_doh" | _json_arr)" "$_allowdoh")"

  # Extra binds as objects, each carrying whether its host source exists (a missing absolute source
  # passes doctor today but errors the engine at run - A7). set -f keeps a glob-y spec literal (A5).
  local mounts_json="[" _mf=1 _m _src _ex
  set -f
  for _m in ${SLUICE_MOUNTS:-}; do
    set +f
    _src="${_m%%:*}"; _ex=true
    case "$_src" in /*) [ -e "$_src" ] || _ex=false ;; esac
    [ "$_mf" = 1 ] && _mf=0 || mounts_json="$mounts_json,"
    mounts_json="$mounts_json{\"spec\":\"$(_json_esc "$_m")\",\"exists\":$_ex}"
    set -f
  done
  set +f
  mounts_json="$mounts_json]"

  # A5: build these arrays via the tr-split idiom (mask/overlay use it) - NOT `printf '%s\n' $unquoted`,
  # which pathname-expands a glob metachar in config (e.g. SLUICE_ALLOW_IPS="1.2.3.4 *") against $PWD.
  local allow_json ports_json ips_json blocked_json
  allow_json="$(printf '%s'   "${SLUICE_ALLOW_DOMAINS:-}" | tr ' \t' '\n\n' | _json_arr)"
  ports_json="$(printf '%s'   "${SLUICE_PORTS:-}"         | tr ' \t' '\n\n' | _json_arr)"
  ips_json="$(printf '%s'     "${SLUICE_ALLOW_IPS:-}"     | tr ' \t' '\n\n' | _json_arr)"
  blocked_json="$(printf '%s' "$blocked"                  | tr ' \t' '\n\n' | _json_arr)"

  printf '{"engine":"%s","engine_found":%s,"daemon":%s,"config":"%s","config_error":%s,"project_dir":"%s","name":"%s","desc":"%s","image":{"tag":"%s","built":%s,"stale":%s},"lock":"%s","allowlist":%s,"base":%s,"ports":%s,"allow_ips":%s,"base_image":"%s","policy_url":"%s","state_dirs":%s,"overlay_dirs":%s,"mounts":%s,"auth":%s,"hardening":%s,"mask":{"patterns":%s,"masked":%s,"unmasked_secrets":%s},"risk":%s,"broken_symlinks":%s,"egress":{"running":%s,"blocked":%s}}\n' \
    "$(_json_esc "$engine_ver")" "$engine_found" "$daemon" "$(_json_esc "$PROJECT_CONFIG")" "$config_error" "$(_json_esc "$PROJECT_DIR")" "$(_json_esc "$tag")" "$(_json_esc "${SLUICE_DESC:-}")" \
    "$(_json_esc "$tag")" "$img_built" "$img_stale" "$lock" \
    "$allow_json" "$(base_domains | tr ' ' '\n' | _json_arr)" \
    "$ports_json" "$ips_json" "$(_json_esc "${SLUICE_BASE_IMAGE:-}")" \
    "$(_json_esc "${SLUICE_POLICY_URL:-}")" "$nsd" "$overlays_json" "$mounts_json" "$auth_json" "$hardening_json" \
    "$mask_pats" "$mask_hits" "$mask_unm" "$risk_json" "$links_json" \
    "$running_b" "$blocked_json"
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
  local names=() stats=() projs=() stacks=() descs=() curs=() orphs=() allows=() ports_=() locks=() blocks=() ovls=()
  local name proj stack desc status cur orphan allowcount portslbl lock blocked ovl
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    proj="$( "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.project" }}' "$name" 2>/dev/null || true)"
    stack="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.stack" }}'   "$name" 2>/dev/null || true)"
    desc="$( "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.desc" }}'    "$name" 2>/dev/null || true)"
    allowcount="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.allowcount" }}' "$name" 2>/dev/null || true)"
    portslbl="$(  "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.ports" }}'      "$name" 2>/dev/null || true)"
    ovl="$(       "$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.overlays" }}'   "$name" 2>/dev/null || true)"
    case "$proj"       in "<no value>") proj=""       ;; esac
    case "$stack"      in "<no value>") stack=""      ;; esac
    case "$desc"       in "<no value>") desc=""       ;; esac
    case "$allowcount" in "<no value>") allowcount="" ;; esac
    case "$portslbl"   in "<no value>") portslbl=""   ;; esac
    case "$ovl"        in "<no value>") ovl=""        ;; esac
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
    allows+=("$allowcount"); ports_+=("$portslbl"); locks+=("$lock"); blocks+=("$blocked"); ovls+=("$ovl")
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

  local i j ac lk pjson ojson bjson
  if [ "$mode" = --json ]; then
    printf '['
    for j in "${!order[@]}"; do
      i="${order[$j]}"
      [ "$j" -gt 0 ] && printf ','
      ac="${allows[$i]}"; [ -n "$ac" ] || ac=null              # null = un-rebuilt box (label absent), not 0
      lk=false; [ "${locks[$i]}" = locked ] && lk=true
      # shellcheck disable=SC2086
      pjson="$(printf '%s\n' ${ports_[$i]} | _json_arr)"
      ojson="$(printf '%s' "${ovls[$i]}" | tr ' \t' '\n\n' | _json_arr)"
      bjson=""; if [ -n "$egress" ]; then
        if [ "${stats[$i]}" = running ]; then bjson=",\"blocked\":${blocks[$i]:-0}"; else bjson=',"blocked":null'; fi
      fi
      printf '{"name":"%s","status":"%s","stack":"%s","path":"%s","description":"%s","current":%s,"orphan":%s,"allow_count":%s,"ports":%s,"overlay_dirs":%s,"locked":%s%s}' \
        "$(_json_esc "${names[$i]}")" "$(_json_esc "${stats[$i]}")" "$(_json_esc "${stacks[$i]}")" \
        "$(_json_esc "${projs[$i]}")" "$(_json_esc "${descs[$i]}")" "${curs[$i]}" "${orphs[$i]}" \
        "$ac" "$pjson" "$ojson" "$lk" "$bjson"
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
