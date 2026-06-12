#!/usr/bin/env bash
# sluice - run any project in a sandboxed, egress-firewalled container.
# Drop a sluice.config.sh in a project (or run `sluice` to scaffold one); `sluice help` lists the
# commands. Per-project image/container, auto-rebuilt when the config or core changes.
#
# GENERATED FILE - do not edit directly. Assembled from src/*.sh by `make build`
# (the slices concatenate in order; a CI gate fails if this file drifts from src/).
set -euo pipefail

# resolve our install dir (bin/sluice is symlinked onto PATH; follow the chain)
SELF="$0"
while [ -h "$SELF" ]; do
  link="$(readlink "$SELF")"
  case "$link" in /*) SELF="$link";; *) SELF="$(dirname "$SELF")/$link";; esac
done
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
CORE="$ROOT/core"

die() { echo "${E_RED:-}[sluice]${E_RST:-} $*" >&2; exit 1; }

# minimal JSON emit (host jq is not assumed; fields here are short/flat)
# Escape a string for a JSON value: backslash + doublequote, flatten tab/newline, then DELETE every
# remaining C0 control byte + DEL (ESC/BEL/OSC) so a box-controlled value (e.g. a logged SNI) can't
# smuggle a terminal-escape sequence through `--json`/persisted receipts when they're later cat'd.
_json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/}"; printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177'; }
# Sanitize a box-controlled string for safe display on a TERMINAL: flatten whitespace and DELETE every
# C0 control byte + DEL (ESC/BEL/OSC). Unlike _json_esc it leaves \ and " intact (this is for humans, not
# JSON), so a crafted filename / symlink target can't inject escapes or forge a line of `doctor` output.
_term_esc() { local s="$1"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177'; }
# Emit a JSON array of strings from newline-separated stdin (blank lines skipped; a final line
# without a trailing newline still counts - base_domains emits one).
_json_arr() { local first=1 line; printf '['; while IFS= read -r line || [ -n "$line" ]; do [ -n "$line" ] || continue; [ "$first" = 1 ] && first=0 || printf ','; printf '"%s"' "$(_json_esc "$line")"; done; printf ']'; }

# Home-relative display form of a path (~/...), for HUMAN output only - ls already renders paths
# this way; doctor/learn share it via this helper. JSON output keeps raw absolute paths.
_tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}";; "$HOME") printf '~';; *) printf '%s' "$1";; esac; }

# color: gated on a stdout TTY + NO_COLOR, so piped/redirected output stays plain ASCII
# (the --json paths print no color regardless; the TTY gate also blanks these when piped.)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_GRN=''; C_RED=''; C_YEL=''; C_DIM=''; C_BLD=''; C_RST=''
fi
# Parallel stderr-gated set: lines printed to >&2 use E_* (not C_*) so color tracks fd 2's TTY - no
# escape leak into a redirected stderr, and color still shows when only stderr is a terminal.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  E_GRN=$'\033[32m'; E_RED=$'\033[31m'; E_YEL=$'\033[33m'; E_DIM=$'\033[2m'; E_RST=$'\033[0m'
else
  E_GRN=''; E_RED=''; E_YEL=''; E_DIM=''; E_RST=''
fi

# version + help
SLUICE_VERSION="0.9.0"   # fallback when not a git checkout
