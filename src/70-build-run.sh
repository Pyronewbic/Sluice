verify_base() {
  local img="$1" att
  # Only the official base carries a signature we know how to verify. For any other ref (a mirror, a
  # custom base) REQUIRE_SIGNED must FAIL rather than silently pass - else the knob is a no-op exactly
  # for the enterprise mirror case it's meant to protect.
  case "$img" in
    ghcr.io/*sluice-base*) ;;
    *) [ "${SLUICE_REQUIRE_SIGNED:-}" = 1 ] && die "SLUICE_REQUIRE_SIGNED=1 but '$img' is not the official signed base (ghcr.io/.../sluice-base) - sluice can't verify a mirrored/custom ref. Use the official base or unset SLUICE_REQUIRE_SIGNED."
       return 0 ;;
  esac
  if ! command -v cosign >/dev/null 2>&1; then
    [ "${SLUICE_REQUIRE_SIGNED:-}" = 1 ] && die "SLUICE_REQUIRE_SIGNED=1 but cosign is not installed"
    echo "[sluice] ${E_YEL}note${E_RST}: cosign not installed - skipping base signature check ($img)" >&2; return 0
  fi
  if cosign verify "$img" \
       --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
       --certificate-identity-regexp='^https://github\.com/Pyronewbic/Sluice/\.github/workflows/publish-base\.yml@refs/tags/v' >/dev/null 2>&1; then
    echo "[sluice] ${E_GRN}cosign-verified${E_RST} base image: $img" >&2
    # also confirm the signed CycloneDX SBOM attestation (soft; bases signed before this had none).
    cosign verify-attestation --type cyclonedx "$img" \
      --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
      --certificate-identity-regexp='^https://github\.com/Pyronewbic/Sluice/\.github/workflows/publish-base\.yml@refs/tags/v' >/dev/null 2>&1 && att=0 || att=$?
    if [ "$att" = 0 ]; then
      echo "[sluice] ${E_GRN}cosign-verified${E_RST} SBOM attestation: $img" >&2
    else
      [ "${SLUICE_REQUIRE_SIGNED:-}" = 1 ] && die "no verifiable SBOM attestation for $img"
      echo "[sluice] ${E_YEL}note${E_RST}: $img is signed but has no verifiable SBOM attestation (continuing)" >&2
    fi
  else
    [ "${SLUICE_REQUIRE_SIGNED:-}" = 1 ] && die "cosign verification failed for $img"
    echo "[sluice] ${E_YEL}WARNING:${E_RST} could not verify $img (continuing; SLUICE_REQUIRE_SIGNED=1 to enforce)" >&2
  fi
}

# Best-effort stack label for `sluice ls`: the `(detected: X)` note `sluice init` writes into a
# scaffolded config; empty for hand-written / agent configs.
config_stack() { grep -oE 'detected: [^)]+' "$PROJECT_CONFIG" 2>/dev/null | head -1 | sed 's/detected: //' || true; }

build() {
  local tmp; tmp="$(mktemp -d)"
  cp -R "$CORE"/. "$tmp"/
  cp "$PROJECT_CONFIG" "$tmp/sluice.config.sh"
  # F2 dep prefetch: drop the declared manifests into ./prefetch so the project stage can fetch deps
  # at build (free egress) into a $HOME cache the runtime mount won't shadow. Always present (a .keep
  # for non-prefetch builds) so the Dockerfile COPY never fails on a missing dir.
  mkdir -p "$tmp/prefetch"; : > "$tmp/prefetch/.keep"
  local _pf
  set -f   # split the config list on whitespace, not glob it against $PWD
  for _pf in ${SLUICE_PREFETCH_FILES:-}; do
    [ -f "$PROJECT_DIR/$_pf" ] && cp "$PROJECT_DIR/$_pf" "$tmp/prefetch/" 2>/dev/null || true
  done
  set +f
  # Pinned replay (SLUICE_PIN=1): the Dockerfile always COPY's pin/, so keep a .keep there; drop the real
  # sluice.pin in ONLY when pin mode is active (so an env-only SLUICE_PIN=1 still crosses into the build).
  # _SLUICE_PIN_SKIP is an internal, non-contract flag the `update` path sets to re-resolve fresh first.
  mkdir -p "$tmp/pin"; : > "$tmp/pin/.keep"
  local _pin_active=""
  if [ "${SLUICE_PIN:-}" = 1 ] && [ "${_SLUICE_PIN_SKIP:-}" != 1 ]; then
    [ -f "$PROJECT_DIR/sluice.pin" ] || { rm -rf "$tmp"; die "SLUICE_PIN=1 but no sluice.pin - run 'sluice lock --pin' first"; }
    cp "$PROJECT_DIR/sluice.pin" "$tmp/pin/sluice.pin"
    _pin_active=1
  fi
  # Self-describing labels (read by `sluice ls`; not part of config_hash, so no spurious rebuild).
  local args=(--label "sluice.confighash=$(config_hash)"
    --label "sluice.project=$PROJECT_DIR"
    --label "sluice.stack=$(config_stack)"
    --label "sluice.allowcount=$(printf '%s' "${SLUICE_ALLOW_DOMAINS:-}" | wc -w | tr -d ' ')"
    --label "sluice.ports=${SLUICE_PORTS:-}"
    --label "sluice.overlays=${SLUICE_OVERLAY_DIRS:-}"
    --label "sluice.desc=${SLUICE_DESC:-}" "$@")   # extra flags, e.g. --no-cache
  if [ -n "${SLUICE_BASE_IMAGE:-}" ]; then
    verify_base "$SLUICE_BASE_IMAGE"
    args+=(--build-arg "BASE_IMAGE=$SLUICE_BASE_IMAGE")     # project layer FROM the signed base
  fi
  # Pin mode: build FROM the exact base digest recorded in sluice.pin and turn on the replay legs.
  if [ -n "$_pin_active" ]; then
    args+=(--build-arg SLUICE_PIN=1)
    local _pinbase; _pinbase="$(awk '$1=="base"{print $2; exit}' "$PROJECT_DIR/sluice.pin")"
    case "$_pinbase" in *@sha256:*) ;; *) rm -rf "$tmp"; die "sluice.pin has no @sha256 base digest - re-run 'sluice lock --pin'" ;; esac
    if [ -n "${SLUICE_BASE_IMAGE:-}" ]; then
      # Signed-base build: the pinned base must be the same repo as the configured one (else re-pin).
      local _pbrepo="${_pinbase%@*}" _birepo="${SLUICE_BASE_IMAGE%@*}"; _birepo="${_birepo%:*}"; _pbrepo="${_pbrepo%:*}"
      [ "$_pbrepo" = "$_birepo" ] || { rm -rf "$tmp"; die "config base ($SLUICE_BASE_IMAGE) changed since the pin ($_pinbase) - re-run 'sluice lock --pin'"; }
      args+=(--build-arg "BASE_IMAGE=$_pinbase")   # FROM the pinned digest (verify_base already ran above)
    else
      args+=(--build-arg "WOLFI_BASE=$_pinbase")   # local build: pin the wolfi base by digest
    fi
  fi
  # Quiet the engine's build transcript (layer/apk/npm chatter) to a per-box log; on failure replay
  # the tail so the error is visible. The full transcript is always one `cat` away at the logged path.
  local _blog="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug/build.log"
  mkdir -p "$(dirname "$_blog")" 2>/dev/null || _blog="$(mktemp)"
  echo "[sluice] building $tag ... (log: $(_tilde "$_blog"))" >&2
  # SLUICE_BUILD_RETRIES (default 0): retry the build a few times for a flaky registry/network. Off
  # by default so a deterministic build error still fails fast; set e.g. =2 in CI.
  local _retries="${SLUICE_BUILD_RETRIES:-0}"; case "$_retries" in ''|*[!0-9]*) _retries=0 ;; esac
  local _try=0 _ok=""
  while :; do
    if "$ENGINE" build "${args[@]}" -t "$tag" "$tmp" >"$_blog" 2>&1; then _ok=1; break; fi
    [ "$_try" -lt "$_retries" ] || break
    _try=$((_try+1)); echo "[sluice] ${E_YEL}build failed${E_RST} - retry $_try/$_retries ..." >&2; sleep 2
  done
  rm -rf "$tmp"
  if [ -z "$_ok" ]; then
    echo "[sluice] ${E_YEL}build failed${E_RST} - last lines of $(_tilde "$_blog"):" >&2
    tail -n 40 "$_blog" >&2 2>/dev/null || true
    [ -n "$_pin_active" ] && echo "[sluice] ${E_YEL}note${E_RST}: pinned build (SLUICE_PIN=1) - a pinned version may no longer be served (Wolfi is rolling); 'sluice update' re-resolves + re-pins." >&2
    die "image build failed (transient registry/network error? re-run, or set SLUICE_BUILD_RETRIES=N to auto-retry; full log: $_blog)"
  fi
  # Pinned replay: the CLAIM is earned by VERIFICATION, not by the replay legs alone. Assert the built
  # image's inventory matches sluice.lock (write_pin refreshed it from the same pinned closure); die on
  # any drift so a partial replay can never pass as a verified pin.
  if [ -n "$_pin_active" ]; then
    local _pdrift; _pdrift="$(classify_drift "$(lock_drift 2>/dev/null || true)" 2>/dev/null || true)"
    if [ -n "$_pdrift" ]; then
      echo "[sluice] ${E_RED}pinned build did NOT match sluice.lock${E_RST} - replay drift:" >&2
      printf '%s\n' "$_pdrift" | render_drift_human err >&2
      die "pinned replay verification failed - the built image drifted from sluice.lock (a pinned version may be unavailable; 'sluice update' re-resolves + re-pins)"
    fi
    echo "[sluice] ${E_GRN}pinned build verified${E_RST}: inventory matches sluice.lock" >&2
  fi
  "$RUNNER" rm -f -v "$container" >/dev/null 2>&1 || true   # rebuilt image -> fresh container
  runtime_sync_image force
}

# Build only if the image is missing or its baked config hash is stale.
maybe_build() {
  local have want
  want="$(config_hash)"
  have="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)"
  [ "$have" = "$want" ] || build
}

# True when no built image exists at all (a check has nothing to verify against).
image_missing() { ! "$ENGINE" image inspect "$tag" >/dev/null 2>&1; }
# True when the image exists but its baked confighash predates the current config (edited since build).
image_stale() {
  local have want
  want="$(config_hash)"
  have="$("$ENGINE" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' "$tag" 2>/dev/null || true)"
  [ -n "$have" ] && [ "$have" != "$want" ]
}

# SLUICE_MASK launch wiring: validate the patterns (die early; the doctor-side expander skips bad
# ones), then build the mount flags that shadow each CURRENT match - an empty read-only bind for a
# file, a tmpfs for a dir. The box still sees the path exists; it cannot read the contents. The
# empty source file lives in the sluice state root (stable across reboots, unlike a mktemp).
mask_validate() {
  local pat
  set -f   # validate the PATTERNS, not whatever they happen to glob to in $PWD
  for pat in ${SLUICE_MASK:-}; do
    case "$pat" in /*|*..*) die "SLUICE_MASK pattern must be a relative glob inside the project (no leading /, no ..): $pat" ;; esac
  done
  set +f
}
# Fills MASK_ARGS (engine mount flags) + MASKED_PATHS (display list) from the current matches.
mask_build_args() {
  MASK_ARGS=(); MASKED_PATHS=""
  [ -n "${SLUICE_MASK:-}" ] || return 0
  mask_validate
  local matches mp empty
  matches="$(mask_matches 2>/dev/null || true)"
  [ -n "$matches" ] || return 0
  empty="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/.mask-empty"
  mkdir -p "${empty%/*}" 2>/dev/null || true
  [ -f "$empty" ] || : > "$empty" 2>/dev/null || true
  chmod 0444 "$empty" 2>/dev/null || true
  while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    # Overlay workspace: mask the read-only original too, or the entrypoint's seed copy reads it.
    if [ -d "$PROJECT_DIR/$mp" ]; then
      MASK_ARGS+=(--tmpfs "$PROJECT_DIR/$mp")
      [ "${SLUICE_WORKSPACE:-}" = overlay ] && MASK_ARGS+=(--tmpfs "/mnt/sluice-orig/$mp")
    else
      MASK_ARGS+=(-v "$empty":"$PROJECT_DIR/$mp":ro)
      [ "${SLUICE_WORKSPACE:-}" = overlay ] && MASK_ARGS+=(-v "$empty":"/mnt/sluice-orig/$mp":ro)
    fi
    MASKED_PATHS="$MASKED_PATHS $mp"
  done <<EOF
$matches
EOF
  MASKED_PATHS="${MASKED_PATHS# }"
}

# Echo the git common dir to rw-mount for a LINKED worktree - but only when the worktree linkage
# verifies bidirectionally. In non-overlay mode the box (uid 1000) owns $PROJECT_DIR/.git and can rewrite
# it to `gitdir: <other repo>`, which would otherwise steer sluice into rw-mounting + chown'ing an
# arbitrary host repo (cross-repo rewrite; git-hook RCE on Linux). We mount $common only when it is
# OUTSIDE the project AND the worktree's own git dir sits under $common/worktrees/ AND its backlink
# ($common/worktrees/<id>/gitdir) points back at THIS project's .git - a file the box cannot forge (it
# lives outside the box's writable mount). Otherwise warn and mount nothing (use SLUICE_MOUNTS to opt in).
_validated_git_common_dir() {
  git -C "$PROJECT_DIR" rev-parse --git-common-dir >/dev/null 2>&1 || return 0
  local pd common gd back proj_git
  pd="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P || true)"; [ -n "$pd" ] || return 0
  common="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null)"
  case "$common" in /*) ;; *) common="$PROJECT_DIR/$common" ;; esac
  common="$(cd "$common" 2>/dev/null && pwd -P || true)"
  [ -n "$common" ] || return 0
  case "$common/" in "$pd"/*) return 0 ;; esac          # common dir already inside the project mount
  gd="$(git -C "$PROJECT_DIR" rev-parse --absolute-git-dir 2>/dev/null)"
  gd="$(cd "$gd" 2>/dev/null && pwd -P || true)"
  proj_git="$pd/.git"
  if [ -n "$gd" ] && [ -f "$gd/gitdir" ]; then
    case "$gd/" in "$common"/worktrees/*)
      back="$(tr -d '\r\n' < "$gd/gitdir" 2>/dev/null)"
      case "$back" in /*)
        back="$(cd "$(dirname "$back")" 2>/dev/null && pwd -P || true)/$(basename "$back")"
        [ "$back" = "$proj_git" ] && { printf '%s\n' "$common"; return 0; } ;;
      esac ;;
    esac
  fi
  echo "[sluice] ${E_YEL:-}not mounting the git common dir${E_RST:-} ($common) - its worktree linkage doesn't verify against this repo; mount it explicitly via SLUICE_MOUNTS if intended." >&2
  return 0
}

# start: run the idle container (firewall comes up in the entrypoint)
start() {
  "$RUNNER" rm -f -v "$container" >/dev/null 2>&1 || true

  # Optional host-side hook to stage credentials/secrets before launch.
  if [ -n "${SLUICE_PRELAUNCH:-}" ]; then
    command -v "$SLUICE_PRELAUNCH" >/dev/null 2>&1 \
      || die "SLUICE_PRELAUNCH=$SLUICE_PRELAUNCH is not a function/command defined in sluice.config.sh"
    echo "[sluice] running prelaunch hook: $SLUICE_PRELAUNCH"
    "$SLUICE_PRELAUNCH"
  fi

  # route_localnet -> squid intercept; disable_ipv6 -> v4-only proxy (set at run; /proc/sys is ro).
  # cap-drop ALL then add only what the root entrypoint needs: chown the mounted dir (CHOWN/
  # DAC_OVERRIDE/FOWNER), drop squid to its uid (SETUID/SETGID), the firewall (NET_ADMIN/NET_RAW),
  # dnsmasq on :53 (NET_BIND_SERVICE), SIGHUP squid on live reload (KILL). Sessions still run uid
  # 1000 with no effective caps; this shrinks what a hypothetical in-box root could reach.
  # no-new-privileges: an unprivileged session can never gain privs via a setuid binary (defence in
  # depth). pids-limit: a runaway agent or build can't fork-bomb the host (override with
  # SLUICE_PIDS_LIMIT; SLUICE_MEMORY caps RAM).
  local run_args=(--cap-drop ALL
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETUID --cap-add SETGID
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE --cap-add KILL
    --security-opt no-new-privileges
    --pids-limit "${SLUICE_PIDS_LIMIT:-4096}"
    --sysctl net.ipv4.conf.all.route_localnet=1
    --sysctl net.ipv6.conf.all.disable_ipv6=1
    --sysctl net.ipv6.conf.default.disable_ipv6=1)
  [ -n "${SLUICE_MEMORY:-}" ] && run_args+=(--memory "$SLUICE_MEMORY")
  # SLUICE_SECCOMP: opt-in seccomp on top of the dropped caps (unset = the engine's own profile).
  #   hardened - denylist that is a strict superset of the engine default (adds userfaultfd, the
  #              ASLR-disable path, ...); breaks browser-engine userns sandboxes.
  #   browser  - hardened minus the namespace/mount calls Chromium/Playwright need for their own
  #              userns sandbox (ptrace/bpf/modules/userfaultfd/... stay blocked).
  #   audit    - hardened, log-only (SCMP_ACT_LOG): observe what WOULD be blocked, enforce nothing.
  local _sc=""
  case "${SLUICE_SECCOMP:-}" in
    hardened) run_args+=(--security-opt "seccomp=$CORE/seccomp.json") ;;
    browser)  run_args+=(--security-opt "seccomp=$CORE/seccomp-browser.json") ;;
    audit)    # Write the log-only profile to the stable per-box state dir and overwrite in place, so
              # repeated runs don't leak a /tmp file each (a bare mktemp had no reaper - run-default/shell
              # then arm the receipt EXIT trap, which would clobber any rm trap we set here).
              _sc="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug/seccomp-audit.json"
              mkdir -p "${_sc%/*}" 2>/dev/null || _sc="$(mktemp "${TMPDIR:-/tmp}/sluice-seccomp-audit.XXXXXX")"
              sed 's/SCMP_ACT_ERRNO/SCMP_ACT_LOG/g' "$CORE/seccomp.json" > "$_sc"
              run_args+=(--security-opt "seccomp=$_sc") ;;
    ""|default) : ;;
    *) die "SLUICE_SECCOMP must be hardened, browser, or audit (got '${SLUICE_SECCOMP}')" ;;
  esac
  # SLUICE_READONLY_ROOT=1: immutable rootfs. tmpfs the ephemeral system paths; the two dirs that mix
  # baked content with runtime writes (/etc/squid, /home/sluice) become anon volumes (pre-populated
  # from the image, writable). resolv.conf can't be rewritten under --read-only, so we set it via
  # --dns 127.0.0.1 (-> dnsmasq) and hand the real upstream(s) to the entrypoint via SLUICE_DNS_UPSTREAM
  # (probed from a throwaway run). Probe on $RUNNER, not $ENGINE: under SLUICE_RUNTIME=kata the box
  # runs on nerdctl/containerd, whose resolver differs from docker's 127.0.0.11 - probing $ENGINE there
  # would hand dnsmasq an upstream that doesn't exist and silently break all name resolution.
  if [ "${SLUICE_READONLY_ROOT:-}" = 1 ]; then
    local _ro_up
    _ro_up="$("$RUNNER" run --rm --entrypoint sh "$tag" -c 'awk "/^nameserver/{print \$2}" /etc/resolv.conf | grep -v : | tr "\n" " "' 2>/dev/null | sed 's/ *$//')"
    [ -n "$_ro_up" ] || _ro_up="127.0.0.11"
    # Pin mode + size on the system tmpfs: the default (1777, uncapped) would let uid 1000 write these
    # system scratch dirs and fill /var/log/squid to starve squid's access log. /tmp stays 1777 (world
    # scratch); /run + the squid dirs are root/squid-owned 0755 (the entrypoint chowns the squid dirs)
    # and size-capped so a runaway can't exhaust host RAM.
    run_args+=(--read-only
      --tmpfs "/tmp:mode=1777" --tmpfs "/run:mode=0755,size=16m"
      --tmpfs "/var/log/squid:mode=0755,size=64m" --tmpfs "/var/cache/squid:mode=0755,size=256m"
      -v /etc/squid -v /home/sluice
      --dns 127.0.0.1 -e "SLUICE_DNS_UPSTREAM=$_ro_up" -e SLUICE_READONLY_ROOT=1)
  fi
  # SELinux-enforcing hosts deny the box access to a bind mount without a label; run it unconfined for
  # SELinux only (non-root + caps + egress firewall + dir-only mount still confine it).
  selinux_enforcing && run_args+=(--security-opt label=disable)

  # Central policy (SLUICE_POLICY_URL + user/system policy.conf) is applied host-side in apply_policy
  # (slice 60): allow folds into SLUICE_ALLOW_DOMAINS, deny narrows it, forbid/ceilings already gated
  # the run. So the SLUICE_RUNTIME_ALLOW below carries the policy-effective list - no separate pass.

  # Pass the live allowlist at runtime (wins over the baked copy) so an edit (e.g. `sluice learn`) needs
  # no rebuild. Always set, even empty: a removed host takes effect, and the entrypoint can tell it's
  # sluice-launched, not a bare `docker run`.
  run_args+=(-e "SLUICE_RUNTIME_ALLOW=${SLUICE_ALLOW_DOMAINS:-}")

  # Scoped TLS interception (opt-in, default off): SLUICE_BUMP_DOMAINS hosts get decrypted for URL
  # filtering (SLUICE_BUMP_URLS); everything else splices. Passed like the allowlist (live edits, no
  # rebuild). When on, the box mints a per-container CA; the CA-trust env below points clients at it.
  run_args+=(-e "SLUICE_RUNTIME_BUMP=${SLUICE_BUMP_DOMAINS:-}" -e "SLUICE_RUNTIME_BUMP_URLS=${SLUICE_BUMP_URLS:-}")
  # Bumped-lane upload controls (opt-in, only meaningful with SLUICE_BUMP_DOMAINS): a method allowlist +
  # a request-body cap, passed like the other bump knobs (applied at container start, no image rebuild).
  run_args+=(-e "SLUICE_RUNTIME_BUMP_METHODS=${SLUICE_BUMP_METHODS:-}" -e "SLUICE_RUNTIME_BUMP_MAX_BODY=${SLUICE_BUMP_MAX_BODY:-}")
  if [ -n "${SLUICE_BUMP_DOMAINS:-}" ]; then
    run_args+=(-e "NODE_EXTRA_CA_CERTS=/etc/squid/ssl/squid-cert.pem" \
               -e "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" \
               -e "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt")
  fi

  # Mount the project dir rw; SLUICE_WORKDIR tells the entrypoint to chown it to sluice (Linux uid).
  # SLUICE_WORKSPACE=overlay: protect the host repo - mount it READ-ONLY at /mnt/sluice-orig and give
  # the box a writable COPY at the same path (an anon volume the entrypoint fills from the orig). The
  # agent can't touch the host repo; review with `sluice diff`, write back with `sluice apply`.
  if [ "${SLUICE_WORKSPACE:-}" = overlay ]; then
    run_args+=(-v "$PROJECT_DIR":/mnt/sluice-orig:ro -v "$PROJECT_DIR" \
               -e "SLUICE_WORKDIR=$PROJECT_DIR" -e SLUICE_WORKSPACE=overlay)
  else
    run_args+=(-v "$PROJECT_DIR":"$PROJECT_DIR" -e "SLUICE_WORKDIR=$PROJECT_DIR")
  fi

  # git worktree: also mount the common dir (when outside the project) so refs resolve + write. Skipped
  # in overlay mode - an rw common-dir mount would let the agent escape the read-only protection. The
  # linkage is validated so a box-rewritten .git can't redirect the mount to an arbitrary repo (see helper).
  if [ "${SLUICE_WORKSPACE:-}" != overlay ]; then
    local common; common="$(_validated_git_common_dir)"
    [ -n "$common" ] && run_args+=(-v "$common":"$common" -e "SLUICE_GITDIR=$common")
  fi

  # Extra mounts (newline-separated host:container[:ro]).
  if [ -n "${SLUICE_MOUNTS:-}" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] && run_args+=(-v "$m")
    done <<EOF
$SLUICE_MOUNTS
EOF
  fi

  # SLUICE_STATE_DIRS: bind-mount each home-relative dir from a per-project host store
  # ($XDG_STATE_HOME/sluice/<slug>) so agent sessions/auth survive recreation. Relative dirs only
  # (rejected below); never a baked path (.npm-global, cursor's .local).
  if [ -n "${SLUICE_STATE_DIRS:-}" ]; then
    local state_base="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/$slug" sd state_paths=""
    set -f   # split the config list on whitespace, not glob it against $PWD
    for sd in ${SLUICE_STATE_DIRS}; do
      case "$sd" in /*|*..*) die "SLUICE_STATE_DIRS entry must be a relative path under the home dir: $sd";; esac
      mkdir -p "$state_base/$sd"
      run_args+=(-v "$state_base/$sd":"/home/sluice/$sd")
      state_paths="$state_paths /home/sluice/$sd"
    done
    set +f
    run_args+=(-e "SLUICE_STATE_PATHS=$state_paths")
  fi

  # SLUICE_OVERLAY_DIRS: a per-box named volume over each project-relative dir, so the box keeps its
  # own contents (e.g. Linux-built node_modules) while the host's stay untouched. The volume starts
  # EMPTY (install in the box), persists across container recreation, and is labeled for cleanup
  # ('sluice rm'/'prune'). The entrypoint chowns a fresh volume to the sluice user (SLUICE_OVERLAY_PATHS).
  if [ -n "${SLUICE_OVERLAY_DIRS:-}" ]; then
    local od ovol opaths="" odirs=""
    set -f   # split the config list on whitespace, not glob it against $PWD
    for od in ${SLUICE_OVERLAY_DIRS}; do
      case "$od" in /*|*..*) die "SLUICE_OVERLAY_DIRS entry must be a relative path inside the project (no leading /, no ..): $od" ;; esac
      od="${od%/}"
      ovol="sluice-$slug-ov-$(printf '%s' "$od" | tr '[:upper:]' '[:lower:]' | tr -C 'a-z0-9' '-')"
      "$RUNNER" volume create --label "sluice.box=$container" "$ovol" >/dev/null 2>&1 || true
      run_args+=(-v "$ovol":"$PROJECT_DIR/$od")
      opaths="$opaths $PROJECT_DIR/$od"; odirs="$odirs $od"
    done
    set +f
    run_args+=(-e "SLUICE_OVERLAY_PATHS=$opaths")
    echo "[sluice] overlay dirs (box-local volumes, host contents untouched):$odirs" >&2
  fi

  # SLUICE_MASK: shadow in-repo secrets (empty ro bind / tmpfs over each match). Evaluated NOW -
  # a file created later in the run is not masked (THREAT_MODEL.md).
  mask_build_args
  if [ "${#MASK_ARGS[@]}" -gt 0 ]; then
    run_args+=("${MASK_ARGS[@]}")
    _nmask="$(printf '%s' "$MASKED_PATHS" | wc -w | tr -d ' ')"
    echo "[sluice] masking $_nmask in-repo path(s) (unreadable in the box) - see 'sluice doctor'" >&2
  fi

  # Publish declared ports on host loopback only; init-firewall.sh opens the inbound ACCEPT.
  set -f   # split the config list on whitespace, not glob it against $PWD
  for p in ${SLUICE_PORTS:-}; do
    run_args+=(-p "127.0.0.1:$p:$p")
  done
  set +f

  echo "[sluice] starting $container ..."
  runtime_run --name "$container" "${run_args[@]}" "$tag" >/dev/null
  local tries=60; [ "$RUNNER" != "$ENGINE" ] && tries=120   # a Kata micro-VM takes longer to boot
  for _ in $(seq 1 "$tries"); do
    "$RUNNER" logs "$container" 2>&1 | grep -q "\[sluice\] ready" && break
    sleep 0.5
  done
  running || die "container failed to come up - see: sluice logs"
}

ensure_up() { maybe_build; runtime_sync_image; running || start; }

# Build the `<engine> exec` arg vector (sluice user, SLUICE_ENV forwarded, TTY only when attached).
_exec_args() {
  _EXEC_ARGS=(-i --user sluice -w "$PROJECT_DIR")
  [ -t 0 ] && [ -t 1 ] && _EXEC_ARGS+=(-t)
  set -f   # split the config list on whitespace, not glob it against $PWD
  for v in ${SLUICE_ENV:-}; do
    _EXEC_ARGS+=(-e "$v")
  done
  set +f
}
# exec_in replaces this process (shell/run); run_in waits so an EXIT trap can fire after (run-default).
exec_in() { _exec_args; exec "$RUNNER" exec "${_EXEC_ARGS[@]}" "$container" "$@"; }
run_in()  { _exec_args; "$RUNNER" exec "${_EXEC_ARGS[@]}" "$container" "$@"; }

# --- overlay workspace (SLUICE_WORKSPACE=overlay) -------------------------------------------------
# The host repo is mounted read-only at /mnt/sluice-orig; the box works on a writable copy at
# $SLUICE_WORKDIR (== $PROJECT_DIR). The agent can't touch the host repo; these compare/apply the copy.
workspace_is_overlay() { [ "${SLUICE_WORKSPACE:-}" = overlay ]; }

# Echo "added modified deleted" counts between the protected orig and the working copy (0 0 0 if down).
# The working-copy path is passed as $1 (docker exec does NOT inherit the run-time -e SLUICE_WORKDIR).
# Deletions are counted against the boot-time snapshot (/run/sluice-orig-manifest), matching what
# `sluice apply` removes - so a file the host added mid-session never inflates the deleted count.
workspace_counts() {
  running || { echo "0 0 0"; return 0; }
  _root_exec "$container" sh -c '
    O=/mnt/sluice-orig; W="$1"; [ -d "$O" ] || { echo "0 0 0"; exit 0; }
    d="$(diff -rq "$O" "$W" 2>/dev/null)"
    added="$(printf "%s\n" "$d" | grep -c "^Only in $W")"
    modified="$(printf "%s\n" "$d" | grep -c " differ$")"
    if [ -f /run/sluice-orig-manifest ]; then
      cd "$W" && find . -mindepth 1 | sort > /tmp/w
      deleted="$(comm -23 /run/sluice-orig-manifest /tmp/w | grep -c .)"
    else
      deleted="$(printf "%s\n" "$d" | grep -c "^Only in $O")"   # pre-snapshot box: legacy live compare
    fi
    printf "%s %s %s\n" "$added" "$modified" "$deleted"
  ' _ "$PROJECT_DIR" 2>/dev/null || echo "0 0 0"
}

# `sluice diff`: a unified diff of the working copy vs the protected original (.git excluded for signal).
cmd_workspace_diff() {
  workspace_is_overlay || die "sluice diff needs SLUICE_WORKSPACE=overlay (the protected-copy workspace)"
  ensure_up
  _root_exec "$container" sh -c 'diff -ruN --exclude=.git /mnt/sluice-orig "$1" 2>/dev/null' _ "$PROJECT_DIR" || true
}

# `sluice apply`: write the working copy back onto the host repo (adds/mods via tar, then deletions).
cmd_workspace_apply() {
  workspace_is_overlay || die "sluice apply needs SLUICE_WORKSPACE=overlay"
  running || die "the box isn't running - nothing to apply (run 'sluice' first)"
  local a m d; read -r a m d <<EOF
$(workspace_counts)
EOF
  if [ "$((a + m + d))" -eq 0 ]; then echo "[sluice] working copy matches the repo - nothing to apply"; return 0; fi
  # apply WRITES to the host repo - confirm interactively, and refuse non-interactively unless
  # SLUICE_YES=1 (matching 'sluice prune'). The old code fell through and applied on any non-tty.
  if [ -t 0 ] && [ -t 1 ] && [ "${SLUICE_YES:-}" != 1 ]; then
    printf '[sluice] write %s added, %s modified, %s deleted to %s? [y/N] ' "$a" "$m" "$d" "$PROJECT_DIR"
    local ans; read -r ans || ans=n
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "[sluice] not applied."; return 0 ;; esac
  elif [ "${SLUICE_YES:-}" != 1 ]; then
    echo "[sluice] non-interactive: re-run with SLUICE_YES=1 to write these changes to $PROJECT_DIR."
    return 0
  fi
  # Adds + modifications: tar the working copy over the host repo. Surface failures (no 2>/dev/null,
  # check the pipe status) instead of printing a false 'applied'.
  if ! _root_exec "$container" sh -c 'cd "$1" && tar -cf - .' _ "$PROJECT_DIR" | tar -C "$PROJECT_DIR" -xf -; then
    die "apply failed writing to $PROJECT_DIR (check permissions and free space; the host repo may be partially updated)"
  fi
  # Deletions: remove host files the box deleted, against the BOOT-TIME snapshot (not the live ro
  # mount), so a file the host created mid-session is never mistaken for a box deletion (B4).
  # SLUICE_APPLY_NO_DELETE=1 keeps them; a box built before the snapshot existed fails safe.
  local applied_del="$d"
  if [ "$d" -eq 0 ]; then :
  elif [ "${SLUICE_APPLY_NO_DELETE:-}" = 1 ]; then
    echo "[sluice] ${E_YEL}SLUICE_APPLY_NO_DELETE=1${E_RST} - keeping the $d host file(s) the box deleted." >&2
    applied_del=0
  elif _root_exec "$container" sh -c 'test -f /run/sluice-orig-manifest' 2>/dev/null; then
    _root_exec "$container" sh -c 'cd "$1" && find . -mindepth 1 | sort > /tmp/w; comm -23 /run/sluice-orig-manifest /tmp/w' _ "$PROJECT_DIR" 2>/dev/null \
      | while IFS= read -r p; do [ -n "$p" ] && rm -rf "${PROJECT_DIR:?}/${p#./}" 2>/dev/null; done
  else
    echo "[sluice] ${E_YEL}note:${E_RST} this box predates the apply-safety snapshot - skipping the $d deletion(s); 'sluice rebuild' then re-apply to propagate them." >&2
    applied_del=0
  fi
  echo "[sluice] applied $a added, $m modified, $applied_del deleted to $PROJECT_DIR."
}

# After a run-default session, print an egress receipt: hosts the box reached (hit counts, most-hit
# first) and hosts the firewall blocked (review these). stderr-only so it never pollutes the app's
# stdout; silent when there was no egress. Detailed per-host view: `sluice egress`.
