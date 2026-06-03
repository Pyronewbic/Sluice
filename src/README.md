# src/ - the sluice launcher, sliced

`bin/sluice` is **generated** by `make build`, which concatenates these files in lexical order
(`cat src/*.sh`). They are ordered fragments of one script, not independently-runnable modules:
the slices share globals and run top-to-bottom, so order matters - `00-prelude` (shebang + `set` +
self-locate) must stay first and `90-dispatch` (the command `case`) last. Don't reorder; insert new
work into the slice it belongs to.

Workflow: edit a slice, run `make build`, commit both the slice and `bin/sluice`. CI's `make
build-check` fails if `bin/sluice` drifts from `src/`. Lint/shellcheck run on the assembled
`bin/sluice` (a single fragment won't shellcheck cleanly on its own - it references functions defined
in other slices).

| slice | holds |
|---|---|
| `00-prelude` | shebang, `set -euo pipefail`, self-locate (`SELF`/`ROOT`/`CORE`), `die`, colors, version constant |
| `05-version-help` | `sluice_version`, update notice, `usage`/`help_for`, `version` |
| `10-egress-helpers` | naming, `config_hash`, squid-log / blocked / reached / egress-row helpers |
| `20-lock-sbom-scan` | `egress`, inventory, `lock` (drift/check/diff/enforce), SBOM, vuln scan |
| `30-doctor-ls` | `doctor` (+ `--json`), `ls` |
| `40-runtime` | `banner`, engine/runner resolution, runtime image sync |
| `45-cli-entry` | top-level arg parse (`-b`/`--box`), info-command dispatch, box-target resolution |
| `50-init` | `init` detection helpers + `cmd_init` (+ `--update`) and its early dispatch |
| `60-main-flow` | `find_config`, `prune`, doctor/ls/prune/agent early dispatch, config sourcing |
| `70-build-run` | `build`/`maybe_build`/`start`/`ensure_up`, exec helpers, workspace overlay |
| `80-learn` | egress receipt, allowlist apply/merge/reload, `learn` (+ `--audit`) |
| `90-dispatch` | the final `case "${1:-run-default}"` command dispatch |
