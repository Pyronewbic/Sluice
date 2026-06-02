# AUDIT demo: sluice lock as a supply-chain gate, REAL commands, kept tight. In sync -> a dependency
# is added and the box rebuilt OFF-CAMERA (a real `sluice build` inside a Hide block, so the gif has
# no dead build time) -> `lock --check` catches the drift (classified, exit 1) -> re-lock records the
# supply-chain delta -> the CycloneDX SBOM carries the new package with its purl + SHA-1 integrity
# hash -> `lock --scan --fail-on high` runs that SBOM through a host grype and gates on the
# lodash@4.17.4 CVEs (a deliberately old pin in the config; the Wolfi base + apk deps stay clean).
# apk `tree` is used so the SBOM component shows a hash (apk carries integrity). Commands are pasted
# (TypingSpeed 0) with a read-hold, not typed.
#
# Reproduce (from the repo root; needs grype on PATH for the final beat):
#   d=/tmp/sluice-lock-demo; rm -rf "$d"; mkdir -p "$d"
#   cp assets/demos/lock-demo.config.sh "$d/sluice.config.sh"
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice build && sluice lock )   # in-sync baseline
#   printf 'export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false BUILDKIT_PROGRESS=quiet GRYPE_CHECK_FOR_APP_UPDATE=false; export PS1="$ "; cd %s\n' "$d" > /tmp/lock-setup.sh
#   vhs assets/demos/lock-demo.tape                                             # writes /tmp/lock-demo.gif
#   cp /tmp/lock-demo.gif assets/lock-demo.gif

Output "/tmp/lock-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 640
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source /tmp/lock-setup.sh; clear"
Enter
Sleep 1200ms
Show

# 1. baseline: the committed lock matches the built image.
Sleep 600ms
Type "sluice lock --check"
Sleep 700ms
Enter
Sleep 2600ms

# 2. add a dependency and rebuild - real, but off-camera (Hide), so there's no build scene to sit through.
Hide
Type `perl -0pi -e 's/"ripgrep"/"ripgrep tree"/' sluice.config.sh`
Enter
Sleep 300ms
Type "sluice build"
Enter
Sleep 28000ms
Type "clear"
Enter
Sleep 200ms
Show

# 3. the gate catches the drift (classified, exit 1).
Type "sluice lock --check"
Sleep 700ms
Enter
Sleep 3200ms

# 4. re-lock records it and reports the supply-chain delta.
Type "sluice lock"
Sleep 700ms
Enter
Sleep 3200ms

# 5. the SBOM carries the dep: CycloneDX 1.6 purl + SHA-1 integrity hash.
Type `sluice lock --sbom | jq '{specVersion, components:(.components|length), added:[.components[]|select(.name=="tree")]}'`
Sleep 800ms
Enter
Sleep 3800ms

# 6. scan that SBOM through a host grype; --fail-on high gates the build on the lodash CVEs (non-zero exit).
Type "clear"
Enter
Sleep 250ms
Type `sluice lock --scan --fail-on high || echo "gated: exit $?"`
Sleep 900ms
Enter
Sleep 8000ms
