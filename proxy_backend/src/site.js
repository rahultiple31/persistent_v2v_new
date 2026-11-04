// Serves the webapp: the built files, the generated /frontend-config.js and the security headers.
//
// Every file is read into memory at startup (the build is a few MB) and looked up by its exact path, so a
// request can never reach anything outside the build. Text files are also kept gzip-compressed, since the
// load balancer does not compress.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { gzipSync } from "node:zlib";

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".ico": "image/x-icon",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".wav": "audio/wav",
  ".mp3": "audio/mpeg",
  ".wasm": "application/wasm",
};
const COMPRESSIBLE = /^(text\/|application\/json|image\/svg\+xml)/;
const MIN_COMPRESS_BYTES = 1024;
export const FRONTEND_CONFIG_PATH = "/frontend-config.js";
const INDEX_PATH = "/index.html";

function asset(body, contentType) {
  const gzip = COMPRESSIBLE.test(contentType) && body.length >= MIN_COMPRESS_BYTES ? gzipSync(body) : null;
  return {
    body,
    gzip: gzip && gzip.length < body.length ? gzip : null,
    contentType,
    etag: `"${createHash("sha256").update(body).digest("base64url").slice(0, 22)}"`,
  };
}

function readTree(root, dir = root, files = new Map()) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) readTree(root, full, files);
    else if (entry.isFile()) {
      const urlPath = `/${path.relative(root, full).split(path.sep).join("/")}`;
      files.set(urlPath, asset(readFileSync(full), CONTENT_TYPES[path.extname(full).toLowerCase()] ?? "application/octet-stream"));
    }
  }
  return files;
}

/**
 * @param {object} site - config.site: { dir, webappConfig, contentSecurityPolicy, cspReportOnly }
 * @returns {{ fileCount: number, handle(req, res, pathname): void }}
 */
export function createSite(site) {
  const files = readTree(site.dir);
  if (!files.has(INDEX_PATH)) throw new Error(`WEBAPP_DIR has no index.html: ${site.dir}`);
  // The settings come from the environment, not from a file in the build.
  files.set(FRONTEND_CONFIG_PATH, asset(Buffer.from(`window.WebappConfig = ${JSON.stringify(site.webappConfig)};\n`), CONTENT_TYPES[".js"]));

  const cspHeader = site.cspReportOnly ? "Content-Security-Policy-Report-Only" : "Content-Security-Policy";
  const securityHeaders = (req) => ({
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    ...(site.contentSecurityPolicy ? { [cspHeader]: site.contentSecurityPolicy } : {}),
    // Only the load balancer reaches the tasks, so its X-Forwarded-Proto can be trusted.
    ...(req.headers["x-forwarded-proto"] === "https" ? { "Strict-Transport-Security": "max-age=31536000; includeSubDomains" } : {}),
  });

  return {
    fileCount: files.size,

    handle(req, res, pathname) {
      if (req.method !== "GET" && req.method !== "HEAD") {
        res.writeHead(405, { Allow: "GET, HEAD", "Content-Length": 0, ...securityHeaders(req) });
        res.end();
        return;
      }
      let filePath;
      try {
        filePath = decodeURIComponent(pathname);
      } catch {
        filePath = null;
      }
      // Paths without a file extension are the app's own pages: answer with index.html.
      const file =
        files.get(filePath === "/" ? INDEX_PATH : filePath) ?? (filePath && !path.posix.extname(filePath) ? files.get(INDEX_PATH) : undefined);
      if (!file) {
        res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", ...securityHeaders(req) });
        res.end(req.method === "HEAD" ? undefined : "Not found");
        return;
      }

      // Every file is revalidated (cheap with the ETag), so a new deployment is picked up on the next load.
      const headers = { "Cache-Control": "no-cache", ETag: file.etag, ...(file.gzip ? { Vary: "Accept-Encoding" } : {}), ...securityHeaders(req) };
      if (req.headers["if-none-match"] === file.etag) {
        res.writeHead(304, headers);
        res.end();
        return;
      }
      const gzip = file.gzip && /\bgzip\b/.test(req.headers["accept-encoding"] || "");
      const body = gzip ? file.gzip : file.body;
      res.writeHead(200, {
        ...headers,
        "Content-Type": file.contentType,
        "Content-Length": body.length,
        ...(gzip ? { "Content-Encoding": "gzip" } : {}),
      });
      res.end(req.method === "HEAD" ? undefined : body);
    },
  };
}
