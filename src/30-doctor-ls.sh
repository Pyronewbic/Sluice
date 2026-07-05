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

# Render a newline-separated list (stdin) as indented doctor bullets, capped at the first 10 with a
# "(+ N more)" tail - the shape the secret/symlink/blocked-host lists share. $1 = the SGR color for
# each item (e.g. $C_RED), default none. Items are run through _term_esc (control chars stripped) so a
# crafted hostname can't smuggle escapes into the readout. PURE: reads stdin, writes stdout, touches no
# globals/engine - so it's unit-testable in the no-Docker gate. Blank lines drop from the count + output.
_doctor_bullets() {
  local col="${1:-}" rst="" list n line
  [ -n "$col" ] && rst="$C_RST"
  list="$(cat)"                                   # slurp stdin once, then count + iterate from it
  n="$(printf '%s\n' "$list" | grep -c . || true)"
  [ "${n:-0}" -gt 0 ] || return 0
  printf '%s\n' "$list" | grep . | head -10 | while IFS= read -r line; do
    printf '             %s%s%s\n' "$col" "$(_term_esc "$line")" "$rst"
  done
  [ "$n" -gt 10 ] && printf '             %s(+ %s more)%s\n' "$C_DIM" "$((n - 10))" "$C_RST"
  return 0
}

# --- central egress policy (v2): deny-capable, ceiling-setting ------------------------------------
# Defined HERE (not next to apply_policy in the run-path slice) so the machinery exists before the
# early `doctor` dispatch can call policy_evaluate report-only. Sources, lowest trust first (a
# deny/forbid from ANY source is final): $SLUICE_POLICY_URL (env, per user/CI),
# ~/.config/sluice/policy.conf (user), /etc/sluice/policy.conf (root-owned - the org's MANAGED policy;
# tamper-resistant ONLY because a dev can't edit it without root, and the org pushes it). OSS ships the
# enforcement; the can't-remove-it property is the org's root-owned-file deployment. Line directives (a
# bare host = allow, back-compat): allow H | deny H | deny-ip CIDR | forbid SLUICE_X | forbid-laundering
# | max-allow-ips N. Host-side final gate BEFORE build/run (apply_policy): effective allowlist = (local
# + allow) - deny; a forbidden loosening knob / laundering host / denied or over-cap ALLOW_IPS makes us
# DIE. Inert when no policy is configured. A URL-fetched policy can be authenticated
# (SLUICE_POLICY_SIG/_IDENTITY cosign, or SLUICE_POLICY_SHA256 pin; _REQUIRE fails closed).
policy_configured() { [ -n "${SLUICE_POLICY_URL:-}" ] || [ -f "$HOME/.config/sluice/policy.conf" ] || [ -f /etc/sluice/policy.conf ]; }

# Authenticate the URL-fetched policy body (the untrusted source; the root-owned /etc file is
# filesystem-trusted). Fails CLOSED. SLUICE_POLICY_SHA256 pins the body hash (no cosign needed);
# SLUICE_POLICY_SIG (a cosign sign-blob bundle, path or URL) + SLUICE_POLICY_IDENTITY (expected signer
# regexp, + SLUICE_POLICY_ISSUER) verifies the signature; SLUICE_POLICY_REQUIRE=1 makes an unverifiable
# policy fatal even if neither is set.
_verify_policy_sig() {
  local body="$1" tmp sig sf got issuer="${SLUICE_POLICY_ISSUER:-https://token.actions.githubusercontent.com}"
  if [ -n "${SLUICE_POLICY_SHA256:-}" ]; then
    got="$(printf '%s' "$body" | _sha256)"
    [ "$got" = "$SLUICE_POLICY_SHA256" ] || die "policy body sha256 ($got) != pinned SLUICE_POLICY_SHA256 - refusing."
  fi
  if [ -n "${SLUICE_POLICY_SIG:-}" ]; then
    command -v cosign >/dev/null 2>&1 || die "SLUICE_POLICY_SIG is set but cosign is not installed - can't verify the policy signature."
    [ -n "${SLUICE_POLICY_IDENTITY:-}" ] || die "SLUICE_POLICY_SIG is set but SLUICE_POLICY_IDENTITY (expected signer) is not - refusing to verify against any identity."
    tmp="$(mktemp)"; printf '%s' "$body" > "$tmp"; sig="$SLUICE_POLICY_SIG"
    case "$sig" in http://*|https://*|file://*)
      sf="$(mktemp)"; curl -fsSL --max-time 10 "$SLUICE_POLICY_SIG" > "$sf" 2>/dev/null || { rm -f "$tmp" "$sf"; die "could not fetch SLUICE_POLICY_SIG=$SLUICE_POLICY_SIG"; }; sig="$sf" ;;
    esac
    if cosign verify-blob "$tmp" --bundle "$sig" \
         --certificate-identity-regexp "$SLUICE_POLICY_IDENTITY" --certificate-oidc-issuer "$issuer" >/dev/null 2>&1; then
      rm -f "$tmp"; [ -n "${sf:-}" ] && rm -f "$sf"
    else
      rm -f "$tmp"; [ -n "${sf:-}" ] && rm -f "$sf"
      die "policy signature verification failed (expected signer $SLUICE_POLICY_IDENTITY) - refusing."
    fi
  fi
  if [ "${SLUICE_POLICY_REQUIRE:-}" = 1 ] && [ -z "${SLUICE_POLICY_SIG:-}" ] && [ -z "${SLUICE_POLICY_SHA256:-}" ]; then
    die "SLUICE_POLICY_REQUIRE=1 but no SLUICE_POLICY_SIG / SLUICE_POLICY_SHA256 is configured - the policy is unverifiable."
  fi
  return 0
}

# Merged policy text from all sources (low->high precedence). A configured-but-unfetchable URL is fatal
# (a managed policy must never silently fall back to local-only); a URL body is authenticated before use.
_policy_raw() {
  local url="${SLUICE_POLICY_URL:-}" uf="$HOME/.config/sluice/policy.conf" sf="/etc/sluice/policy.conf" chunk
  if [ -n "$url" ]; then
    chunk="$(curl -fsSL --max-time 10 "$url" 2>/dev/null)" \
      || die "SLUICE_POLICY_URL=$url could not be fetched - refusing to run without the configured policy (make it reachable, or unset it)."
    _verify_policy_sig "$chunk"
    printf '%s\n' "$chunk"
  fi
  [ -f "$uf" ] && { cat "$uf"; echo; }
  [ -f "$sf" ] && { cat "$sf"; echo; }
  return 0   # a false final [ -f ] test would otherwise abort body=$(_policy_raw) under set -e
}

_ip2int() {
  local a b c d; IFS=. read -r a b c d <<<"${1:-0.0.0.0}"
  printf '%s' "$(( ((a&255)<<24)|((b&255)<<16)|((c&255)<<8)|(d&255) ))"
}
# 0 if IPv4 $1 is within $2 (ip or ip/bits).
_ip_in_cidr() {
  local ip="$1" base bits a b mask
  case "$2" in */*) base="${2%/*}"; bits="${2#*/}" ;; *) base="$2"; bits=32 ;; esac
  case "$bits" in ''|*[!0-9]*) bits=32 ;; esac
  a="$(_ip2int "$ip")"; b="$(_ip2int "$base")"
  [ "$bits" -le 0 ] && return 0
  [ "$bits" -ge 32 ] && { [ "$a" = "$b" ]; return; }
  mask=$(( 0xFFFFFFFF ^ ((1 << (32 - bits)) - 1) ))
  [ "$(( a & mask ))" -eq "$(( b & mask ))" ]
}
# 0 if host $1 is denied by the space-list $2 (exact, or a leading-dot wildcard matching subdomains).
_policy_denied_host() {
  local h="$1" d
  for d in $2; do
    [ "$h" = "$d" ] && return 0
    case "$d" in .*) case ".$h" in *"$d") return 0 ;; esac ;; esac
  done
  return 1
}

# 0 if the leading-dot allow wildcard $1 COVERS any deny token in the space-list $2 - i.e. allowing it
# would silently re-admit a host the policy denies (deny is host-granular; a .parent allow swallows it).
# Only meaningful for a leading-dot wildcard; an exact allow host is handled by _policy_denied_host.
_allow_covers_denied() {
  local w="$1" d db
  case "$w" in .*) ;; *) return 1 ;; esac
  for d in $2; do
    db="${d#.}"                          # a deny wildcard .x denies x + subs; covering x suffices
    case ".$db" in *"$w") return 0 ;; esac
  done
  return 1
}

# PURE policy evaluator: parse the merged policy, compute the effective allowlist + wildcard conflicts,
# and COLLECT every violation (with the exact human reason apply_policy dies with) into output globals -
# in the same order apply_policy refuses. It does NOT die (except via _policy_raw, whose fail-closed die
# on an UNREACHABLE policy URL is correct + shared), NOT mutate SLUICE_ALLOW_DOMAINS, NOT export, NOT
# echo. Both the run path (apply_policy, die-mode) and doctor (report-only) call it. Outputs:
#   _PEVAL_EFFECTIVE  effective allowlist = (local + allow) - deny  (the value apply_policy assigns)
#   _PEVAL_REFUSALS   newline-separated refusal reasons, in run-path die order (empty = clean)
#   _PEVAL_RSBASE     1 if require-signed-base (apply_policy exports SLUICE_REQUIRE_SIGNED)
#   _PEVAL_SRC        policy source label;  _PEVAL_SUMMARY  "N allow, N deny, N forbid"
#   _PEVAL_UNKNOWNS   unknown directive tokens;  _PEVAL_STRICT  1 if strict-unknown
policy_evaluate() {
  local body allow="" deny="" denyip="" forbid="" maxips="" launder=0 strict=0 rsbase=0 unknowns="" line verb arg
  body="$(_policy_raw)"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | awk '{$1=$1};1')"; [ -n "$line" ] || continue
    verb="${line%% *}"; arg="${line#"$verb"}"; arg="$(printf '%s' "$arg" | awk '{$1=$1};1')"
    case "$verb" in
      allow)               allow="$allow $arg" ;;
      deny)                deny="$deny $arg" ;;
      deny-ip)             denyip="$denyip $arg" ;;
      forbid)              forbid="$forbid $arg" ;;
      forbid-laundering)   launder=1 ;;
      max-allow-ips)       maxips="$arg" ;;
      strict-unknown)      strict=1 ;;
      require-signed-base) rsbase=1 ;;
      *) if [ -z "$arg" ] && printf '%s' "$verb" | grep -qE '^\.?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then allow="$allow $verb"
         else unknowns="$unknowns $verb"; fi ;;
    esac
  done <<EOF
$body
EOF
  _PEVAL_UNKNOWNS="$unknowns"; _PEVAL_STRICT="$strict"; _PEVAL_RSBASE="$rsbase"
  local refusals=""
  # Refusals are collected in the SAME order apply_policy dies on them, so dying on the first non-empty
  # line reproduces the run-path verdict exactly. (1) unknown directive(s) under strict-unknown.
  if [ -n "$unknowns" ] && [ "$strict" = 1 ]; then
    refusals="$refusals""policy: unknown directive(s):$unknowns - refusing (strict-unknown)."$'\n'
  fi
  # (2) forbidden loosening knobs: the org said no - the local config must not set one. Same per-knob
  # reason + same order as the run-path loop.
  local k
  for k in $forbid; do
    case "$k" in
      SLUICE_DNS_OPEN|SLUICE_ALLOW_DOH) if [ "${!k:-}" = 1 ]; then refusals="$refusals""policy forbids ${k}=1 (your config sets it) - remove it to run under this policy."$'\n'; fi ;;
      *) if [ -n "${!k:-}" ]; then refusals="$refusals""policy forbids setting ${k} (your config sets it) - remove it to run under this policy."$'\n'; fi ;;
    esac
  done
  # effective allowlist = (local + policy allow) - policy deny. (3) a leading-dot allow wildcard that
  # COVERS a deny token would silently re-admit a denied host - a conflict refusal.
  local merged eff="" h conflict=""
  merged="$(printf '%s %s' "${SLUICE_ALLOW_DOMAINS:-}" "$allow" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  for h in $merged; do
    if _policy_denied_host "$h" "$deny"; then continue
    elif _allow_covers_denied "$h" "$deny"; then conflict="$conflict $h"
    else eff="$eff $h"; fi
  done
  if [ -n "$conflict" ]; then refusals="$refusals""policy: allowlist wildcard(s)$conflict would re-admit a host the policy denies - narrow them to exact hosts to run under this policy (deny is final)."$'\n'; fi
  _PEVAL_EFFECTIVE="$(printf '%s' "$eff" | awk '{$1=$1};1')"
  # (4) forbid-laundering: any laundering-capable host left on the EFFECTIVE allowlist (matches the
  # run path, which checks the post-deny list).
  if [ "$launder" = 1 ]; then
    local risky=""; for h in $_PEVAL_EFFECTIVE; do if laundering_host "$h"; then risky="$risky $h"; fi; done
    if [ -n "$risky" ]; then refusals="$refusals""policy forbids laundering-capable allowlisted host(s):$risky"$'\n'; fi
  fi
  # (5) SLUICE_ALLOW_IPS matching a deny-ip, then (6) over the max-allow-ips cap. Same order, same count.
  local ipn=0 e ipp d
  for e in ${SLUICE_ALLOW_IPS:-}; do
    ipn=$((ipn+1)); ipp="${e%%:*}"; ipp="${ipp%%/*}"
    for d in $denyip; do if _ip_in_cidr "$ipp" "$d"; then refusals="$refusals""policy denies SLUICE_ALLOW_IPS '$e' (matches deny-ip $d)"$'\n'; fi; done
  done
  case "$maxips" in ''|*[!0-9]*) ;; *) if [ "$ipn" -gt "$maxips" ]; then refusals="$refusals""policy caps SLUICE_ALLOW_IPS at $maxips (your config has $ipn)"$'\n'; fi ;; esac
  _PEVAL_REFUSALS="$refusals"
  # source + counts for visibility (banner/run line / doctor).
  _PEVAL_SRC="$([ -f /etc/sluice/policy.conf ] && echo /etc/sluice/policy.conf || { [ -f "$HOME/.config/sluice/policy.conf" ] && echo "$HOME/.config/sluice/policy.conf" || echo "${SLUICE_POLICY_URL:-}"; })"
  _PEVAL_SUMMARY="$(printf '%s allow, %s deny, %s forbid' "$(printf '%s' "$allow" | wc -w | tr -d ' ')" "$(printf '%s' "$deny" | wc -w | tr -d ' ')" "$(printf '%s' "$forbid" | wc -w | tr -d ' ')")"
}

# Doctor-only, REPORT-ONLY policy evaluation: run policy_evaluate WITHOUT dying or mutating anything,
# so doctor can show the post-deny effective allowlist + the refusals a run/build would hit. It runs in
# a child subshell so policy_evaluate's global writes don't leak into the rest of doctor's report. The
# subshell FIRST probes the policy source with a plain _policy_raw call: a `|| exit` makes an unreachable
# URL an honest non-zero subshell exit (relying on the body=$(_policy_raw) assignment inside
# policy_evaluate to propagate the die is unsafe - set -e is suppressed for a command whose status is
# being captured, which would silently yield an empty body). On success it prints the effective
# allowlist (line 1) then the refusal reasons (one per line); on an unreachable source it exits non-zero
# and we surface "unreachable" so doctor still COMPLETES. (The probe + policy_evaluate's own fetch means
# a URL policy is fetched twice on the doctor path - benign for a one-shot diagnostic.) Caller guards
# with policy_configured. Sets doctor-local: _DPE_STATUS (ok|unreachable), _DPE_EFF, _DPE_REFUSALS.
_doctor_policy_eval() {
  local blob rc
  blob="$( _policy_raw >/dev/null 2>&1 || exit 1
           policy_evaluate
           printf '%s\n' "$_PEVAL_EFFECTIVE"; printf '%s' "$_PEVAL_REFUSALS" )" && rc=0 || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then _DPE_STATUS=unreachable; _DPE_EFF=""; _DPE_REFUSALS=""; return 0; fi
  _DPE_STATUS=ok
  _DPE_EFF="$(printf '%s' "$blob" | sed -n '1p')"
  _DPE_REFUSALS="$(printf '%s' "$blob" | sed '1d')"
}

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
  local eng="" v blocked _attn=0   # _attn: count of attention/warning sites, for the trailing verdict
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
      eng=""; _attn=$((_attn+1))   # daemon down (or wedged/timed out): skip the engine-dependent checks below
    fi
  elif [ -n "${SLUICE_ENGINE:-}" ]; then
    # Explicitly named but absent: "install docker or podman" is the wrong remedy. Mirror resolve_engine's die.
    eng=""; _attn=$((_attn+1)); _doc engine "${C_RED}none${C_RST} - SLUICE_ENGINE='$SLUICE_ENGINE' not found on PATH"
  else
    eng=""; _attn=$((_attn+1)); _doc engine "${C_RED}none${C_RST} - install docker or podman"
  fi

  if ! PROJECT_CONFIG="$(find_config)"; then
    _attn=$((_attn+1)); _doc config "${C_RED}none${C_RST} - run 'sluice init' to scaffold one"
    _doctor_verdict "$_attn"; return 0
  fi
  PROJECT_DIR="$(cd "$(dirname "$PROJECT_CONFIG")" && pwd)"
  # Doctor is the command you run BECAUSE the config is broken, so a broken config must not abort it.
  # bash -n catches syntax errors; relaxing errexit around the source keeps a non-zero top-level line
  # from killing doctor. A literal top-level `exit` in the config still escapes (it can't be contained
  # without a subshell that would drop the vars derive_names + the report below need) - known limit.
  if bash -n "$PROJECT_CONFIG" 2>/dev/null; then
    _doc config "$(_tilde "$PROJECT_CONFIG")"
  else
    _attn=$((_attn+1))
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
        /*) if [ ! -e "$_src" ]; then _attn=$((_attn+1)); _doc "" "${C_DIM}$(_term_esc "$_m")${C_RST} ${C_YEL}host path not found - run will fail${C_RST}"
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
  local _unm _nu _uf
  _unm="$(unmasked_secrets 2>/dev/null || true)"
  if [ -n "$_unm" ]; then
    _attn=$((_attn+1))
    _nu="$(printf '%s\n' "$_unm" | grep -c . || true)"
    _doc "" "${C_YEL}note${C_RST}: $_nu secret-looking file(s) readable in the box - shadow them: SLUICE_MASK=\".env*\" (sluice.config.example.sh)"
    printf '%s\n' "$_unm" | head -10 | while IFS= read -r _uf; do
      printf '             %s\n' "$(_term_esc "$_uf")"
    done
    [ "$_nu" -gt 10 ] && _doc "" "${C_DIM}(+ $((_nu - 10)) more)${C_RST}"
  fi

  # Symlinks that leave the mounted scope work on the host but dangle inside the box - warn.
  local _links _nl _lp _lt _TAB; _TAB="$(printf '\t')"
  _links="$(symlinks_outside_scope 2>/dev/null || true)"
  if [ -n "$_links" ]; then
    _attn=$((_attn+1))
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
        _attn=$((_attn+1))
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
        _attn=$((_attn+1))
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
  # Always show a harden row: opt-ins when on, else the effective default posture the run path applies.
  if [ -n "$_hard" ]; then _doc harden "${_hard# }"
  else _doc harden "${C_DIM}defaults (seccomp=default, root rw, workspace=bind)${C_RST}"; fi

  [ -n "${SLUICE_PORTS:-}" ] && _doc ports "$SLUICE_PORTS ${C_DIM}(published on 127.0.0.1)${C_RST}"
  # Under a managed policy, the live allowlist is (local + allow) - deny: show what would ACTUALLY be
  # allowed, plus any refusal a run/build would die on - report-only, doctor never dies or mutates.
  local _eff_allow="${SLUICE_ALLOW_DOMAINS:-}" _pol_unreachable=""
  if policy_configured; then
    _doctor_policy_eval
    if [ "$_DPE_STATUS" = unreachable ]; then
      _pol_unreachable=1; _attn=$((_attn+1))
      _doc allowlist "${SLUICE_ALLOW_DOMAINS:-(none beyond base)} ${C_DIM}(pre-policy; policy unreachable)${C_RST}"
    else
      _eff_allow="$_DPE_EFF"
      _doc allowlist "${_eff_allow:-(none beyond base)} ${C_DIM}(effective, post-policy deny/wildcard)${C_RST}"
      if [ -n "$_DPE_REFUSALS" ]; then
        local _nr; _nr="$(printf '%s\n' "$_DPE_REFUSALS" | grep -c . || true)"
        _attn=$((_attn+_nr))   # each refusal line is an attention site
        printf '%s\n' "$_DPE_REFUSALS" | while IFS= read -r _r; do
          [ -n "$_r" ] && _doc "" "${C_RED}policy would refuse:${C_RST} $_r"
        done
      fi
    fi
  else
    _doc allowlist "${SLUICE_ALLOW_DOMAINS:-(none beyond base)}"
  fi
  local _risky="" _doh="" _h
  set -f   # the allowlist entries are not globs - keep a wildcard (e.g. *.s3.amazonaws.com) literal
  for _h in ${_eff_allow:-}; do
    laundering_host "$_h" && _risky="$_risky $_h"
    doh_listed "$_h" && _doh="$_doh $_h"
  done
  set +f
  # Hazard notes by severity: the genuinely exfil-capable ones lead (DoH-allowed, then laundering);
  # the informational lines (base:, benign still-blocked DoH, ips:, policy) come after.
  if [ -n "$_doh" ] && [ "${SLUICE_ALLOW_DOH:-}" = 1 ]; then
    _attn=$((_attn+1)); _doc "" "${C_YEL}note${C_RST}: DoH resolver(s) allowed AND SLUICE_ALLOW_DOH=1 -${_doh} - DNS-over-HTTPS exfil is possible"
  fi
  if [ -n "$_risky" ]; then
    _attn=$((_attn+1)); _doc "" "${C_YEL}note${C_RST}: shared host(s) an attacker can also write to -${_risky} - data can be laundered out (splice, not decrypt); keep the allowlist tight"
  fi
  _doc "" "base: $(base_domains)"
  if [ -n "$_doh" ] && [ "${SLUICE_ALLOW_DOH:-}" != 1 ]; then
    _doc "" "${C_DIM}note: DoH resolver(s) on the allowlist -${_doh} - still BLOCKED (DoH exfil channel); SLUICE_ALLOW_DOH=1 to permit${C_RST}"
  fi
  [ -n "${SLUICE_ALLOW_IPS:-}" ] && _doc ips "$SLUICE_ALLOW_IPS ${C_DIM}(direct egress, bypasses the hostname filter; bare ip = any port, ip:port scopes it)${C_RST}"
  if [ -n "${SLUICE_POLICY_URL:-}" ]; then
    if [ -n "$_pol_unreachable" ]; then _doc policy "${C_RED}$SLUICE_POLICY_URL - unreachable${C_RST} (run/build would refuse to start)"
    else _doc policy "$SLUICE_POLICY_URL"; fi
  fi

  if [ -n "${SLUICE_ENV:-}" ]; then
    for v in $SLUICE_ENV; do
      if [ -n "${!v:-}" ]; then _doc auth "$v ${C_GRN}set${C_RST}"; else _doc auth "$v ${C_RED}unset${C_RST} - export it on the host"; fi
    done
  fi

  if [ -n "$eng" ] && running; then
    local _RCPT_OFFSET; _RCPT_OFFSET="$(last_run_offset)"   # scope to last run (matches 'sluice learn'); empty -> full log
    blocked="$(blocked_new 2>/dev/null || true)"
    if [ -n "$blocked" ]; then
      _attn=$((_attn+1))
      _doc egress "${C_RED}$(printf '%s\n' "$blocked" | grep -c .) host(s) blocked${C_RST} (last run) - run 'sluice learn' to allow:"
      printf '%s\n' "$blocked" | _doctor_bullets "$C_RED"
    elif ! _audit_readable; then
      _attn=$((_attn+1))
      _doc egress "${C_YEL}egress audit unavailable${C_RST} - could not read the in-box log (pids limit?); can't confirm nothing was blocked"
    else
      _doc egress "${C_GRN}no blocked egress needs allowing${C_RST}"
    fi
  else
    _doc egress "${C_DIM}sandbox not running${C_RST} - start it, exercise the app, re-run 'sluice doctor'"
  fi

  _doctor_verdict "$_attn"
}

# Trailing one-line verdict for the human readout: $1 = the attention/warning count accumulated by
# cmd_doctor. Zero -> a green all-clear; otherwise a yellow "N item(s) need attention" (singular/plural
# correct). PURE (reads its arg, writes one line) so the verdict copy is unit-testable without an engine.
_doctor_verdict() {
  local n="${1:-0}"
  if [ "$n" -eq 0 ]; then
    printf '  %sok%s: ready - no action needed\n' "$C_GRN" "$C_RST"
  elif [ "$n" -eq 1 ]; then
    printf '  %s1 item needs attention%s\n' "$C_YEL" "$C_RST"
  else
    printf '  %s%s items need attention%s\n' "$C_YEL" "$n" "$C_RST"
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

  local running_b=false blocked="" egress_unavail=false
  if [ -n "$eng" ] && running; then
    running_b=true; local _RCPT_OFFSET; _RCPT_OFFSET="$(last_run_offset)"
    blocked="$(blocked_new 2>/dev/null || true)"
    # Empty may mean "nothing blocked" or a failed read; distinguish so blocked isn't a false [].
    [ -z "$blocked" ] && ! _audit_readable && egress_unavail=true
  fi

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

  # Managed-policy posture: the post-deny effective allowlist + the refusals a run/build would die on
  # (report-only - _doctor_policy_eval never dies/mutates). null when no policy is configured; a
  # configured-but-unfetchable URL surfaces as reachable:false (doctor still completes).
  local policy_json=null
  if policy_configured; then
    _doctor_policy_eval
    if [ "$_DPE_STATUS" = unreachable ]; then
      policy_json='{"reachable":false,"effective_allowlist":[],"refusals":[]}'
    else
      policy_json="$(printf '{"reachable":true,"effective_allowlist":%s,"refusals":%s}' \
        "$(printf '%s' "$_DPE_EFF" | tr ' ' '\n' | _json_arr)" \
        "$(printf '%s' "$_DPE_REFUSALS" | _json_arr)")"
    fi
  fi

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
  [ "$egress_unavail" = true ] && blocked_json=null

  printf '{"engine":"%s","engine_found":%s,"daemon":%s,"config":"%s","config_error":%s,"project_dir":"%s","name":"%s","desc":"%s","image":{"tag":"%s","built":%s,"stale":%s},"lock":"%s","allowlist":%s,"base":%s,"ports":%s,"allow_ips":%s,"base_image":"%s","policy_url":"%s","policy":%s,"state_dirs":%s,"overlay_dirs":%s,"mounts":%s,"auth":%s,"hardening":%s,"mask":{"patterns":%s,"masked":%s,"unmasked_secrets":%s},"risk":%s,"broken_symlinks":%s,"egress":{"running":%s,"blocked":%s}}\n' \
    "$(_json_esc "$engine_ver")" "$engine_found" "$daemon" "$(_json_esc "$PROJECT_CONFIG")" "$config_error" "$(_json_esc "$PROJECT_DIR")" "$(_json_esc "$tag")" "$(_json_esc "${SLUICE_DESC:-}")" \
    "$(_json_esc "$tag")" "$img_built" "$img_stale" "$lock" \
    "$allow_json" "$(base_domains | tr ' ' '\n' | _json_arr)" \
    "$ports_json" "$ips_json" "$(_json_esc "${SLUICE_BASE_IMAGE:-}")" \
    "$(_json_esc "${SLUICE_POLICY_URL:-}")" "$policy_json" "$nsd" "$overlays_json" "$mounts_json" "$auth_json" "$hardening_json" \
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
