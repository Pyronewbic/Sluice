# FLEET-AUDIT demo: audit every box's egress hash-chain in ONE pass with the engine DOWN. `sluice egress
# --verify --all` walks EVERY box's append-only chain as pure host-side file reads - no container engine,
# no per-box config - so it runs daemon-down and covers ORPHANED boxes (a chain outlives its box). Green
# "all 3 box(es) intact"; --json carries schema sluice.fleet-verify/v1 (per-box results via jq); --export
# --all concatenates every box's JSONL slug-sorted, each record self-tagged with .box. Then one dropped
# log line flips ONE box to TAMPERED, non-zero exit - never a silent pass. The fleet is 3 SEEDED chains under an ISOLATED XDG_STATE_HOME (see
# fleet-audit-seed.sh): byte-valid records in sluice's exact _persist_receipt shape, hashed with sluice's
# own _sha256, so --verify recomputes and chains every line for real (a wrong byte prints TAMPERED). No
# engine is ever contacted - DOCKER_HOST points nowhere on the recording shell - which is the whole point.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   mkdir -p .demos/render
#   bash assets/demos/fleet-audit-seed.sh        # seed 3 byte-valid egress chains under .demos/fleet-audit/state (no engine)
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport XDG_STATE_HOME="$PWD/.demos/fleet-audit/state"\nexport DOCKER_HOST="unix:///nonexistent/sluice-no-engine.sock"\nexport PS1="$ "\ncd .demos/fleet-audit\n' > .demos/fleet-audit-setup.sh
#   vhs assets/demos/fleet-audit.tape            # writes .demos/render/fleet-audit.gif
#   gifsicle -O3 --colors 128 .demos/render/fleet-audit.gif -o assets/fleet-audit.gif   # optimize into assets

Output ".demos/render/fleet-audit.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/fleet-audit-setup.sh; clear"
Enter
Sleep 1000ms
Show

# beat 1: audit the WHOLE fleet in one pass - no engine, no config, daemon down. Every box's append-only
# hash chain re-hashed host-side; all intact.
Sleep 600ms
Type "sluice egress --verify --all"
Sleep 600ms
Enter
Sleep 4000ms

# beat 2: the machine-readable contract - schema sluice.fleet-verify/v1, one result per box (jq).
Type "sluice egress --verify --all --json | jq -c '{schema, boxes_broken}, (.boxes[] | {box, records, verified})'"
Sleep 600ms
Enter
Sleep 4500ms

# beat 3: ship the whole fleet's raw audit log - every box's JSONL concatenated slug-sorted, each record
# self-tagged with .box so a SIEM regroups by box regardless of order.
Type "sluice egress --export --all | jq -c '{box, ts, reached: .totals.reached}'"
Sleep 600ms
Enter
Sleep 5000ms

# OFF CAMERA: tamper. Drop a WHOLE line from ONE box's chain (billing-worker) so its prev-link breaks.
# clear so the re-audit runs on a fresh screen - the intact->TAMPERED flip is the payoff.
Hide
Type "sed -i '' '1d' $XDG_STATE_HOME/sluice/billing-worker/egress-log.jsonl"
Enter
Sleep 500ms
Type "clear"
Enter
Sleep 500ms
Show

# beat 4: re-audit the fleet. The one broken chain is caught, non-zero exit - never a silent pass.
Type "sluice egress --verify --all"
Sleep 600ms
Enter
Sleep 4000ms
