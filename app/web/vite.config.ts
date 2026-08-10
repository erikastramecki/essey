import { defineConfig, type PluginOption } from "vite";
import react from "@vitejs/plugin-react";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import { fileURLToPath } from "node:url";
import fs from "node:fs";

// PFP mint-reservation API (dev). Re-resolves the uniqueness key SERVER-SIDE from the posted
// selection (via the same resolver) so a client can't spoof it, then check-and-locks it in a
// JSON store. Prod: swap the file store for KV/Redis and mount as a serverless function.
function pfpReserve(): PluginOption {
  const STORE = fileURLToPath(new URL("./.reservations.json", import.meta.url));
  const read = () => { try { return JSON.parse(fs.readFileSync(STORE, "utf8")); } catch { return {}; } };
  const write = (o: any) => fs.writeFileSync(STORE, JSON.stringify(o, null, 2));
  const send = (res: any, code: number, obj: any) => { res.statusCode = code; res.setHeader("content-type", "application/json"); res.end(JSON.stringify(obj)); };
  return {
    name: "essey-pfp-reserve",
    configureServer(server) {
      server.middlewares.use("/api/reserve", async (req: any, res: any) => {
        try {
          if (req.method === "GET") {
            const key = new URL(req.url, "http://x").searchParams.get("key") || "";
            const st = read(); return send(res, 200, { key, reserved: !!st[key], by: st[key]?.wallet ?? null });
          }
          if (req.method === "POST") {
            let body = ""; for await (const c of req) body += c;
            const { gender, forced, seed, wallet } = JSON.parse(body || "{}");
            const data = JSON.parse(fs.readFileSync(fileURLToPath(new URL(`./public/builder/data_${gender}.json`, import.meta.url)), "utf8"));
            const mod: any = await server.ssrLoadModule("/src/pfp-resolve.ts");
            const r = mod.resolveSelection(data, forced || {}, (seed >>> 0) || 0); // authoritative key
            const store = read();
            if (store[r.key]) return send(res, 200, { ok: false, taken: true, key: r.key, by: store[r.key].wallet });
            store[r.key] = { gender, wallet: wallet || "anon", ts: Date.now() }; write(store);
            return send(res, 200, { ok: true, reserved: true, key: r.key });
          }
          send(res, 405, { error: "method" });
        } catch (e) { send(res, 500, { error: String(e) }); }
      });
    },
  };
}

// @essey/sui-sdk is imported as first-party source so Vite transpiles its TS.
export default defineConfig({
  // snarkjs + circomlibjs (the shielded-pool prover) reach for node built-ins (buffer/events/stream/
  // process/assert) at runtime; polyfill them for the browser or in-browser proving throws.
  plugins: [nodePolyfills({ include: ["buffer", "events", "stream", "util", "process", "assert"], globals: { Buffer: true, process: true } }), react(), pfpReserve()],
  resolve: {
    alias: { "@essey/sui-sdk": fileURLToPath(new URL("../sui-sdk/src/index.ts", import.meta.url)) },
    // the aliased SDK source + dapp-kit must share ONE @mysten/sui instance (else two
    // Transaction classes → wallet signing breaks). Force a single copy from web/node_modules.
    dedupe: ["@mysten/sui", "@mysten/dapp-kit", "@mysten/bcs", "@tanstack/react-query", "react", "react-dom"],
  },
  server: { port: 5173 },
});
