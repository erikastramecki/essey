import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import { fileURLToPath } from "node:url";

// @essey/sui-sdk is imported as first-party source so Vite transpiles its TS.
export default defineConfig({
  // snarkjs + circomlibjs (the shielded-pool prover) reach for node built-ins (buffer/events/stream/
  // process/assert) at runtime; polyfill them for the browser or in-browser proving throws.
  plugins: [nodePolyfills({ include: ["buffer", "events", "stream", "util", "process", "assert"], globals: { Buffer: true, process: true } }), react()],
  resolve: {
    alias: { "@essey/sui-sdk": fileURLToPath(new URL("../sui-sdk/src/index.ts", import.meta.url)) },
    // the aliased SDK source + dapp-kit must share ONE @mysten/sui instance (else two
    // Transaction classes → wallet signing breaks). Force a single copy from web/node_modules.
    dedupe: ["@mysten/sui", "@mysten/dapp-kit", "@mysten/bcs", "@tanstack/react-query", "react", "react-dom"],
  },
  server: { port: 5173 },
});
