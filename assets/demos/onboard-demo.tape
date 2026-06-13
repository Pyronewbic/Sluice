# ONBOARD demo (README Use + examples 'Your own stack'): zero-config first touch, REAL commands.
# A config-less node project: bare `sluice` detects the stack, SCAFFOLDS sluice.config.sh, previews
# the knobs it chose, asks [Y/n], then builds + runs it sandboxed - closing on the egress receipt
# (registry.npmjs.org reached green, from the run's `npm install`) and the first-run nudge to
# `sluice learn` / `sluice lock`. node's npm registry is in the BASE allowlist, so the scaffolded
# SLUICE_ALLOW_DOMAINS is intentionally empty (its comment points at `sluice learn`); the receipt is
# what proves egress actually works.
#
# Recorded OUTSIDE the repo (~/sluice-onboard/web, a non-git dir, like the operator demo's ~/sf) for
# two reasons: the config walk-up (find_config climbs to /, not .git-bounded) must SCAFFOLD rather
# than find the repo's own config, and an in-repo dir prints a git-common-dir mount notice. The build
# is pre-warmed off-camera so there's no dead build time; the on-camera bare `sluice` re-scaffolds the
# IDENTICAL config (config_hash is content-based), so the image is a cache hit (no rebuild). The box
# is removed before recording so the on-camera `npm install` is a real fetch (-> registry, green).
#
# Reproduce (from the repo root; .demos/ is gitignored render scratch):
#   R="$PWD"; P=~/sluice-onboard/web; rm -rf ~/sluice-onboard; mkdir -p "$P" .demos/render
#   printf "console.log('web ready on http://localhost:3000');\n" > "$P/app.js"
#   printf 'fund=false\naudit=false\nupdate-notifier=false\n' > "$P/.npmrc"   # quiet npm's notices on camera
#   cat > "$P/package.json" <<'PKG'
#   { "name": "web", "version": "0.1.0", "private": true,
#     "dependencies": { "chalk": "^5.3.0" }, "scripts": { "dev": "node app.js" } }
#   PKG
#   ( cd "$P" && PATH="$R/bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice >/dev/null 2>&1 )  # scaffold+build off-camera
#   ( cd "$P" && rm -f sluice.config.sh )       # reset to config-less for the on-camera scaffold (image stays cached)
#   docker rm -f sluice-web >/dev/null 2>&1     # fresh box -> the on-camera npm install really fetches
#   printf 'export PATH="$PWD/bin:$PATH"; export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false; export PS1="$ "; cd ~/sluice-onboard/web\n' > .demos/onboard-setup.sh
#   vhs assets/demos/onboard-demo.tape          # writes .demos/render/onboard-demo.gif
#   cp .demos/render/onboard-demo.gif assets/onboard-demo.gif

Output ".demos/render/onboard-demo.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/onboard-setup.sh; clear"
Enter
Sleep 1000ms
Show

# 1. a bare project: a package.json (+ app.js), and NO sluice.config.sh.
Sleep 600ms
Type "ls"
Sleep 700ms
Enter
Sleep 2000ms

# 2. one command: sluice detects node, SCAFFOLDS the config, previews the knobs it chose, asks [Y/n].
Type "sluice"
Sleep 700ms
Enter
Sleep 3800ms

# 3. accept (default Y): the image is a cache hit, then it runs - `npm install` reaches
#    registry.npmjs.org (green), the receipt prints, and the first-run nudge points at learn / lock.
Enter
Sleep 8500ms
Sleep 1500ms
