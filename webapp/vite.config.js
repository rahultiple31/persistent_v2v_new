import { defineConfig } from "vite";
import mkcert from "vite-plugin-mkcert";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import { viteStaticCopy } from "vite-plugin-static-copy";
 
// Local development with the proxy enabled: /ws and /api are forwarded to the proxy, so the app talks to
// the same origin as it does behind CloudFront. Defaults to a proxy running locally (cd proxy && npm start).
const proxyTarget = process.env.V2V_PROXY_TARGET || "http://localhost:8080";
 
export default defineConfig({
  server: {
    https: true,
    fs: {
      cachedChecks: false,
    },
    proxy: {
      "/ws": { target: proxyTarget, ws: true },
      "/api": { target: proxyTarget },
    },
  }, // Not needed for Vite 5+
  build: {
    // Never embed the AudioWorklet modules as data: URLs (Vite does that for files under 4 KB). The Content
    // Security Policy only allows scripts from the app's own origin, so the worklets must be real files.
    assetsInlineLimit: (filePath) => (/[\\/]worklets[\\/]/.test(filePath) ? false : undefined),
  },
  plugins: [
    mkcert(),
    nodePolyfills(),
    viteStaticCopy({
      targets: [
        {
          src: "lib/*",
          dest: "./lib",
        },
        {
          src: "assets/*",
          dest: "./assets",
        },
      ],
    }),
  ],
  define: {
    // By default, Vite doesn't include shims for NodeJS/
    // necessary for segment analytics lib to work
    global: {},
  },
});