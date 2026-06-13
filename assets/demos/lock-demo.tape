# supply-chain gate: sluice lock as a CI gate, REAL commands, kept tight. In sync -> a dependency
# is added and the box rebuilt OFF-CAMERA (a real `sluice build` inside a Hide block, so the gif has
# no dead build time) -> `lock --check` catches the drift (classified, exit 1) -> the CycloneDX SBOM
# carries the new package with its purl + SHA-1 integrity hash -> `lock --scan --fail-on high` runs
# the SBOM through a host grype and gates on the lodash@4.17.4 CVEs (a separate deliberately old npm
# pin in the config; the Wolfi base + apk deps stay clean). apk `tree` is the package added on camera
# so the SBOM component shows a hash (apk carries integrity); lodash is the distinct package the scan
# gates on. Commands are pasted (TypingSpeed 0) with a read-hold, not typed.
#
# Reproduce (from the repo root; needs grype on PATH for the final beat; .demos/ is gitignored scratch):
#   d=.demos/lock; rm -rf "$d"; mkdir -p "$d" .demos/render
#   cp assets/demos/lock-demo.config.sh "$d/sluice.config.sh"
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 DOCKER_CLI_HINTS=false BUILDKIT_PROGRESS=quiet GRYPE_CHECK_FOR_APP_UPDATE=false; export PS1="$ "; cd .demos/lock\n' > .demos/lock-setup.sh
#   ( cd "$d" && SLUICE_NO_BANNER=1 SLUICE_YES=1 PATH="$PWD/../../bin:$PATH" sluice build && sluice lock )   # in-sync baseline
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" sluice lock --scan >/dev/null 2>&1 )                            # pre-warm grype DB off-camera
#   vhs assets/demos/lock-demo.tape                                                                         # writes .demos/render/lock-demo.gif
#   cp .demos/render/lock-demo.gif assets/lock-demo.gif

Output ".demos/render/lock-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 640
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/lock-setup.sh; clear"
Enter
Sleep 1200ms
Show

# 1. baseline: the committed lock matches the built image.
Sleep 600ms
Type "sluice lock --check"
Sleep 700ms
Enter
Sleep 2600ms

# add a dependency and rebuild - real, but off-camera (Hide), so there's no build scene to sit through.
Hide
Type `perl -0pi -e 's/"ripgrep"/"ripgrep tree"/' sluice.config.sh`
Enter
Sleep 300ms
Type "sluice build >build.log 2>&1"
Enter
Sleep 28000ms
Type "clear"
Enter
Sleep 600ms
Show

# 2. the gate catches the drift (classified, exit 1).
Type "sluice lock --check"
Sleep 700ms
Enter
Sleep 3200ms

# 3. the SBOM carries the dep: CycloneDX purl + SHA-1 integrity hash (apk tree).
Type `sluice lock --sbom | jq '{specVersion, components:(.components|length), added:[.components[]|select(.name=="tree")]}'`
Sleep 800ms
Enter
Sleep 4000ms

# 4. scan the SBOM through a host grype; --fail-on high gates on the separate lodash CVE (non-zero exit).
Type "clear"
Enter
Sleep 250ms
Type `sluice lock --scan --fail-on high || echo "gated: exit $?"`
Sleep 900ms
Enter
Sleep 7000ms
