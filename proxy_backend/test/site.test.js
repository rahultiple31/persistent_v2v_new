import { after, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { loadConfig } from "../src/config.js";
import { startTestServer, testConfig } from "./helpers.js";

// A small webapp build.
const dir = mkdtempSync(path.join(tmpdir(), "v2v-site-"));
const INDEX = `<!doctype html><script src="./frontend-config.js"></script>${"<p>V2V</p>".repeat(200)}`;
mkdirSync(path.join(dir, "assets"));
writeFileSync(path.join(dir, "index.html"), INDEX);
writeFileSync(path.join(dir, "assets", "index-abc123.js"), "console.log('app');");
writeFileSync(path.join(dir, "frontend-config.js"), "window.WebappConfig = { stale: true };");
after(() => rmSync(dir, { recursive: true, force: true }));

const WEBAPP_CONFIG = { oidcIssuer: "https://sso.example.com", oidcClientId: "v2v" };
const CSP = "default-src 'self'";
const siteConfig = (overrides = {}) =>
  testConfig({ WEBAPP_DIR: dir, WEBAPP_CONFIG: JSON.stringify(WEBAPP_CONFIG), CONTENT_SECURITY_POLICY: CSP, ...overrides });

test("site: serves the webapp, compressed, with security headers and a report-only CSP by default", async () => {
  const server = await startTestServer({ config: siteConfig() });
  const res = await fetch(`${server.httpUrl}/`, { headers: { "Accept-Encoding": "gzip" } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
  assert.equal(res.headers.get("content-encoding"), "gzip");
  assert.equal(await res.text(), INDEX);
  assert.equal(res.headers.get("cache-control"), "no-cache");
  assert.equal(res.headers.get("x-frame-options"), "DENY");
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  assert.equal(res.headers.get("referrer-policy"), "strict-origin-when-cross-origin");
  assert.equal(res.headers.get("content-security-policy-report-only"), CSP);
  assert.equal(res.headers.get("content-security-policy"), null);
  // HSTS only when the load balancer received the request over HTTPS.
  assert.equal(res.headers.get("strict-transport-security"), null);
  const https = await fetch(`${server.httpUrl}/`, { headers: { "X-Forwarded-Proto": "https" } });
  assert.equal(https.headers.get("strict-transport-security"), "max-age=31536000; includeSubDomains");
  await server.close();

  const enforced = await startTestServer({ config: siteConfig({ CSP_REPORT_ONLY: "false" }) });
  const res2 = await fetch(`${enforced.httpUrl}/assets/index-abc123.js`);
  assert.equal(res2.headers.get("content-type"), "text/javascript; charset=utf-8");
  assert.equal(res2.headers.get("content-security-policy"), CSP);
  assert.equal(await res2.text(), "console.log('app');");
  await enforced.close();
});

test("site: /frontend-config.js comes from WEBAPP_CONFIG, not from the build", async () => {
  const server = await startTestServer({ config: siteConfig() });
  const res = await fetch(`${server.httpUrl}/frontend-config.js`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/javascript; charset=utf-8");
  assert.equal(res.headers.get("cache-control"), "no-cache");
  assert.equal(await res.text(), `window.WebappConfig = ${JSON.stringify(WEBAPP_CONFIG)};\n`);
  await server.close();
});

test("site: app paths get index.html, missing or outside files 404, ETags revalidate, /api and /healthz unchanged", async () => {
  const server = await startTestServer({ config: siteConfig() });
  const { httpUrl } = server;
  assert.equal(await (await fetch(`${httpUrl}/callback?code=x`)).text(), INDEX);
  assert.equal((await fetch(`${httpUrl}/assets/missing.js`)).status, 404);
  assert.equal((await fetch(`${httpUrl}/%2e%2e/%2e%2e/package.json`)).status, 404);
  assert.equal((await fetch(`${httpUrl}/%E0%A4%A`)).status, 404);

  const etag = (await fetch(`${httpUrl}/index.html`)).headers.get("etag");
  assert.equal((await fetch(`${httpUrl}/index.html`, { headers: { "If-None-Match": etag } })).status, 304);
  const head = await fetch(`${httpUrl}/index.html`, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), "");
  assert.equal((await fetch(`${httpUrl}/`, { method: "POST" })).status, 405);

  const api = await fetch(`${httpUrl}/api/nope`);
  assert.equal(api.status, 404);
  assert.deepEqual(await api.json(), { error: "notFound" });
  assert.equal((await fetch(`${httpUrl}/api/translation-mode`)).status, 401);
  assert.deepEqual(await (await fetch(`${httpUrl}/healthz`)).json(), { status: "ok" });
  await server.close();
});

test("site: without WEBAPP_DIR the proxy serves no files (local development with the Vite dev server)", async () => {
  const server = await startTestServer();
  const res = await fetch(`${server.httpUrl}/`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: "notFound" });
  await server.close();
});

test("Config: WEBAPP_DIR needs WEBAPP_CONFIG as a JSON object", () => {
  const env = { BEDROCK_REGION: "us-east-1", NOVA_MODEL_ID: "m", WEBAPP_DIR: dir };
  assert.throws(() => loadConfig(env), /WEBAPP_CONFIG must be a JSON object/);
  assert.throws(() => loadConfig({ ...env, WEBAPP_CONFIG: "[1]" }), /WEBAPP_CONFIG must be a JSON object/);
  assert.equal(loadConfig({ ...env, WEBAPP_CONFIG: "{}" }).site.cspReportOnly, true);
});
