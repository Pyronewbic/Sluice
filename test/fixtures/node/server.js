const http = require("http");
const ms = require("ms"); // proves `npm install` pulled a dep through the proxy
http
  .createServer((_, res) => res.end("ok from node (" + ms(1000) + ")\n"))
  .listen(3000, "0.0.0.0");
