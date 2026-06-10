verify_base() {
  local img="$1" att
  case "$img" in ghcr.io/*sluice-base*) ;; *) return 0 ;; esac   # only auto-verify our own base
  if ! command -v cosign >/dev/null 2>&1; then
    [ "${SLUICE_REQUIRE_SIGNED:-}" = 1 ] && die "SLUICE_REQUIRE_SIGNED=1 but cosign is not installed"
    echo "[sluice] ${E_YEL}note${E_RST}: cosign not installed - skipping base signature check ($img)" >&2; return 0
  fi
  if cosign verify "$img" \
       --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
       --certificate-identity-regexp='^https://github.com/Pyronewbic/Sluice/' >/dev/null 2>&1; then
    echo "[sluice] ${E_GRN}cosign-verified${E_RST} base image: $img" >&2
    # also confirm the signed CycloneDX SBOM attestation (soft; bases signed before this had none).
    cosign verify-attestation --type cyclonedx "$img" \
      --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
      --certificate-identity-regexp='^https://github.com/Pyronewbic/Sluice/' >/dev/null 2>&1 && att=0 || att=$?
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
  for _pf in ${SLUICE_PREFETCH_FILES:-}; do
    [ -f "$PROJECT_DIR/$_pf" ] && cp "$PROJECT_DIR/$_pf" "$tmp/prefetch/" 2>/dev/null || true
  done
  # Self-describing labels (read by `sluice ls`; not part of config_hash, so no spurious rebuild).
  local args=(--label "sluice.confighash=$(config_hash)"
    --label "sluice.project=$PROJECT_DIR"
    --label "sluice.stack=$(config_stack)"
    --label "sluice.allowcount=$(printf '%s' "${SLUICE_ALLOW_DOMAINS:-}" | wc -w | tr -d ' ')"
    --label "sluice.ports=${SLUICE_PORTS:-}"
    --label "sluice.desc=${SLUICE_DESC:-}" "$@")   # extra flags, e.g. --no-cache
  if [ -n "${SLUICE_BASE_IMAGE:-}" ]; then
    verify_base "$SLUICE_BASE_IMAGE"
    args+=(--build-arg "BASE_IMAGE=$SLUICE_BASE_IMAGE")     # project layer FROM the signed base
  fi
  echo "[sluice] building $tag ..."
  if "$ENGINE" build "${args[@]}" -t "$tag" "$tmp"; then
    rm -rf "$tmp"
  else
    rm -rf "$tmp"; die "image build failed"
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
    audit)    _sc="$(mktemp "${TMPDIR:-/tmp}/sluice-seccomp-audit.XXXXXX")"
              sed 's/SCMP_ACT_ERRNO/SCMP_ACT_LOG/g' "$CORE/seccomp.json" > "$_sc"
              run_args+=(--security-opt "seccomp=$_sc") ;;
    ""|default) : ;;
    *) die "SLUICE_SECCOMP must be hardened, browser, or audit (got '${SLUICE_SECCOMP}')" ;;
  esac
  # SLUICE_READONLY_ROOT=1: immutable rootfs. tmpfs the ephemeral system paths; the two dirs that mix
  # baked content with runtime writes (/etc/squid, /home/sluice) become anon volumes (pre-populated
  # from the image, writable). resolv.conf can't be rewritten under --read-only, so we set it via
  # --dns 127.0.0.1 (-> dnsmasq) and hand the real upstream(s) to the entrypoint via SLUICE_DNS_UPSTREAM
  # (probed from a throwaway run of the image, which still has docker's default resolv.conf).
  if [ "${SLUICE_READONLY_ROOT:-}" = 1 ]; then
    local _ro_up
    _ro_up="$("$ENGINE" run --rm --entrypoint sh "$tag" -c 'awk "/^nameserver/{print \$2}" /etc/resolv.conf | grep -v : | tr "\n" " "' 2>/dev/null | sed 's/ *$//')"
    [ -n "$_ro_up" ] || _ro_up="127.0.0.11"
    run_args+=(--read-only
      --tmpfs /tmp --tmpfs /run --tmpfs /var/log/squid --tmpfs /var/cache/squid
      -v /etc/squid -v /home/sluice
      --dns 127.0.0.1 -e "SLUICE_DNS_UPSTREAM=$_ro_up" -e SLUICE_READONLY_ROOT=1)
  fi
  # SELinux-enforcing hosts deny the box access to a bind mount without a label; run it unconfined for
  # SELinux only (non-root + caps + egress firewall + dir-only mount still confine it).
  selinux_enforcing && run_args+=(--security-opt label=disable)

  # SLUICE_POLICY_URL: fetch a central allowlist on the host (free egress, before lockdown) and merge
  # it into the box's policy at run. Plain text, one host/line, # comments OK. Additive + host-trusted;
  # a fetch failure warns and uses the local allowlist.
  if [ -n "${SLUICE_POLICY_URL:-}" ]; then
    local policy_raw policy_hosts
    if policy_raw="$(curl -fsSL --max-time 10 "$SLUICE_POLICY_URL" 2>/dev/null)"; then
      policy_hosts="$(printf '%s\n' "$policy_raw" | sed 's/#.*//' | awk '{$1=$1};1' | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"
      [ -n "$policy_hosts" ] && run_args+=(-e "SLUICE_POLICY_ALLOW=$policy_hosts")
      echo "[sluice] egress policy from $SLUICE_POLICY_URL ($(printf '%s' "$policy_hosts" | wc -w | tr -d ' ') hosts)"
    else
      echo "[sluice] ${E_YEL}WARNING:${E_RST} could not fetch SLUICE_POLICY_URL=$SLUICE_POLICY_URL - using the local allowlist" >&2
    fi
  fi

  # Pass the live allowlist at runtime (wins over the baked copy) so an edit (e.g. `sluice learn`) needs
  # no rebuild. Always set, even empty: a removed host takes effect, and the entrypoint can tell it's
  # sluice-launched, not a bare `docker run`.
  run_args+=(-e "SLUICE_RUNTIME_ALLOW=${SLUICE_ALLOW_DOMAINS:-}")

  # Scoped TLS interception (opt-in, default off): SLUICE_BUMP_DOMAINS hosts get decrypted for URL
  # filtering (SLUICE_BUMP_URLS); everything else splices. Passed like the allowlist (live edits, no
  # rebuild). When on, the box mints a per-container CA; the CA-trust env below points clients at it.
  run_args+=(-e "SLUICE_RUNTIME_BUMP=${SLUICE_BUMP_DOMAINS:-}" -e "SLUICE_RUNTIME_BUMP_URLS=${SLUICE_BUMP_URLS:-}")
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
  # in overlay mode - an rw common-dir mount would let the agent escape the read-only protection.
  if [ "${SLUICE_WORKSPACE:-}" != overlay ] && git -C "$PROJECT_DIR" rev-parse --git-common-dir >/dev/null 2>&1; then
    local common; common="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir)"
    case "$common" in /*) ;; *) common="$PROJECT_DIR/$common";; esac
    common="$(cd "$common" 2>/dev/null && pwd || true)"
    if [ -n "$common" ]; then
      case "$common/" in "$PROJECT_DIR"/*) ;; *) run_args+=(-v "$common":"$common" -e "SLUICE_GITDIR=$common");; esac
    fi
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
    for sd in ${SLUICE_STATE_DIRS}; do
      case "$sd" in /*|*..*) die "SLUICE_STATE_DIRS entry must be a relative path under the home dir: $sd";; esac
      mkdir -p "$state_base/$sd"
      run_args+=(-v "$state_base/$sd":"/home/sluice/$sd")
      state_paths="$state_paths /home/sluice/$sd"
    done
    run_args+=(-e "SLUICE_STATE_PATHS=$state_paths")
  fi

  # SLUICE_MASK: shadow in-repo secrets (empty ro bind / tmpfs over each match). Evaluated NOW -
  # a file created later in the run is not masked (THREAT_MODEL.md).
  mask_build_args
  if [ "${#MASK_ARGS[@]}" -gt 0 ]; then
    run_args+=("${MASK_ARGS[@]}")
    echo "[sluice] masking (unreadable in the box): $MASKED_PATHS"
  fi

  # Publish declared ports on host loopback only; init-firewall.sh opens the inbound ACCEPT.
  for p in ${SLUICE_PORTS:-}; do
    run_args+=(-p "127.0.0.1:$p:$p")
  done

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
  for v in ${SLUICE_ENV:-}; do
    _EXEC_ARGS+=(-e "$v")
  done
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
workspace_counts() {
  running || { echo "0 0 0"; return 0; }
  "$RUNNER" exec "$container" sh -c '
    O=/mnt/sluice-orig; W="$1"; [ -d "$O" ] || { echo "0 0 0"; exit 0; }
    d="$(diff -rq "$O" "$W" 2>/dev/null)"
    printf "%s %s %s\n" \
      "$(printf "%s\n" "$d" | grep -c "^Only in $W")" \
      "$(printf "%s\n" "$d" | grep -c " differ$")" \
      "$(printf "%s\n" "$d" | grep -c "^Only in $O")"
  ' _ "$PROJECT_DIR" 2>/dev/null || echo "0 0 0"
}

# `sluice diff`: a unified diff of the working copy vs the protected original (.git excluded for signal).
cmd_workspace_diff() {
  workspace_is_overlay || die "sluice diff needs SLUICE_WORKSPACE=overlay (the protected-copy workspace)"
  ensure_up
  "$RUNNER" exec "$container" sh -c 'diff -ruN --exclude=.git /mnt/sluice-orig "$1" 2>/dev/null' _ "$PROJECT_DIR" || true
}

# `sluice apply`: write the working copy back onto the host repo (adds/mods via tar, then deletions).
cmd_workspace_apply() {
  workspace_is_overlay || die "sluice apply needs SLUICE_WORKSPACE=overlay"
  running || die "the box isn't running - nothing to apply (run 'sluice' first)"
  local a m d; read -r a m d <<EOF
$(workspace_counts)
EOF
  if [ "$((a + m + d))" -eq 0 ]; then echo "[sluice] working copy matches the repo - nothing to apply"; return 0; fi
  if [ -t 0 ] && [ -t 1 ] && [ "${SLUICE_YES:-}" != 1 ]; then
    printf '[sluice] write %s added, %s modified, %s deleted to %s? [y/N] ' "$a" "$m" "$d" "$PROJECT_DIR"
    local ans; read -r ans || ans=n
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "[sluice] not applied."; return 0 ;; esac
  fi
  "$RUNNER" exec "$container" sh -c 'cd "$1" && tar -cf - .' _ "$PROJECT_DIR" 2>/dev/null | tar -C "$PROJECT_DIR" -xf - 2>/dev/null
  "$RUNNER" exec "$container" sh -c 'cd /mnt/sluice-orig && find . -mindepth 1 | sort > /tmp/o; cd "$1" && find . -mindepth 1 | sort > /tmp/w; comm -23 /tmp/o /tmp/w' _ "$PROJECT_DIR" 2>/dev/null \
    | while IFS= read -r p; do [ -n "$p" ] && rm -rf "${PROJECT_DIR:?}/${p#./}" 2>/dev/null; done
  echo "[sluice] applied $a added, $m modified, $d deleted to $PROJECT_DIR."
}

# After a run-default session, print an egress receipt: hosts the box reached (hit counts, most-hit
# first) and hosts the firewall blocked (review these). stderr-only so it never pollutes the app's
# stdout; silent when there was no egress. Detailed per-host view: `sluice egress`.
