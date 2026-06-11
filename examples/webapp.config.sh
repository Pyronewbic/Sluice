# Serve the web app you have - then let `sluice learn` discover its one real upstream.
#
# Usage: copy this file into an (empty) project dir as sluice.config.sh, then run `sluice`.
#   mkdir wa && cp examples/webapp.config.sh wa/sluice.config.sh
#   cd wa && sluice
# A tiny Node service comes up on http://localhost:3000. Then, from your HOST shell:
#   curl localhost:3000          # "ok from node"  - the app serves, no egress needed
#   curl localhost:3000/rate     # 502 "blocked"   - its one API call is default-DROP
#   sluice egress                # shows api.frankfurter.dev was blocked
#   sluice learn --apply         # allow that one host - hot-reloads, NO rebuild
#   curl localhost:3000/rate     # live FX JSON - the call now reaches through
# This is the everyday loop: run the app under enforcement, see exactly what it needs,
# allow only that. The allowlist starts EMPTY so the first /rate call blocks; `learn`
# writes SLUICE_ALLOW_DOMAINS="api.frankfurter.dev" below and reloads the running box.

# --- the app (baked at build, in $HOME so the runtime project mount won't shadow it) ----
# Node is in the base image; v24's global fetch means server.js needs no dependencies.
SLUICE_SETUP_CMDS='
cat > "$HOME/server.js" <<EOF
const http = require("http");
const PORT = 3000;
http.createServer((req, res) => {
  if (req.url === "/rate") {
    fetch("https://api.frankfurter.dev/v1/latest")
      .then(r => r.text().then(body => {
        res.writeHead(r.status, { "content-type": "application/json" });
        res.end(body);
      }))
      .catch(err => {
        res.writeHead(502, { "content-type": "text/plain" });
        res.end("blocked: " + err.message + "\n");
      });
    return;
  }
  res.writeHead(200, { "content-type": "text/plain" });
  res.end("ok from node\n");
}).listen(PORT, "0.0.0.0", () => console.log("listening on " + PORT));
EOF
'

# --- serve ----------------------------------------------------------------------
# Publish 3000 (the firewall opens the matching inbound rule); the app binds 0.0.0.0
# so the forwarded traffic reaches it.
SLUICE_PORTS="3000"
SLUICE_RUN_CMD='node "$HOME/server.js"'

# --- egress ---------------------------------------------------------------------
# Empty on purpose: the first call to /rate is BLOCKED, then `sluice learn --apply`
# fills this line in. Note the CANONICAL host api.frankfurter.dev - the shorter .app
# alias 301-redirects elsewhere, which the transparent SNI redirect can't follow.
SLUICE_ALLOW_DOMAINS=""
