# Plandex - open-source terminal agent for large, multi-step coding tasks - run YOLO inside a sluice.
#
#   sluice agent plandex
#
# YOLO is fine here: the sluice contains it (non-root, this dir only, egress locked). It can
# still rewrite this dir and use any forwarded creds, so commit your work first.
# Auth: first run signs in to Plandex Cloud (email pin, in-terminal) - the token persists in the
# state dir. For BYO keys export OPENROUTER_API_KEY (or OPENAI_API_KEY / ANTHROPIC_API_KEY) on the HOST.
# plandex is a Go binary (NOT an npm package); fetch the release tarball onto PATH at build (free egress).
SLUICE_SETUP_CMDS='case "$(uname -m)" in aarch64|arm64) a=arm64 ;; *) a=amd64 ;; esac; v="$(curl -fsSL https://plandex.ai/v2/cli-version.txt)"; mkdir -p "$HOME/.npm-global/bin"; curl -fsSL "https://github.com/plandex-ai/plandex/releases/download/cli%2Fv${v}/plandex_${v}_linux_${a}.tar.gz" | tar -xz -C "$HOME/.npm-global/bin" plandex; ln -sf "$HOME/.npm-global/bin/plandex" "$HOME/.npm-global/bin/pdx"'
# api-v2.plandex.ai is the Plandex Cloud backend; it proxies the model calls, so BYO provider keys are
# relayed to it and no direct provider host is needed (self-hosting: point PLANDEX_API_HOST at your server
# and add its host, or run `sluice learn`). The CLI's version ping to plandex.ai is suppressed in the run
# cmd below, so that host stays blocked (mirrors crush/qwen leaving their update/release host off-allowlist).
SLUICE_ALLOW_DOMAINS="api-v2.plandex.ai"
SLUICE_DESC="Plandex (large-task agent)"
# In-repo secrets: .env* files are shadowed (unreadable in the box); SLUICE_MASK="" to disable.
SLUICE_MASK=".env*"
SLUICE_ENV="OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY"
# Persist Plandex's home dir (auth.json / accounts.json / cache) across runs. NOT .npm-global - that's
# where the baked binary lives, and a mount would shadow it. The per-project .plandex-v2 dir is in the mount.
SLUICE_STATE_DIRS=".plandex-home-v2"
# --full = Full Auto (auto context, apply, execution and debugging); the sluice is the sandbox. Drop it
# (or pick --semi / --basic) for interactive approvals. PLANDEX_SKIP_UPGRADE=1 skips the plandex.ai version ping.
SLUICE_RUN_CMD='PLANDEX_SKIP_UPGRADE=1 plandex --full'
