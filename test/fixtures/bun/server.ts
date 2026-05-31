import { nanoid } from "nanoid";
const id = nanoid(6);
Bun.serve({ port: 3000, hostname: "0.0.0.0", fetch: () => new Response("ok from bun " + id + "\n") });
