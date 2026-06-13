# FIREWALL demo: the egress firewall is proven, not claimed - then the receipt proves itself.
# A run (firewall.config.sh) reaches an ALLOWLISTED host (api.github.com, green OK), and the
# firewall BLOCKS an exfil POST (example.com) and a raw-IP no-SNI bypass (1.1.1.1) - real curl
# failures, not a config claim. `sluice egress` is the box's own ledger: only the allowlisted
# host got through. `sluice egress --verify` walks the append-only hash chain (green, intact).
# Then a single deleted line in the host-side audit log flips verify to RED, non-zero exit:
# "prev-link broken - reordered or dropped". The log proves itself tamper-evident.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/fw; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp examples/firewall.config.sh "$d/sluice.config.sh"
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport PS1="$ "\ncd .demos/fw\n' > .demos/fw-setup.sh
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice build )   # build off-camera
#   vhs assets/demos/firewall-demo.tape                                                       # writes .demos/render/firewall-demo.gif
#   cp .demos/render/firewall-demo.gif assets/firewall-demo.gif
# The Hide block below runs the build + one seeding run, then clears - all off camera.

Output ".demos/render/firewall-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 640
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/fw-setup.sh"
Enter
Sleep 1000ms
# start the audit log fresh so verify reports a clean "2 record(s)" on camera (off-camera only).
Type 'rm -f $HOME/.local/state/sluice/fw/egress-log.jsonl'
Enter
Sleep 1000ms
Type "SLUICE_YES=1 sluice build >/dev/null 2>&1"
Enter
Sleep 8000ms
# one off-camera run so the host-side egress audit log gets its FIRST record (verify needs >=2).
Type "SLUICE_YES=1 sluice >/dev/null 2>&1"
Enter
Sleep 6000ms
Type "clear"
Enter
Sleep 1000ms
Show

# beat 1: run firewall.config.sh to completion. api.github.com OK (green), example.com BLOCKED
# (the exfil POST), 1.1.1.1 BLOCKED (raw IP, no SNI). This is the SECOND egress-log record.
Sleep 500ms
Type "sluice"
Sleep 600ms
Enter
Sleep 8000ms

# beat 2: the box's own per-host ledger - only the allowlisted host got through; the blocks
# above stayed in the box (example.* / raw-IP are exfil canaries, not proposable hosts).
Type "sluice egress"
Sleep 600ms
Enter
Sleep 4000ms

# beat 3: walk the append-only hash chain - green, intact. Hold so the green verify reads.
Type "sluice egress --verify"
Sleep 600ms
Enter
Sleep 3500ms

# OFF CAMERA: tamper. Delete a WHOLE LINE of the host-side audit log (drops a record) so the
# chain's prev-link breaks - not a single-field edit (that would trip "self-hash mismatch").
# clear so beat 4 re-verifies the SAME command on a fresh screen: the green->red flip is the payoff.
Hide
Type `sed -i '' '1d' $HOME/.local/state/sluice/fw/egress-log.jsonl`
Enter
Sleep 500ms
Type "clear"
Enter
Sleep 500ms
Show

# beat 4: re-verify the SAME log. RED, non-zero exit: the dropped record breaks the chain.
Type "sluice egress --verify"
Sleep 600ms
Enter
Sleep 4000ms
