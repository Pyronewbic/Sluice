#!/bin/bash
# Build the shallow-path fleet the operator-demo.tape records, and quiet the other demo boxes so
# `sluice ls --running` shows only this fleet (the real stopped boxes stay untouched + auto-excluded).
# Run from anywhere: it locates the repo via its own path. Then: vhs assets/demos/operator-demo.tape.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"      # assets/demos/ -> repo root
SLUICE="$ROOT/bin/sluice"
export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 SLUICE_YES=1 DOCKER_CLI_HINTS=false
export ANTHROPIC_API_KEY=sk-demo

# Stop OTHER running sluice demo boxes so the fleet table is clean. Only stops (never removes), and
# only the named demo boxes - your real boxes are never touched.
for b in sluice-doctor sluice-fw sluice-learn sluice-overlay sluice-agent; do
  docker stop "$b" >/dev/null 2>&1 && echo "stopped $b" || true
done

# A 3-box fleet at SHALLOW ~/sf paths (a node blog, a python api, a claude agent) so the wide ls
# table reads on camera.
rm -rf "$HOME/sf"; mkdir -p "$HOME/sf/blog" "$HOME/sf/api" "$HOME/sf/bot/.claude"

cat > "$HOME/sf/blog/sluice.config.sh" <<'CFG'
# personal blog (detected: node)
SLUICE_NAME="blog"
SLUICE_DESC="personal blog"
SLUICE_ALLOW_DOMAINS="registry.npmjs.org"
SLUICE_PORTS="4321"
SLUICE_RUN_CMD='curl -s -m6 -o /dev/null https://registry.npmjs.org; true'
CFG

cat > "$HOME/sf/api/sluice.config.sh" <<'CFG'
# internal API (detected: python)
SLUICE_NAME="api"
SLUICE_DESC="internal API"
SLUICE_ALLOW_DOMAINS="pypi.org files.pythonhosted.org"
SLUICE_PORTS="8000"
SLUICE_RUN_CMD='curl -s -m6 -o /dev/null https://pypi.org; curl -s -m6 -o /dev/null https://api.openai.com; true'
CFG

cat > "$HOME/sf/bot/sluice.config.sh" <<'CFG'
# Claude Code (Anthropic) (detected: node)
SLUICE_NAME="bot"
SLUICE_DESC="Claude Code (Anthropic)"
SLUICE_ALLOW_DOMAINS="api.anthropic.com"
SLUICE_MASK=".env*"
SLUICE_ENV="ANTHROPIC_API_KEY"
SLUICE_RUN_CMD='curl -s -m6 -o /dev/null https://api.anthropic.com; curl -s -m6 -o /dev/null https://api.openai.com; true'
CFG

# bot: an out-of-scope symlink so its `doctor` shows the broken-symlink warning (the .env is masked,
# so it correctly does NOT warn as an unmasked secret).
echo 'OPENAI_API_KEY=sk-live-do-not-commit' > "$HOME/sf/bot/.env"
ln -sfn /etc/hosts "$HOME/sf/bot/.claude/CLAUDE.md"

for d in blog api bot; do ( cd "$HOME/sf/$d" && "$SLUICE" >/dev/null 2>&1 ); done
( cd "$HOME/sf/api" && "$SLUICE" lock >/dev/null 2>&1 )   # one locked box -> LOCK-column variety in the fleet table
"$SLUICE" ls --running
