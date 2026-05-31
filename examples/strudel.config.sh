# Strudel - the live-coding music REPL, served from a sluice.
#
# Usage: copy this file into an (empty) project dir as sluice.config.sh, then run `sluice`.
#   mkdir strudel && cp examples/strudel.config.sh strudel/sluice.config.sh
#   cd strudel && sluice
# Then open http://localhost:4321 in your HOST browser. Click the editor, press
# Ctrl+Enter to play. Audio + UI happen host-side; the sluice stays headless + firewalled.
#
# What this demonstrates: a single config file turns an empty dir into a sandboxed,
# firewalled web app - exercising SLUICE_SETUP_CMDS (build-time), SLUICE_PORTS (published +
# firewall-opened), SLUICE_RUN_CMD (the server), and SLUICE_ALLOW_DOMAINS (runtime egress).
# No credentials, no SLUICE_PRELAUNCH.

# --- build-time: bake the REPL bundle + the page + a tiny static server ----------
# Runs as the sluice user before the firewall (free egress), so the curl below works.
# The @strudel/repl bundle (a self-contained 2.2 MB IIFE that registers the
# <strudel-editor> web component) is downloaded ONCE here and served locally - so at
# RUNTIME the only egress the app needs is the sample host (see SLUICE_ALLOW_DOMAINS).
SLUICE_SETUP_CMDS='
mkdir -p /home/sluice/strudel-app
curl -fsSL https://unpkg.com/@strudel/repl@1.3.0 -o /home/sluice/strudel-app/strudel-repl.js
cat > /home/sluice/strudel-app/index.html <<"HTML"
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Strudel in a sluice</title>
  <script src="strudel-repl.js"></script>
  <style>
    html, body { margin: 0; height: 100%; background: #0f0f12; color: #e8e8ea; font-family: system-ui, sans-serif; }
    header { padding: 10px 14px; font-size: 13px; opacity: 0.75; }
    strudel-editor { display: block; height: calc(100vh - 42px); }
  </style>
</head>
<body>
  <header>Strudel, served from a sluice - click the editor and press Ctrl+Enter to play. Stop with Ctrl+. </header>
  <strudel-editor>
    <!--
samples("github:tidalcycles/dirt-samples")
stack(
  s("bd*2, ~ sd, hh*4"),
  note("c2 <eb2 g2>").s("sawtooth").lpf(700).gain(0.7)
).slow(2)
    -->
  </strudel-editor>
</body>
</html>
HTML
cat > /home/sluice/strudel-app/server.mjs <<"JS"
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
const ROOT = "/home/sluice/strudel-app";
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css", ".json": "application/json", ".wav": "audio/wav", ".mp3": "audio/mpeg", ".ogg": "audio/ogg" };
const PORT = 4321;
createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
  if (path === "/") path = "/index.html";
  const file = join(ROOT, normalize(path).replace(/^([.][.][/])+/, ""));
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream" });
    res.end(body);
  } catch (e) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  }
}).listen(PORT, "0.0.0.0", () => console.log("[strudel] serving " + ROOT + " on http://0.0.0.0:" + PORT));
JS
'

# --- runtime egress: THE Strudel-specific gotcha --------------------------------
# Strudel fetches drum/instrument SAMPLES at play time. Without these on the egress
# allowlist, the default-DROP firewall silently blocks sample loading and you get
# silence. dirt-samples (bd/sd/hh/cp above) and Strudel's default sound maps live on
# raw.githubusercontent.com; some sounds pull from jsdelivr. Add the host of any other
# sample pack / soundfont you use (e.g. github.io for GM soundfonts).
SLUICE_ALLOW_DOMAINS="raw.githubusercontent.com cdn.jsdelivr.net"

# --- serve ----------------------------------------------------------------------
# Publish 4321 to the host (the firewall opens the matching inbound rule). The server
# binds 0.0.0.0 (NOT 127.0.0.1) so the docker-forwarded traffic actually reaches it.
SLUICE_PORTS="4321"
SLUICE_RUN_CMD="node /home/sluice/strudel-app/server.mjs"
