#!/usr/bin/env bats
# `sluice doctor` project scans that need no box (work with or without an engine daemon):
# SLUICE_MASK posture + the unmasked-secret warning. Each @test gets its own temp project.
load test_helper/common

setup() { WORK="$(mktemp -d)"; }
teardown() { rm -rf "$WORK"; }

@test "doctor: warns on a secret-looking file that is not masked" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "secret-looking"
  assert_output --partial ".env"
  assert_output --partial "SLUICE_MASK"
}

@test "doctor: lists active masks and stops warning once the file is covered" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "mask"
  assert_output --partial "1 path(s) masked"
  refute_output --partial "secret-looking"
}

@test "doctor: a nested secret is NOT covered by a root-level pattern (still warns)" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/packages/api"
  echo "SECRET=1" > "$WORK/packages/api/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "secret-looking"
  assert_output --partial "packages/api/.env"
}

@test "doctor: warns when a masked file is git-tracked (in-box git would see it emptied)" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  ( cd "$WORK" && git init -q && git add .env \
      && git -c user.email=t@t -c user.name=t commit -qm x )
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "git-tracked"
  assert_output --partial ".env"
}

@test "doctor: an untracked masked file raises no git-tracked warning" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  ( cd "$WORK" && git init -q )
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "git-tracked"
}

@test "doctor: .env.example is scaffolding, not a secret (no warning)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=" > "$WORK/.env.example"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "secret-looking"
}

# The candidate cap must bound the WARNED (unmasked) set, not the raw find stream: if masked files eat
# the cap's slots, an unmasked secret past it is never tested (a false pass). Deterministic guard: stub
# `find` to emit >50 MASKED entries BEFORE the lone unmasked secret, so the old cap-before-filter code
# drops it (it never reaches the mask filter) while filter-then-cap keeps it - independent of real find
# traversal order. (Extract the functions from bin/sluice, the pattern verify-lock/policy-unit use.)
@test "doctor: unmasked secret past the cap is still reported (mask filters before the cap)" {
  local t="$BATS_TEST_TMPDIR/unmasked_cap.sh"
  cat > "$t" <<'STUBS'
set -euo pipefail
SLUICE_MASK=".env*"
PROJECT_DIR=/proj
# 60 masked .env entries (root-level), THEN the unmasked secret at position 61 - well past the 50 cap.
find() { local i=0; while [ "$i" -lt 60 ]; do printf '%s/.env.%03d\n' "$PROJECT_DIR" "$i"; i=$((i+1)); done; printf '%s/d1/d2/deep.pem\n' "$PROJECT_DIR"; }
STUBS
  sed -n '/^mask_covers()/,/^}/p; /^unmasked_secrets()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  echo 'unmasked_secrets' >> "$t"
  run bash "$t"
  assert_success
  assert_output --partial 'd1/d2/deep.pem'   # the unmasked secret survives filter-then-cap
  refute_output --partial '.env'             # masked files never enter the warned set
}

@test "doctor: secret scan prunes vendor dirs (node_modules .env ignored)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/node_modules/pkg"
  echo "SECRET=1" > "$WORK/node_modules/pkg/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "secret-looking"
}

@test "doctor --json: mask patterns / masked / unmasked_secrets" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  echo "key-material" > "$WORK/server.pem"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = d['mask']
assert m['patterns'] == ['.env*'], m
assert m['masked'] == ['.env'], m
assert m['unmasked_secrets'] == ['server.pem'], m
"
}

@test "doctor --json: no mask configured -> empty arrays, still valid JSON" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['mask'] == {'patterns': [], 'masked': [], 'unmasked_secrets': []}, d['mask']
"
}

# The versioned-data-contract stamp: `doctor --json` carries a schema id so a consumer can key on it
# (fields are only ADDED within /v1; a removal/rename bumps the suffix - docs/operations.md contracts).
@test "doctor --json: carries the sluice.doctor/v1 schema stamp" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['schema']=='sluice.doctor/v1', d.get('schema')"
}

# --- dangling-symlink check ---------------------------------------------------------------------

@test "doctor: warns on a symlink that resolves outside the mounted scope" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  OUTSIDE="$(mktemp -d)"
  echo shared > "$OUTSIDE/shared.md"
  mkdir -p "$WORK/.claude"
  ln -s "$OUTSIDE/shared.md" "$WORK/.claude/CLAUDE.md"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "broken inside the box"
  assert_output --partial ".claude/CLAUDE.md"
  rm -rf "$OUTSIDE"
}

@test "doctor: warns on a dangling out-of-scope symlink (target gone)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  ln -s /nonexistent/elsewhere "$WORK/dangler"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "broken inside the box"
  assert_output --partial "dangler"
}

@test "doctor: an in-repo symlink is fine (no warning)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo real > "$WORK/real.txt"
  ln -s real.txt "$WORK/alias.txt"
  mkdir -p "$WORK/sub"
  ln -s ../real.txt "$WORK/sub/up.txt"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "broken inside the box"
}

@test "doctor: a worktree symlink into the git common dir is in scope (no warning)" {
  command -v git >/dev/null 2>&1 || skip "git not present"
  ( cd "$WORK" && git init -q main && cd main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && git worktree add -q "$WORK/wt" >/dev/null 2>&1 )
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/wt/sluice.config.sh"
  ln -s "$WORK/main/.git/HEAD" "$WORK/wt/head-link"
  run bash -c "cd '$WORK/wt' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "head-link"
}

@test "doctor: symlink scan prunes vendor dirs (node_modules .bin links ignored)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/node_modules/.bin"
  ln -s /usr/bin/true "$WORK/node_modules/.bin/fake"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "broken inside the box"
}

@test "doctor --json: broken_symlinks lists the project-relative link path" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  ln -s /nonexistent/elsewhere "$WORK/dangler"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['broken_symlinks'] == ['dangler'], d['broken_symlinks']
"
}

# --- SLUICE_OVERLAY_DIRS surfacing --------------------------------------------------------------

@test "doctor: lists overlay dirs" {
  printf 'SLUICE_OVERLAY_DIRS="node_modules"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "overlays"
  assert_output --partial "node_modules"
}

@test "doctor --json: overlay_dirs from the config" {
  printf 'SLUICE_OVERLAY_DIRS="node_modules .venv"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['overlay_dirs'] == ['node_modules', '.venv'], d['overlay_dirs']
"
}

# --- hardening / risk / mounts posture (R4/R5) --------------------------------------------------

@test "doctor: human harden line lists active opt-ins" {
  printf 'SLUICE_SECCOMP=hardened\nSLUICE_READONLY_ROOT=1\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "harden"
  assert_output --partial "seccomp=hardened"
  assert_output --partial "readonly-root"
}

@test "doctor --json: hardening object reflects the knobs" {
  printf 'SLUICE_SECCOMP=browser\nSLUICE_WORKSPACE=overlay\nSLUICE_MEMORY=2g\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
h = json.load(sys.stdin)['hardening']
assert h['seccomp'] == 'browser', h
assert h['workspace_overlay'] is True, h
assert h['memory'] == '2g', h
assert h['pids_limit'] == '4096', h
assert h['readonly_root'] is False, h
"
}

@test "doctor --json: risk flags laundering + DoH allowlisted hosts" {
  printf 'SLUICE_ALLOW_DOMAINS="api.openai.com cloudflare-dns.com github.com"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
r = json.load(sys.stdin)['risk']
assert r['laundering_hosts'] == ['api.openai.com'], r
assert r['doh_hosts'] == ['cloudflare-dns.com'], r
assert r['allow_doh'] is False, r
"
}

@test "doctor --json: mounts array surfaces extra binds (spec + exists)" {
  # An existing host source -> exists:true. (/tmp exists on every CI runner + macOS.)
  printf 'SLUICE_MOUNTS="/tmp:/home/sluice/x:ro"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['mounts'] == [{'spec': '/tmp:/home/sluice/x:ro', 'exists': True}], d['mounts']
"
}

# A7: a missing host source passes doctor today but errors the engine at run - warn (human) +
# carry exists:false (json), so the misconfig is caught before the box is even built.
@test "doctor --json: a missing host mount source carries exists:false" {
  printf 'SLUICE_MOUNTS="/no/such/host/path:/home/sluice/x:ro"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['mounts'] == [{'spec': '/no/such/host/path:/home/sluice/x:ro', 'exists': False}], d['mounts']
"
}

@test "doctor: a missing host mount source lists the spec and warns it will fail" {
  printf 'SLUICE_MOUNTS="/no/such/host/path:/home/sluice/x:ro"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "/no/such/host/path:/home/sluice/x:ro"   # the spec is on the human side now
  assert_output --partial "host path not found"                    # ... with the run-will-fail warning
}

@test "doctor --json: no hardening configured -> defaults, still valid" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['hardening']['seccomp'] == 'default', d['hardening']
assert d['risk'] == {'laundering_hosts': [], 'doh_hosts': [], 'allow_doh': False}, d['risk']
assert d['mounts'] == [], d['mounts']
"
}

# --- A5/A6: config arrays must never pathname-expand against the cwd -----------------------------
# A glob metachar in the allowlist/ips (e.g. SLUICE_ALLOW_IPS="1.2.3.4 *") must stay a literal, not
# expand to whatever files happen to sit in the project dir. We seed decoy filenames in the cwd; if
# the unquoted expansion globbed, those names would leak into the JSON arrays (A5) or be classified
# by the risk loops (A6). Human and --json must also AGREE on the literal.
@test "doctor --json: a glob metachar in the allowlist/ips does NOT expand to filenames" {
  printf 'SLUICE_ALLOW_DOMAINS="github.com *"\nSLUICE_ALLOW_IPS="1.2.3.4 *"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  : > "$WORK/DECOY_A" ; : > "$WORK/DECOY_B"   # files a buggy glob would expand '*' into
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
flat = json.dumps(d)
assert 'DECOY_A' not in flat and 'DECOY_B' not in flat, 'glob expanded into the cwd: ' + flat
assert d['allowlist'] == ['github.com', '*'], d['allowlist']
assert d['allow_ips'] == ['1.2.3.4', '*'], d['allow_ips']
"
}

@test "doctor: a wildcard laundering host shows literally in the human note, not globbed" {
  # The risk loop is the only UNQUOTED human-side allowlist surface; the decoy MATCHES the wildcard so
  # the old (un-set -f) loop globs it into the laundering note. The quoted allowlist/ips _doc lines
  # never globbed, so they can't tell fixed from broken - this case can.
  printf 'SLUICE_ALLOW_DOMAINS="*.s3.amazonaws.com github.com"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  : > "$WORK/evil.s3.amazonaws.com"   # matches *.s3.amazonaws.com
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "*.s3.amazonaws.com"     # the literal wildcard, classified as a laundering host
  refute_output --partial "evil.s3.amazonaws.com"  # the decoy filename never leaks into the note
}

# A6: the laundering/DoH risk loops iterate the allowlist - a wildcard entry (e.g. *.s3.amazonaws.com)
# must classify the LITERAL host, never a globbed filename, even with decoys in the cwd.
@test "doctor --json: a wildcard laundering host is classified literally, not globbed" {
  printf 'SLUICE_ALLOW_DOMAINS="*.s3.amazonaws.com github.com"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  : > "$WORK/evil.s3.amazonaws.com"   # MATCHES *.s3.amazonaws.com: old unguarded loop globs this filename in
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
r = json.load(sys.stdin)['risk']
assert r['laundering_hosts'] == ['*.s3.amazonaws.com'], r   # literal wildcard, not the globbed decoy filename
"
}

# --- A9: explicit-but-missing SLUICE_ENGINE gets the right remedy -------------------------------
# SLUICE_ENGINE naming a binary not on PATH must NOT suggest 'install docker or podman' (it IS
# installed-intent; the name is just wrong) - mirror resolve_engine's "not found on PATH".
@test "doctor: SLUICE_ENGINE set but not on PATH reports 'not found on PATH', not 'install'" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && SLUICE_ENGINE=__nope__ '$SLUICE' doctor"
  assert_success
  assert_output --partial "SLUICE_ENGINE='__nope__' not found on PATH"
  refute_output --partial "install docker or podman"
}

@test "doctor --json: SLUICE_ENGINE set but not on PATH -> engine_found false" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && SLUICE_ENGINE=__nope__ '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['engine_found'] is False, d
"
}

# --- A3: the daemon/image probes are bounded so doctor can't hang on a black-hole engine --------
# A truly wedged daemon isn't reproducible no-Docker, so test the _with_timeout primitive directly:
# a slow command is KILLED within ~the bound and reports non-zero (124, coreutils' timeout code),
# while a fast command passes its real status through. (Extract the fn from bin/sluice, the pattern
# the unmasked-cap test above uses.)
@test "doctor: _with_timeout kills a slow command within the bound (non-zero)" {
  local t="$BATS_TEST_TMPDIR/with_timeout.sh"
  echo 'set -euo pipefail' > "$t"
  sed -n '/^_with_timeout()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  {
    echo '_with_timeout 5 true && echo FAST_OK'                         # fast success -> rc 0
    echo 'if _with_timeout 5 false; then echo BUG; else echo FAST_FAIL_OK; fi'  # fast non-zero passes through
    echo 's=$(date +%s); if _with_timeout 1 sleep 10; then echo SLOW_BUG; else echo "SLOW_KILLED rc=$?"; fi; e=$(date +%s); echo "ELAPSED=$((e-s))"'
  } >> "$t"
  run bash "$t"
  assert_success
  assert_output --partial "FAST_OK"
  assert_output --partial "FAST_FAIL_OK"
  assert_output --partial "SLOW_KILLED"        # the slow command was terminated, not awaited to completion
  # killed well under the command's own 10s sleep (bound is 1s; allow generous slack for CI)
  local elapsed; elapsed="$(printf '%s\n' "$output" | sed -n 's/^ELAPSED=//p')"
  [ -n "$elapsed" ] && [ "$elapsed" -lt 8 ]
}

# A syntax-error config must not abort doctor - it's the command you run BECAUSE the config is broken.
# The human report flags the parse error and CONTINUES (later lines present).
@test "doctor: a config with a syntax error is flagged but the report still completes" {
  printf 'SLUICE_RUN_CMD="bash"\nif [ \n' > "$WORK/sluice.config.sh"   # unterminated 'if' = parse error
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "parse error"
  assert_output --partial "allowlist"   # a line AFTER the config source: doctor did not abort
}

# The JSON path must ALWAYS print one valid JSON object (never empty/truncated) and carry the signal.
@test "doctor --json: a config syntax error -> non-empty valid JSON with config_error true" {
  printf 'SLUICE_RUN_CMD="bash"\nif [ \n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  [ -n "$output" ]   # not empty
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)       # parses -> exactly one valid object
assert isinstance(d, dict), d
assert d['config_error'] is True, d
assert d['config'] is not None, d
"
}

# A non-zero top-level line in the config (valid syntax, so bash -n passes) must not abort doctor
# either - relaxed errexit around the source covers it; config_error stays false (it parsed fine).
@test "doctor --json: a config whose top-level line returns non-zero still reports (no abort)" {
  printf 'SLUICE_RUN_CMD="bash"\nfalse\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['config_error'] is False, d   # valid syntax: the parse check passed
"
}

# doctor must not die on a typo'd SLUICE_RUNTIME - it's the command you run to DIAGNOSE that.
@test "doctor: a bad SLUICE_RUNTIME warns and still reports (does not die)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && SLUICE_RUNTIME=kat '$SLUICE' doctor"
  assert_success
  assert_output --partial "not supported"
}

# --- readout polish: trailing verdict / lead-then-list / always-on rows / severity order ----------

# ITEM 1: doctor ends with a trailing verdict line. A clean config (no warnings reachable without an
# engine) gets the green all-clear; the old code printed NO verdict at all, so this fails against it.
@test "doctor: a clean config ends with the green all-clear verdict" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "ready - no action needed"
}

# ITEM 1: a single warning (a lone unmasked .env) yields the SINGULAR "1 item needs attention". The old
# code printed no verdict line, so both the count and the wording are absent from it.
@test "doctor: a single warning yields the singular '1 item needs attention' verdict" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "1 item needs attention"
}

# ITEM 1: two distinct warnings (unmasked secret + broken symlink) pluralize to "2 items need
# attention". Guards the singular/plural branch + that independent sites both increment the counter.
@test "doctor: two warnings pluralize to '2 items need attention'" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  ln -s /nonexistent/elsewhere "$WORK/dangler"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "2 items need attention"
}

# ITEM 2: the unmasked-secret warning is a LEAD line carrying a COUNT, then one file per line - not a
# single space-joined line. The old code emitted "secret-looking file(s) readable in the box - <files>"
# with no count, so the "N secret-looking file(s)" lead is the discriminator (also asserts the per-file
# lines render). Two secrets so the count is unambiguous.
@test "doctor: secret warning leads with a count, then one file per line" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  echo "k" > "$WORK/server.pem"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "2 secret-looking file(s) readable in the box"   # the new counted lead line
  assert_output --partial ".env"                                           # ... then each file on its own line
  assert_output --partial "server.pem"
}

# ITEM 3: the harden row is ALWAYS shown. With no opt-in hardening, the old code printed no harden row
# at all; the new code shows the effective default posture.
@test "doctor: harden row shows the default posture when nothing is opted in" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "defaults (seccomp=default, root rw, workspace=bind)"
}

# ITEM 4: SLUICE_ALLOW_IPS renders under a real left-column "ips" label, NOT a hand-typed "ips:" prefix
# in the value. The old line was `<pad>ips:  <value>`; refuting "ips:" fails against it (it contains the
# colon) and passes against the new label form, while the value itself is still present.
@test "doctor: allow-ips uses a real label, not a hand-typed 'ips:' prefix" {
  printf 'SLUICE_ALLOW_IPS="1.2.3.4 5.6.7.8:443"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "1.2.3.4"     # the value still shows
  refute_output --partial "ips:"        # ... but no hand-typed "ips:" prefix (old code had it)
}

# ITEM 5: hazard notes print by severity - the DoH-allowed-exfil note (highest) leads, BEFORE the
# informational "base:" line. The old order printed "base:" first. We assert on line ORDER: the index
# of the exfil note must be smaller than the index of the base line.
@test "doctor: the DoH-exfil hazard note prints before the informational base line" {
  printf 'SLUICE_ALLOW_DOMAINS="cloudflare-dns.com"\nSLUICE_ALLOW_DOH=1\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "DNS-over-HTTPS exfil is possible"
  local doh_ln base_ln
  doh_ln="$(printf '%s\n' "$output" | grep -n "DNS-over-HTTPS exfil is possible" | head -1 | cut -d: -f1)"
  base_ln="$(printf '%s\n' "$output" | grep -n "^ *base: "                       | head -1 | cut -d: -f1)"
  [ -n "$doh_ln" ] && [ -n "$base_ln" ]
  [ "$doh_ln" -lt "$base_ln" ]   # the dangerous note leads the informational base line
}

# ITEM 6: the blocked-host list renders via the PURE _doctor_bullets helper (capped at 10 + "(+ N more)").
# blocked_new needs a running box (not no-Docker testable), so we unit-test the helper directly via the
# sed-extract pattern. The old bin/sluice has no such function, so the extract is empty and the call
# fails to the shell - this @test cannot pass against pre-change code.
@test "doctor: _doctor_bullets caps the list at 10 with a '(+ N more)' tail" {
  local t="$BATS_TEST_TMPDIR/bullets.sh"
  {
    echo 'set -euo pipefail'
    echo 'C_RED=""; C_RST=""; C_DIM=""'   # NO_COLOR-equivalent so assertions match plain text
  } > "$t"
  sed -n '/^_term_esc()/{p;q;}'      "$ROOT/bin/sluice" >> "$t"   # _term_esc is a one-liner (brace is mid-line); print the defining line and quit
  sed -n '/^_doctor_bullets()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  echo 'seq 1 13 | _doctor_bullets "$C_RED"' >> "$t"
  run bash "$t"
  assert_success
  assert_output --partial "1"
  assert_output --partial "10"
  assert_output --partial "(+ 3 more)"   # 13 items - first 10 shown = 3 more
  refute_output --partial "11"            # capped: the 11th item is not listed
}

# ITEM 6 (cont): the helper drops blank lines and strips control chars (a crafted hostname can't smuggle
# terminal escapes into the readout). Also covers the empty-input -> nothing, rc 0 contract.
@test "doctor: _doctor_bullets drops blanks, strips control chars, and is empty-safe" {
  local t="$BATS_TEST_TMPDIR/bullets_esc.sh"
  {
    echo 'set -euo pipefail'
    echo 'C_RED=""; C_RST=""; C_DIM=""'
  } > "$t"
  sed -n '/^_term_esc()/{p;q;}'      "$ROOT/bin/sluice" >> "$t"   # _term_esc is a one-liner (brace is mid-line); print the defining line and quit
  sed -n '/^_doctor_bullets()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  {
    echo 'printf "" | _doctor_bullets; echo "EMPTY_RC=$?"'                 # empty input: nothing, rc 0
    echo 'printf "a\n\n\nb\n" | _doctor_bullets'                          # blank lines dropped
    echo 'printf "ev\033[31mil\n" | _doctor_bullets | cat -v'             # ESC stripped
  } >> "$t"
  run bash "$t"
  assert_success
  assert_output --partial "EMPTY_RC=0"
  refute_output --partial "^["            # the raw ESC byte is stripped (cat -v renders a survivor as ^[)
  assert_output --partial "ev[31mil"      # only the control byte goes; the printable residue stays inert
}

@test "doctor: the egress-blocked branch is gated by _audit_readable (fail-closed, structural)" {
  # an empty blocked set must consult _audit_readable before the green 'no blocked egress',
  # so a failed in-box read is reported as unavailable, not a false all-clear.
  run grep -c 'elif ! _audit_readable' "$ROOT/bin/sluice"
  [ "$output" -ge 1 ]
}

@test "doctor --json: an unreadable egress audit emits blocked:null, not [] (structural)" {
  run grep -c 'blocked_json=null' "$ROOT/bin/sluice"
  [ "$output" -ge 1 ]
}

# Rootless podman can't enforce pids/memory caps or bind ports <1024 (host/kernel limits); doctor
# surfaces the caveats. Drive the real launcher with a fake `podman` on PATH reporting Rootless=true
# (SLUICE_ENGINE forces it over the host's docker).
_fake_rootless_podman_bin() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/podman" <<'P'
#!/bin/sh
case "$*" in
  "info --format {{.Host.Security.Rootless}}") echo true ;;
  info) exit 0 ;;
  --version) echo "podman version 4.9.3" ;;
  *) exit 1 ;;
esac
P
  chmod +x "$WORK/bin/podman"
}

@test "doctor: rootless podman surfaces the pids/memory + ports<1024 caveats" {
  _fake_rootless_podman_bin
  printf 'SLUICE_RUN_CMD="bash"\nSLUICE_MEMORY="512m"\nSLUICE_PORTS="80 8080"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && PATH=\"$WORK/bin:\$PATH\" SLUICE_ENGINE=podman '$SLUICE' doctor"
  assert_success
  assert_output --partial "cgroups-v2"
  assert_output --partial "port 80 (<1024)"
  assert_output --partial "may silently not apply"
  refute_output --partial "port 8080"          # 8080 is >=1024, not flagged
}

@test "doctor: docker engine emits no rootless-podman caveats" {
  printf 'SLUICE_RUN_CMD="bash"\nSLUICE_PORTS="80"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "cgroups-v2"
}

@test "doctor --json: rootless_podman is true under rootless podman, false under docker" {
  _fake_rootless_podman_bin
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && PATH=\"$WORK/bin:\$PATH\" SLUICE_ENGINE=podman '$SLUICE' doctor --json"
  assert_success
  jq -e '.rootless_podman==true' <<<"$output"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json"
  assert_success
  jq -e '.rootless_podman==false' <<<"$output"
}


# --- coverage gaps surfaced by the test-case review (changed-behavior edge/bad paths) ---
@test "doctor: a masked directory whose contents are git-tracked is flagged" {
  printf 'SLUICE_MASK="secrets"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/secrets"
  echo "KEY=1" > "$WORK/secrets/api.key"
  ( cd "$WORK" && git init -q && git add secrets/api.key \
      && git -c user.email=t@t -c user.name=t commit -qm x )
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "git-tracked"
  assert_output --partial "secrets"
}
