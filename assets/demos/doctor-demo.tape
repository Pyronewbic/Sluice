# DOCTOR demo: the one-screen posture panel. Off-camera the box is locked and a real run hits a
# blocked host, then `sluice doctor` shows the whole health view - engine, the mounted project dir
# (the box's only host path), the in-box hazard warnings (an unmasked secret-looking .env, a
# symlink that resolves outside the mount), image freshness, the supply-chain lock (in sync),
# published ports, auth env, and the LAST run's blocked egress with a learn hint. All real,
# colorized to the sluice convention (green ok, red blocked, yellow warn, dim neutral).
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/doctor; rm -rf "$d"; mkdir -p "$d/.claude" .demos/render
#   cp assets/demos/doctor-demo.config.sh "$d/sluice.config.sh"
#   echo 'OPENAI_API_KEY=sk-live-do-not-commit' > "$d/.env"          # seeds the unmasked-secret warning
#   ln -s /opt/claude/shared/CLAUDE.md "$d/.claude/CLAUDE.md"        # seeds the out-of-scope symlink warning
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 OPENAI_API_KEY=sk-demo sluice run true )  # build + warm
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false OPENAI_API_KEY=sk-demo; export PS1="$ "; cd .demos/doctor\n' > .demos/doctor-setup.sh
#   vhs assets/demos/doctor-demo.tape                                # writes .demos/render/doctor-demo.gif
#   cp .demos/render/doctor-demo.gif assets/doctor-demo.gif

Output ".demos/render/doctor-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 580
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/doctor-setup.sh; clear"
Enter
Sleep 1000ms
# off-camera: lock the box so the panel shows a green supply-chain 'in sync' line
Type "sluice lock"
Enter
Sleep 6000ms
# off-camera: a real run so the egress line is populated (openai isn't allowlisted -> blocked)
Type "sluice run sh -c 'curl -s -m6 -o /dev/null https://api.openai.com; true'"
Enter
Sleep 3500ms
Type "clear"
Enter
Sleep 300ms
Show

Sleep 600ms
Type "sluice doctor"
Sleep 700ms
Enter
Sleep 9000ms
Sleep 1500ms
