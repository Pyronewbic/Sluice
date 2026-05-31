// Minimal Deno server. Imports a dep from jsr.io to exercise egress through the proxy.
import { delay } from "jsr:@std/async@1/delay";
await delay(1);
Deno.serve({ port: 8000, hostname: "0.0.0.0" }, () => new Response("ok from deno\n"));
