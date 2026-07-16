find_config() {
  if [ -n "${SLUICE_BOX_TARGET:-}" ]; then   # -b/--box: the targeted box's recorded dir, not $PWD's
    [ -n "${BOX_PROJECT:-}" ] && [ -f "$BOX_PROJECT/sluice.config.sh" ] && { echo "$BOX_PROJECT/sluice.config.sh"; return 0; }
    return 1   # config gone (orphan): the caller's no-config path fires
  fi
  d="$PWD"
  while [ "$d" != / ]; do
    [ -f "$d/sluice.config.sh" ] && { echo "$d/sluice.config.sh"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# `sluice doctor`: self-contained health report (resolves its own engine/config), runs anywhere.
if [ "${1:-}" = doctor ]; then
  case "${2:-}" in ""|--json) cmd_doctor "${2:-}"; exit 0 ;; *) die "usage: sluice doctor [--json]" ;; esac
fi

# `sluice ls`: global box listing (resolves its own engine above; no project config needed).
if [ "${1:-}" = ls ]; then shift; cmd_ls "$@"; exit $?; fi

# `sluice prune`: global cleanup - remove every sluice box (or only orphans with --orphans); confirms.
cmd_prune() {
  local only_orphans="" imgs i a proj kept
  [ "${1:-}" = --orphans ] && only_orphans=1
  imgs="$("$ENGINE" image ls --filter label=sluice.confighash --format '{{.Repository}}' 2>/dev/null | sed 's,^localhost/,,' | grep -v '^<none>$' | sort -u || true)"   # strip podman's localhost/ so names match the canonical sluice-<slug>
  [ -n "$imgs" ] || { echo "[sluice] no sluice boxes to prune."; return 0; }
  if [ -n "$only_orphans" ]; then   # keep only boxes whose recorded project dir is gone
    kept=""
    while IFS= read -r i; do
      [ -n "$i" ] || continue
      proj="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.project" }}' "$i" 2>/dev/null || true)"
      case "$proj" in "<no value>") proj="" ;; esac
      [ -n "$proj" ] && [ ! -d "$proj" ] && kept="$kept$i"$'\n'
    done <<EOF
$imgs
EOF
    imgs="$(printf '%s' "$kept" | grep -v '^$' || true)"
    [ -n "$imgs" ] || { echo "[sluice] no orphan boxes to prune (every box's project dir still exists)."; return 0; }
    echo "[sluice] orphan sluice images to remove (project dir gone):"
  else
    echo "[sluice] sluice images to remove (+ their containers):"
  fi
  # shellcheck disable=SC2086
  printf '  %s\n' $imgs
  if [ -t 0 ] && [ -t 1 ]; then
    printf '[sluice] remove all of these? [y/N] '; read -r a || a=""
    case "$a" in y|Y|yes|YES) ;; *) echo "[sluice] ${C_DIM}aborted.${C_RST}"; return 0 ;; esac
  elif [ "${SLUICE_YES:-}" != 1 ]; then
    echo "[sluice] non-interactive: re-run with SLUICE_YES=1 to confirm pruning."; return 0
  fi
  for i in $imgs; do
    "$RUNNER" rm -f "$i" >/dev/null 2>&1 || true; "$ENGINE" rmi -f "$i" >/dev/null 2>&1 || true
    remove_box_volumes "$i" >/dev/null   # per-box SLUICE_OVERLAY_DIRS volumes go with the box
  done
  echo "[sluice] ${C_GRN}pruned $(printf '%s\n' "$imgs" | grep -c .) box(es).${C_RST}"
  # Persisted state dirs (agent sessions/auth) live outside the boxes and are NOT removed by prune.
  _store="${XDG_STATE_HOME:-$HOME/.local/state}/sluice"
  [ -d "$_store" ] && [ -n "$(ls -A "$_store" 2>/dev/null)" ] && \
    echo "${C_DIM}[sluice] note: persisted session state remains under $_store (remove manually if no longer needed).${C_RST}"
}
if [ "${1:-}" = prune ]; then
  case "${2:-}" in ""|--orphans) cmd_prune "${2:-}"; exit $? ;; *) die "usage: sluice prune [--orphans]" ;; esac
fi

# `sluice egress --verify --all` / `--export --all`: fleet-wide audit over EVERY box's hash chain.
# Dispatched here, before find_config, so it needs neither a project config nor a running engine and
# reaches orphaned boxes (their chains outlive the box). Bare `egress --all` defaults to --verify.
# `-b ... egress --all` was already rejected in src/45.
if [ "${1:-}" = egress ]; then
  case " $* " in
    *" --all "*)
      _eg_mode="verify"; _eg_json=""
      for _eg_a in "$@"; do
        case "$_eg_a" in
          egress|--all|--verify) ;;
          --export) _eg_mode="export" ;;
          --json)   _eg_json="--json" ;;
          *)        die "usage: sluice egress [--verify | --export] --all [--json]" ;;
        esac
      done
      if [ "$_eg_mode" = export ]; then cmd_egress_export_all; else cmd_egress_verify_all "$_eg_json"; fi
      exit $?
      ;;
  esac
fi

# Package-registry hosts for the stack detected in $PWD (a manifest sniff mirroring cmd_init's
# per-stack allowlists - kept lean here, full detection lives in cmd_init). Always the full registry
# set: an agent installs deps at RUNTIME inside the box, so the init prefetch shortcut doesn't apply.
# Echoes "<label>|<hosts>"; nothing when no stack is recognized.
_stack_registry_hosts() {
  local dir="$PWD" pm
  if [ -f "$dir/package.json" ]; then
    pm="npm"
    if   [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then pm="bun"
    elif [ -f "$dir/pnpm-lock.yaml" ]; then pm="pnpm"
    elif [ -f "$dir/yarn.lock" ];      then pm="yarn"; fi
    case "$pm" in
      yarn) echo "node/yarn|registry.yarnpkg.com" ;;
      *)    echo "node/$pm|registry.npmjs.org" ;;
    esac
  elif [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Pipfile" ]; then
    echo "python|pypi.org files.pythonhosted.org"
  elif [ -f "$dir/deno.json" ] || [ -f "$dir/deno.jsonc" ]; then
    echo "deno|deno.land jsr.io registry.npmjs.org esm.sh cdn.jsdelivr.net"
  elif [ -f "$dir/Gemfile" ]; then
    echo "ruby|rubygems.org index.rubygems.org"
  elif [ -f "$dir/Cargo.toml" ]; then
    echo "rust|static.crates.io index.crates.io"
  elif [ -f "$dir/go.mod" ]; then
    echo "go|proxy.golang.org sum.golang.org"
  elif [ -f "$dir/pom.xml" ]; then
    echo "java/maven|repo.maven.apache.org repo1.maven.org"
  elif [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; then
    echo "java/gradle|repo.maven.apache.org repo1.maven.org plugins.gradle.org services.gradle.org"
  elif [ -f "$dir/composer.json" ]; then
    echo "php|repo.packagist.org packagist.org"
  elif [ -n "$(ls "$dir"/*.csproj "$dir"/*.sln 2>/dev/null)" ]; then
    echo "dotnet|api.nuget.org www.nuget.org"
  elif [ -f "$dir/mix.exs" ]; then
    echo "elixir|repo.hex.pm builds.hex.pm"
  elif [ -f "$dir/pubspec.yaml" ]; then
    echo "dart|pub.dev pub.dartlang.org"
  fi
}

# `sluice agent [name] [args...]`: write the agents/<name>.config.sh preset, then build+run.
# Trailing args after the name are forwarded to the agent (one-shot), e.g. `sluice agent claude -p '...'`.
AGENT_EXTRA_ARGS=()
if [ "${1:-}" = agent ]; then
  banner
  shift
  agents_dir="$ROOT/agents"
  if [ -z "${1:-}" ]; then
    echo "[sluice] coding agents (use: sluice agent <name> [args...]):"
    for f in "$agents_dir"/*.config.sh; do
      [ -f "$f" ] || continue
      nm="$(basename "$f" .config.sh)"
      desc="$(. "$f"; printf '%s' "${SLUICE_DESC:-}")"
      vars="$(. "$f"; printf '%s' "${SLUICE_ENV:-}")"; v1="${vars%% *}" setvar=""
      for v in $vars; do [ -n "${!v:-}" ] && { setvar="$v"; break; }; done   # a preset may accept any of several
      if   [ -z "$v1" ];     then auth=""
      elif [ -n "$setvar" ]; then auth="$setvar ${C_GRN}(set)${C_RST}"
      else                        auth="$v1 ${C_DIM}(unset)${C_RST}"; fi
      printf "  %-10s %-26s %s\n" "$nm" "$desc" "$auth"
    done
    exit 0
  fi
  preset="$agents_dir/$1.config.sh"
  [ -f "$preset" ] || die "unknown agent '$1' - run 'sluice agent' to list available presets."
  agent_name="$1"; shift
  [ "$#" -gt 0 ] && AGENT_EXTRA_ARGS=("$@")   # forward trailing args to the agent (one-shot)
  if cfg="$(find_config)"; then
    # If that config came from a DIFFERENT agent's preset, the requested one is being ignored - the
    # box is keyed to the project dir, so a repo holds one agent at a time. Flag it (don't block).
    # Matched on the preset's first-line banner: a scaffolded config keeps it even after the stack-
    # host append below or a `sluice learn` edit (a verbatim cmp went blind on the first edit).
    h1="$(head -1 "$cfg" 2>/dev/null || true)"
    for af in "$agents_dir"/*.config.sh; do
      [ "$h1" = "$(head -1 "$af")" ] || continue
      other="$(basename "$af" .config.sh)"
      [ "$other" = "$agent_name" ] || echo "[sluice] ${E_YEL}note${E_RST}: this project is set up for the '$other' agent - to run '$agent_name', use a separate dir or 'git worktree add', or remove $cfg." >&2
      break
    done
    echo "[sluice] using existing config: $cfg"
  else
    cp "$preset" "$PWD/sluice.config.sh"
    # Union the detected stack's package-registry hosts into the scaffolded allowlist (the preset
    # FILE stays tool-only), so the agent's first install doesn't trip the firewall into a learn
    # cycle. One assignment line is kept - `sluice learn` rewrites the first SLUICE_ALLOW_DOMAINS=.
    stackreg="$(_stack_registry_hosts)"
    if [ -n "$stackreg" ]; then
      stacklbl="${stackreg%%|*}"; stackhosts="${stackreg#*|}"
      cfg_tmp="$(mktemp)"
      awk -v add="$stackhosts" -v lbl="$stacklbl" '
        /^SLUICE_ALLOW_DOMAINS="/ && !done { print "# from stack detection: " lbl; sub(/"[[:space:]]*$/, " " add "\""); done=1 }
        { print }
        END { if (!done) print "SLUICE_ALLOW_DOMAINS=\"" add "\"   # from stack detection: " lbl }
      ' "$PWD/sluice.config.sh" > "$cfg_tmp" && mv "$cfg_tmp" "$PWD/sluice.config.sh"
      chmod 0644 "$PWD/sluice.config.sh" 2>/dev/null || true   # mktemp is 0600; the build sources it
      echo "[sluice] allowlist += $stackhosts (stack detection: $stacklbl)"
    fi
    echo "[sluice] wrote $PWD/sluice.config.sh from the '$agent_name' agent preset."
    echo "[sluice] export the agent's auth env var on your host first (see the file's header)."
  fi
  set -- run-default     # continue into the normal build + run flow below
fi

if ! PROJECT_CONFIG="$(find_config)"; then
  # --box <orphan>: the project dir is gone, so there's no config to source and nothing to mount.
  # Teardown (stop/rm) still works by image/container name alone; everything else can't run.
  if [ -n "$SLUICE_BOX_TARGET" ]; then
    container="$SLUICE_BOX_IMAGE"; tag="$SLUICE_BOX_IMAGE"
    case "${1:-run-default}" in
      stop) "$RUNNER" rm -f -v "$container" >/dev/null 2>&1 || true; echo "[sluice] $container stopped"; exit 0 ;;
      rm)   "$RUNNER" rm -f -v "$container" >/dev/null 2>&1 || true; "$ENGINE" rmi -f "$tag" >/dev/null 2>&1 || true; remove_box_volumes "$container" >/dev/null; echo "[sluice] removed $container (container + image + overlay volumes)"; exit 0 ;;
      *)    die "box '$SLUICE_BOX_SLUG' is an orphan (project dir ${BOX_PROJECT:-?} is gone) - 'sluice -b $SLUICE_BOX_SLUG rm' to remove it" ;;
    esac
  fi
  # no config: scaffold for build/run commands; others have nothing to act on.
  case "${1:-run-default}" in
    run-default|build|rebuild|shell|run|smoke) ;;
    stop|logs|learn|egress|rm|diff|apply) die "no sluice.config.sh found in $PWD or any parent - nothing to ${1}." ;;
    *) die "unknown command: ${1:-} - run 'sluice help' for usage." ;;
  esac
  # zero-config: scaffold, preview, then confirm before build/run (CI stops unless SLUICE_YES=1).
  banner
  echo "[sluice] no sluice.config.sh found - scaffolding one from the detected stack:"
  SLUICE_INIT_QUIET=1 cmd_init
  grep -E '^SLUICE_(EXTRA_PKGS|RUN_CMD|PORTS|ALLOW_DOMAINS)=' "$PWD/sluice.config.sh" | sed 's/^/    /' || true
  if [ -t 0 ] && [ -t 1 ]; then
    printf '[sluice] build and run it now? [Y/n] '
    read -r _ans || _ans=n
    case "$_ans" in [nN]|[nN][oO]) echo "[sluice] kept sluice.config.sh - edit it, then run 'sluice'."; exit 0 ;; esac
  elif [ "${SLUICE_YES:-}" != 1 ]; then
    echo "[sluice] non-interactive: review sluice.config.sh, then run 'sluice' (or set SLUICE_YES=1 to auto-run)."
    exit 0
  fi
  PROJECT_CONFIG="$PWD/sluice.config.sh"
  _SCAFFOLDED=1   # F3: bare-sluice first-run nudge fires after the run completes
fi
PROJECT_DIR="$(cd "$(dirname "$PROJECT_CONFIG")" && pwd)"

# Source the config here (also baked into the image; keep it POSIX-sh-safe).
# shellcheck disable=SC1090
. "$PROJECT_CONFIG"

# per-project image + container names (SLUICE_NAME overrides the dir-name default)
derive_names

# Central egress policy v2 evaluation machinery (policy_configured / _policy_raw / _verify_policy_sig /
# the IP+host matchers / policy_evaluate) is defined up in src/30-doctor-ls.sh - it must exist BEFORE
# the early `doctor` dispatch (top of this slice) so `sluice doctor` can evaluate the policy report-only.
# Only apply_policy (the run-path die-mode gate) lives here, next to the dispatch that invokes it.

# Security-critical managed-egress gate ("deny is final"). Run path only (run-default/run/shell/build/
# rebuild/update). Evaluates the policy purely, then reproduces the original refuse/side-effect sequence:
# warn-or-die on unknowns, export require-signed-base, die on the FIRST refusal in run-path order, else
# mutate SLUICE_ALLOW_DOMAINS to the effective list and echo the policy line. Behavior is byte-identical
# to the pre-refactor inline version.
apply_policy() {
  policy_configured || return 0
  policy_evaluate
  # Unknown directives: warn + ignore (forward-compat) UNLESS strict-unknown (then it's a refusal below).
  if [ -n "$_PEVAL_UNKNOWNS" ] && [ "$_PEVAL_STRICT" != 1 ]; then
    echo "${E_YEL}[sluice] policy: ignoring unknown directive(s):$_PEVAL_UNKNOWNS${E_RST}" >&2
  fi
  # require-signed-base lets the policy mandate a signed base for every box under it. (Exported before
  # the die loop, as in the original; an immediate die exits anyway, so the order is not observable.)
  if [ "$_PEVAL_RSBASE" = 1 ]; then export SLUICE_REQUIRE_SIGNED=1; fi
  # Die on the first refusal in run-path order (the list is ordered to match the original die sequence).
  if [ -n "$_PEVAL_REFUSALS" ]; then
    local _r
    while IFS= read -r _r; do [ -n "$_r" ] && die "$_r"; done <<EOF
$_PEVAL_REFUSALS
EOF
  fi
  # Clean: apply the effective allowlist (ALLOW_IPS is NOT mutated - the firewall reads the BAKED list,
  # so a host-side drop wouldn't reach a running box; the cap/deny-ip refuse instead, above).
  SLUICE_ALLOW_DOMAINS="$_PEVAL_EFFECTIVE"
  _POLICY_SRC="$_PEVAL_SRC"; _POLICY_SUMMARY="$_PEVAL_SUMMARY"
  echo "${E_DIM}[sluice]${E_RST} managed egress policy: $(_tilde "$_POLICY_SRC") ($_POLICY_SUMMARY)" >&2
}
case "${1:-run-default}" in run-default|run|shell|build|rebuild|update) apply_policy ;; esac

# Advisory: in a monorepo it's easy to build/run against a config found by walking UP from a subdir
# without noticing. Name the source (like `-b` announces its target). Run/build paths only; skipped
# under `-b` (PROJECT_DIR is then the targeted box's dir, already echoed).
case "${1:-run-default}" in
  run-default|run|shell|build|rebuild)
    [ "$PROJECT_DIR" != "$PWD" ] && [ -z "${SLUICE_BOX_TARGET:-}" ] \
      && echo "${E_DIM}[sluice]${E_RST} config from $(_tilde "$PROJECT_CONFIG") (box for $(_tilde "$PROJECT_DIR"))" >&2 ;;
esac

# Host-side credential hook: fires once per invocation, before ANY session (warm or cold) - a
# short-lived token minted here is fresh for every run, not only the run that created the container.
run_prelaunch() {
  [ -n "${SLUICE_PRELAUNCH:-}" ] || return 0
  [ -n "${_PRELAUNCH_DONE:-}" ] && return 0
  command -v "$SLUICE_PRELAUNCH" >/dev/null 2>&1 \
    || die "SLUICE_PRELAUNCH=$SLUICE_PRELAUNCH is not a function/command defined in sluice.config.sh"
  echo "[sluice] running prelaunch hook: $SLUICE_PRELAUNCH"
  "$SLUICE_PRELAUNCH"
  _PRELAUNCH_DONE=1
}

# Pre-run nudge: a config that declares auth vars (SLUICE_ENV) with none set on the host and no
# persisted session will likely fail to authenticate (the key is forwarded from your shell, never
# baked; headless OAuth can't complete). Warn, don't block; run-default path only. The prelaunch
# hook runs FIRST, so a hook that stages the auth env never trips a false alarm here.
warn_auth_unset() {
  [ -n "${SLUICE_ENV:-}" ] || return 0
  local v; for v in $SLUICE_ENV; do [ -n "${!v:-}" ] && return 0; done
  local store="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug"
  [ -n "${SLUICE_STATE_DIRS:-}" ] && [ -d "$store" ] && return 0
  local hookhint=""; [ -n "${SLUICE_PRELAUNCH:-}" ] && hookhint=" (prelaunch hook '$SLUICE_PRELAUNCH' set none of them)"
  echo "${E_YEL}[sluice] note:${E_RST} none of [$SLUICE_ENV] are set on the host$hookhint - export one before running." >&2
  echo "         the key is forwarded from your shell (never baked); a browser OAuth login can't complete in the sandbox." >&2
}
case "${1:-run-default}" in run-default) run_prelaunch; warn_auth_unset ;; esac

# Laundering-host gate: an allowlisted host an attacker can also write to (S3, gists, pastebins, LLM
# APIs) lets data leak out even though it's allowlisted - we splice, never decrypt, so a request body
# to an allowed host isn't inspected (THREAT_MODEL "allowed-host laundering"). Nudge at session start;
# SLUICE_LAUNDERING_OK=1 acknowledges + silences, SLUICE_STRICT_LAUNDERING=1 refuses to run.
warn_laundering() {
  local risky="" h
  for h in ${SLUICE_ALLOW_DOMAINS:-}; do laundering_host "$h" && risky="$risky $h"; done
  [ -n "$risky" ] || return 0
  [ "${SLUICE_LAUNDERING_OK:-}" = 1 ] && return 0
  if [ "${SLUICE_STRICT_LAUNDERING:-}" = 1 ]; then
    echo "${E_RED}[sluice] refusing:${E_RST} allowlisted host(s) an attacker can also write to -${risky}" >&2
    echo "         data can be laundered out through them (we splice, not decrypt). Drop them, or set SLUICE_LAUNDERING_OK=1 to allow." >&2
    exit 1
  fi
  echo "${E_YEL}[sluice] note:${E_RST} allowlisted host(s) an attacker can also write to -${risky} - data can be laundered out (splice, not decrypt)." >&2
  echo "         keep the allowlist tight; SLUICE_LAUNDERING_OK=1 to acknowledge (silences this), SLUICE_STRICT_LAUNDERING=1 to refuse." >&2
}
case "${1:-run-default}" in run-default|run|shell) warn_laundering ;; esac

# SLUICE_ALLOW_IPS is a direct-egress escape hatch that BYPASSES squid (init-firewall.sh ACCEPTs it
# raw), and unlike the other path-y knobs it had no floor: a /0 opened all direct egress yet a broader-
# than-/0-by-pieces cover (0.0.0.0/1 128.0.0.0/1) or any short prefix (/1../7) slipped through, as did
# an IPv6 literal (which then mis-parses in the firewall). Floor = /8: refuse a prefix below /8 and any
# 0.0.0.0/N; refuse IPv6 (we are IPv4-only); loudly warn on a port-less (all-ports) entry. A /8-or-longer
# prefix, a single IP, an ip:port, and a bare host still pass. Each entry is ip[/cidr][:port[/proto]].
_ALLOW_IPS_MIN_PREFIX=8   # documented floor: a CIDR shorter than this is too broad for a direct-egress hatch
validate_allow_ips() {
  local e hostcidr plen
  set -f                              # the split below is unquoted-on-purpose; don't glob a '*' in a value
  for e in ${SLUICE_ALLOW_IPS:-}; do
    # Literal catch-alls (0.0.0.0, any /0): all direct egress.
    case "$e" in
      0.0.0.0|0.0.0.0:*|*/0) die "SLUICE_ALLOW_IPS='$e' opens direct egress to everything - refusing. Scope it to a host and port, e.g. 10.0.0.5:5432" ;;
    esac
    # IPv4-only: '::' shorthand, or 2+ colons (a full-form IPv6 literal) - refuse rather than let the
    # single-colon host/port split below feed iptables a broken -d (opaque fail-closed boot abort).
    case "$e" in *::*) die "SLUICE_ALLOW_IPS='$e' is an IPv6 literal - SLUICE_ALLOW_IPS is IPv4-only (the box proxies/filters v4; IPv6 egress is default-closed). Drop it or use the IPv4 address." ;; esac
    case "${e#*:}" in *:*) die "SLUICE_ALLOW_IPS='$e' is an IPv6 literal - SLUICE_ALLOW_IPS is IPv4-only. Drop it or use the IPv4 address." ;; esac
    # Floor: a CIDR shorter than /_ALLOW_IPS_MIN_PREFIX (and any 0.0.0.0/N, caught above) is too broad
    # for a raw direct-egress ACCEPT. Strip a trailing :port first; a bare host / single IP has no '/'.
    hostcidr="${e%%:*}"
    case "$hostcidr" in
      */*) plen="${hostcidr##*/}"
           case "$plen" in
             ''|*[!0-9]*) ;;          # non-numeric prefix: not a broad cover; leave it to the firewall
             *) [ "$plen" -lt "$_ALLOW_IPS_MIN_PREFIX" ] && die "SLUICE_ALLOW_IPS='$e' is a /$plen - too broad (floor is /$_ALLOW_IPS_MIN_PREFIX) for a direct-egress hatch that bypasses the proxy. Narrow it to /$_ALLOW_IPS_MIN_PREFIX or longer, e.g. 10.0.0.5:5432" ;;
           esac ;;
    esac
    case "$e" in
      *:*) ;;   # ip:port - scoped, fine
      *)   echo "${E_YEL}[sluice] WARNING:${E_RST} SLUICE_ALLOW_IPS '$e' has no port - it opens EVERY port to that host, direct (bypasses the hostname filter). Scope it: ${e}:PORT" >&2 ;;
    esac
  done
  set +f
}
case "${1:-run-default}" in run-default|run|shell|build|rebuild|update) validate_allow_ips ;; esac

# SLUICE_EGRESS_HOST_BUDGETS: "host=bytes .wildcard=bytes ..." - a detective per-host tx budget (over
# any host's cap, `sluice egress` exits non-zero). Validate strictly and fail CLOSED: a malformed token
# dies rather than silently no-op. (SLUICE_EGRESS_MAX_BYTES is silently ignored when malformed - src/20;
# this stricter contract is intentional and noted in docs/configuration.md: a silently-void budget is
# worse than a stop.)
validate_host_budgets() {
  local tok host bytes
  set -f
  for tok in ${SLUICE_EGRESS_HOST_BUDGETS:-}; do
    case "$tok" in
      *=*) host="${tok%%=*}"; bytes="${tok#*=}" ;;
      *)   set +f; die "SLUICE_EGRESS_HOST_BUDGETS entry '$tok' must be host=bytes (e.g. .s3.amazonaws.com=1048576)" ;;
    esac
    case "$host"  in '') set +f; die "SLUICE_EGRESS_HOST_BUDGETS entry '$tok' has an empty host" ;;
                     *[!A-Za-z0-9.-]*) set +f; die "SLUICE_EGRESS_HOST_BUDGETS host '$host' has invalid characters" ;; esac
    case "$bytes" in ''|*[!0-9]*) set +f; die "SLUICE_EGRESS_HOST_BUDGETS '$tok': '$bytes' is not a byte count" ;; esac
  done
  set +f
}
case "${1:-run-default}" in run-default|run|shell|build|rebuild|update) validate_host_budgets ;; esac

# SLUICE_EGRESS_HARD_CAP_BYTES: a PREVENTIVE in-box byte ceiling (xt_quota). Numeric and >= 1 MiB - boot
# deny/allow probes + TLS handshakes consume the quota, so a sub-1MiB cap would brick the box at boot.
# SLUICE_ALLOW_IPS_MAX_BYTES: a shared direct-IP budget (any numeric size). Both fail closed.
validate_egress_hard_caps() {
  case "${SLUICE_EGRESS_HARD_CAP_BYTES:-}" in
    '') ;;
    *[!0-9]*) die "SLUICE_EGRESS_HARD_CAP_BYTES must be a byte count (got '${SLUICE_EGRESS_HARD_CAP_BYTES}')" ;;
    *) [ "$SLUICE_EGRESS_HARD_CAP_BYTES" -ge 1048576 ] || die "SLUICE_EGRESS_HARD_CAP_BYTES must be >= 1048576 (1 MiB) - boot probes + TLS handshakes consume the budget; a smaller cap bricks the box at boot" ;;
  esac
  case "${SLUICE_ALLOW_IPS_MAX_BYTES:-}" in
    '') ;;
    *[!0-9]*) die "SLUICE_ALLOW_IPS_MAX_BYTES must be a byte count (got '${SLUICE_ALLOW_IPS_MAX_BYTES}')" ;;
  esac
}
case "${1:-run-default}" in run-default|run|shell|build|rebuild|update) validate_egress_hard_caps ;; esac

# SLUICE_BUMP_METHODS / SLUICE_BUMP_MAX_BODY are sed'd into squid.conf in-box (H5), so their charset is
# security-critical (injection). Validate host-side; the entrypoint re-validates (defense in depth).
validate_bump_controls() {
  local _m
  set -f
  for _m in ${SLUICE_BUMP_METHODS:-}; do
    case "$_m" in *[!A-Za-z]*) set +f; die "SLUICE_BUMP_METHODS token '$_m' must be letters only (an HTTP method, e.g. GET HEAD POST)" ;; esac
  done
  set +f
  case "${SLUICE_BUMP_MAX_BODY:-}" in
    '') ;;
    *[!0-9]*) die "SLUICE_BUMP_MAX_BODY must be a byte count (got '${SLUICE_BUMP_MAX_BODY}')" ;;
  esac
}
case "${1:-run-default}" in run-default|run|shell|build|rebuild|update) validate_bump_controls ;; esac

# build: assemble a temp context (core + this project's config) and build
# Verify a published base image's cosign signature (keyless/OIDC). Soft by default: warn if
# cosign is absent or the image is unsigned; SLUICE_REQUIRE_SIGNED=1 makes either case fatal.
