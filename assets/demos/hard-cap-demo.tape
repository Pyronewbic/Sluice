# HARD-CAP demo: exfil killed mid-flight (SLUICE_EGRESS_HARD_CAP_BYTES). The box is ALLOWED to reach
# httpbin.org (default-drop + allowlist can't stop laundering OUT through a host you permit - the
# README's honest caveat). SLUICE_EGRESS_HARD_CAP_BYTES=1258291 (1.2 MiB, just above the 1 MiB floor)
# is a PREVENTIVE in-box xt_quota DROP on ALL proxied egress: a warm GET proves the host is reachable,
# then a 4 MiB upload to that same allowed host dies mid-flight - curl aborts non-zero, truncated - and
# the receipt shows httpbin.org reached with bytes pinned near the cap (BOUNDED, not zero).
# Honest limits (why the cap is >= 1 MiB): it counts WIRE bytes (TLS handshakes + headers + download
# ACKs debit it), the window is PER-BOOT (a long-lived box accumulates across runs), and hitting it
# kills ALL proxied egress. It needs xt_quota - if the kernel lacks it the box FAILS CLOSED (refuses to
# boot). `sluice doctor` surfaces it as `harden   hard-cap=1258291`.
#
# Render host: docker-desktop (or any Linux host). The payoff REQUIRES xt_quota; Docker Desktop's
# LinuxKit kernel HAS it (verified), so this renders locally - if a host's kernel lacks it the box FAILS
# CLOSED (renders the red line instead). No SLUICE_RUNTIME=kata; the box runs under plain docker.
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/hard-cap; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/hard-cap-demo.config.sh "$d/sluice.config.sh"
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport PS1="$ "\ncd .demos/hard-cap\n' > .demos/hard-cap-setup.sh
#   ( cd "$d" && git init -q )                                                                 # own .git => no git-common-dir warning
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice build )     # build off-camera
#   vhs assets/demos/hard-cap-demo.tape                                                         # writes .demos/render/hard-cap-demo.gif
#   gifsicle -O3 --colors 128 .demos/render/hard-cap-demo.gif -o assets/hard-cap-demo.gif       # optimize into assets
# The Hide block below sources the setup + a cache-hit build, then clears - all off camera.

Output ".demos/render/hard-cap-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/hard-cap-setup.sh"
Enter
Sleep 1000ms
Type "SLUICE_YES=1 sluice build >/dev/null 2>&1"
Enter
Sleep 8000ms
# remove the container so beat 2's `sluice` boots FRESH - the per-boot xt_quota must be full, or a
# reused box (quota already spent) would block the launder at 0 bytes instead of mid-flight.
Type "SLUICE_YES=1 sluice stop >/dev/null 2>&1"
Enter
Sleep 2000ms
Type "clear"
Enter
Sleep 1000ms
Show

# beat 1: the fixture - ONE allowed host, and a preventive cap set just above the 1 MiB floor.
Sleep 500ms
Type "cat sluice.config.sh"
Sleep 600ms
Enter
Sleep 3500ms

# clear between beats (off camera) so each starts fresh - no scroll accumulation (bloats the gif).
Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 2: run it. warm GET proves httpbin.org is reachable; the 4 MiB launder-out dies mid-upload -
# curl exits non-zero with a truncated body. The at-exit receipt bounds httpbin.org's bytes.
Type "sluice"
Sleep 600ms
Enter
Sleep 10500ms

Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 3: the box's own ledger - httpbin.org reached, bytes BOUNDED (a fraction of the 4 MiB tried),
# 0 blocked. The exfil was bounded by volume, not reduced to zero: the honest guarantee the cap makes.
Type "sluice egress"
Sleep 600ms
Enter
Sleep 5000ms
