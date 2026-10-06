#!/usr/bin/env node
// V2V fix 5 - sign-in tokens kept in memory, and 20-minute access tokens.
//   1. The Cognito tokens (access, ID and refresh) are held in the page's memory instead of the
//      browser's localStorage. They are no longer written to disk, where malware or the next user of a
//      shared PC could copy them, and they are gone when the tab closes. Copies saved by earlier
//      versions are deleted when the new version first loads. A reload, or a second V2V tab, signs in
//      again: with SSO that is a few automatic redirects, without a password.
//   2. Page start goes straight to sign-in unless it is the return from sign-in (before, a page load
//      without tokens also started a sign-out, racing the sign-in redirect). The sign-in loop guard is
//      reset once the app is running, so a few quick reloads do not trip it.
//   3. Access and ID tokens last 20 minutes instead of 60. A copied token stops working sooner, also at
//      the proxy, which checks tokens itself and does not see a sign-out. The webapp renews them in the
//      background 4 minutes before they expire. The 12-hour sign-in is unchanged.
//   4. proxy/README.md: where to get a token for the latency benchmark, now that it is not in
//      localStorage.
//
// Run from the project root (the folder that contains cdk-stacks, webapp, proxy and SETUP.md):
//   node apply-v2v-fix-5.cjs            check only: reports what it would do, changes nothing
//   node apply-v2v-fix-5.cjs --apply    applies everything, or nothing if any check fails
//
// - Edits 2 webapp files (webapp/utils/authUtility.js, webapp/main.js), 1 CDK file
//   (cdk-stacks/lib/infrastructure/cognito-stack.ts) and proxy/README.md in place. Each edit replaces
//   one exact block of text; if that block is not found exactly once, nothing is changed and the file
//   is reported. Any other changes you have in those files are kept. The README edit is optional.
// - Independent of fix 4: applies whether or not fix 4 is applied.
// - Backs up every file it modifies to v2v-backup-<timestamp>/ first.
// - Works with either Windows (CRLF) or Unix (LF) line endings, and is safe to run twice.
// - The deploy (cdk-stacks: npm run build:deploy:all) updates the Cognito app client (backend stack)
//   and the webapp. Agents keep the page they have open until they reload it; the first load of the new
//   version signs them in again.
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const NEW_FILES = {};

const EDITS = [
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "// Earlier versions persisted AWS credentials in localStorage; remove any left behind.\ntry {\n  localStorage.removeItem(\"awsCredentials\");\n} catch {",
  "replace": "// Earlier versions persisted AWS credentials and Cognito tokens in localStorage; remove any left behind.\ntry {\n  for (const key of [\"awsCredentials\", \"accessToken\", \"idToken\", \"refreshToken\"]) localStorage.removeItem(key);\n} catch {"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "// Store tokens in localStorage\nfunction setTokens(tokens) {\n  localStorage.setItem(\"accessToken\", tokens.access_token);\n  localStorage.setItem(\"idToken\", tokens.id_token);\n  if (tokens.refresh_token) {\n    localStorage.setItem(\"refreshToken\", tokens.refresh_token);\n  }\n}",
  "replace": "// Cognito tokens, held in this page's memory only: they are never written to disk, where malware or the next\n// user of a shared PC could copy them, and they are gone when the tab closes. A reload therefore signs in\n// again, which with SSO is a few automatic redirects.\nlet _tokens = null;\n\nfunction setTokens(tokens) {\n  _tokens = {\n    accessToken: tokens.access_token,\n    idToken: tokens.id_token,\n    // A refresh response carries no new refresh token: keep the one from sign-in.\n    refreshToken: tokens.refresh_token ?? _tokens?.refreshToken ?? null,\n  };\n}\n\nfunction getToken(name) {\n  return _tokens?.[name] ?? null;\n}"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export async function refreshTokens() {\n  const refreshToken = localStorage.getItem(\"refreshToken\");",
  "replace": "export async function refreshTokens() {\n  const refreshToken = getToken(\"refreshToken\");"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export function isAuthenticated() {\n  const idToken = localStorage.getItem(\"idToken\");\n  const accessToken = localStorage.getItem(\"accessToken\");\n  const refreshToken = localStorage.getItem(\"refreshToken\");",
  "replace": "export function isAuthenticated() {\n  const idToken = getToken(\"idToken\");\n  const accessToken = getToken(\"accessToken\");\n  const refreshToken = getToken(\"refreshToken\");"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export async function getValidTokens() {\n  const idToken = localStorage.getItem(\"idToken\");\n  const accessToken = localStorage.getItem(\"accessToken\");\n  const refreshToken = localStorage.getItem(\"refreshToken\");",
  "replace": "export async function getValidTokens() {\n  const idToken = getToken(\"idToken\");\n  const accessToken = getToken(\"accessToken\");\n  const refreshToken = getToken(\"refreshToken\");"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "  return {\n    accessToken: localStorage.getItem(\"accessToken\"),\n    idToken: localStorage.getItem(\"idToken\"),\n    refreshToken: localStorage.getItem(\"refreshToken\"),\n  };",
  "replace": "  return {\n    accessToken: getToken(\"accessToken\"),\n    idToken: getToken(\"idToken\"),\n    refreshToken: getToken(\"refreshToken\"),\n  };"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export function getUserInfo() {\n  const token = localStorage.getItem(\"idToken\");",
  "replace": "export function getUserInfo() {\n  const token = getToken(\"idToken\");"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export function startTokenRefreshTimer(onRefresh) {\n  const idToken = localStorage.getItem(\"idToken\");\n  const accessToken = localStorage.getItem(\"accessToken\");",
  "replace": "export function startTokenRefreshTimer(onRefresh) {\n  const idToken = getToken(\"idToken\");\n  const accessToken = getToken(\"accessToken\");"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export function getSessionExpiresAt() {\n  const idToken = localStorage.getItem(\"idToken\");",
  "replace": "export function getSessionExpiresAt() {\n  const idToken = getToken(\"idToken\");"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "  const refreshToken = localStorage.getItem(\"refreshToken\");\n\n  // Clear local storage\n  localStorage.removeItem(\"accessToken\");\n  localStorage.removeItem(\"idToken\");\n  localStorage.removeItem(\"refreshToken\");\n  _awsCredentials = null;",
  "replace": "  const refreshToken = getToken(\"refreshToken\");\n\n  _tokens = null;\n  _awsCredentials = null;"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "  getLoginUrl,\n  getValidTokens,\n  handleRedirect,\n  isAuthenticated,\n  logout,",
  "replace": "  getLoginUrl,\n  handleRedirect,\n  logout,"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "      startTokenRefreshTimer();\n      showApp();\n      return;\n    }\n\n    // Check authentication and token expiration\n    if (!isAuthenticated()) {\n      const tokens = await getValidTokens();\n      if (\n        tokens?.accessToken == null ||\n        tokens?.idToken == null ||\n        tokens?.refreshToken == null\n      ) {\n        // No valid token available, redirect to login\n        console.info(\n          `${LOGGER_PREFIX} - initializeApp - No valid token available, redirecting to login`,\n        );\n        redirectToLogin();\n        return;\n      }\n    }\n\n    // Show app with valid token\n    console.info(\n      `${LOGGER_PREFIX} - initializeApp - Valid token available, showing app`,\n    );\n    startTokenRefreshTimer();\n    showApp();\n  } catch (error) {",
  "replace": "      startTokenRefreshTimer();\n      showApp();\n      // Signed in and running: reset the redirect-loop guard (redirectToLogin), which is only for sign-ins\n      // that keep failing. Reset after showApp, so a page that fails right after sign-in still trips it.\n      try {\n        sessionStorage.removeItem(\"loginRedirects\");\n      } catch (_) {\n        // Storage unavailable: nothing to reset.\n      }\n      return;\n    }\n\n    // Tokens are held in the page's memory only (authUtility.js), so every other page load signs in again.\n    console.info(\n      `${LOGGER_PREFIX} - initializeApp - Not signed in, redirecting to login`,\n    );\n    redirectToLogin();\n  } catch (error) {"
 },
 {
  "file": "cdk-stacks/lib/infrastructure/cognito-stack.ts",
  "optional": false,
  "find": "/** How long a sign-in lasts before the agent must sign in again (refresh token lifetime). */\nexport const REFRESH_TOKEN_VALIDITY = cdk.Duration.hours(12);",
  "replace": "/** How long a sign-in lasts before the agent must sign in again (refresh token lifetime). */\nexport const REFRESH_TOKEN_VALIDITY = cdk.Duration.hours(12);\n\n/** How long each access and ID token lasts. The webapp renews both in the background 4 minutes before they expire. */\nexport const TOKEN_VALIDITY = cdk.Duration.minutes(20);"
 },
 {
  "file": "cdk-stacks/lib/infrastructure/cognito-stack.ts",
  "optional": false,
  "find": "      refreshTokenValidity: REFRESH_TOKEN_VALIDITY,",
  "replace": "      refreshTokenValidity: REFRESH_TOKEN_VALIDITY,\n      // Short-lived, so a copied token soon stops working, including at the proxy, which checks tokens itself\n      // and does not see a sign-out.\n      accessTokenValidity: TOKEN_VALIDITY,\n      idTokenValidity: TOKEN_VALIDITY,"
 },
 {
  "file": "proxy/README.md",
  "optional": true,
  "find": "After signing in to the Webapp: DevTools → Application → Local Storage → `accessToken`. It is valid for 1 hour.",
  "replace": "Open DevTools → Network (with Preserve log on), then sign in to the Webapp or reload it: the `token` request to the Cognito domain → Response → `access_token`. It is valid for 20 minutes."
 }
];

// Detects a copy damaged in transfer (cut short, or saved in a non-UTF-8 encoding).
const INTEGRITY = "d304bb4d877eb9a849836d6f880147e94487756bc278308fed34b4b8733043fa";
const actual = crypto.createHash("sha256").update(JSON.stringify({ newFiles: NEW_FILES, edits: EDITS })).digest("hex");
if (actual !== INTEGRITY) {
  console.log("STOPPED - nothing was changed. This script was damaged when it was copied (text cut short or saved in a");
  console.log("non-UTF-8 encoding). Copy it again and save it as UTF-8.");
  process.exit(1);
}

const applyMode = process.argv.includes("--apply");
const exit = (code, lines) => {
  console.log(lines.join("\n"));
  process.exit(code);
};

if (!fs.existsSync("cdk-stacks") || !fs.existsSync("webapp")) {
  exit(1, ["Run this from the project root: the folder that contains cdk-stacks and webapp.", `Current folder: ${process.cwd()}`]);
}

const problems = [];
const notes = [];
const edited = new Map(); // file -> { raw, eol, text, count, already }

for (const e of EDITS) {
  let entry = edited.get(e.file);
  if (!entry) {
    if (!fs.existsSync(e.file)) {
      (e.optional ? notes : problems).push(`${e.file}: file not found${e.optional ? " (optional, skipped)" : ""}`);
      continue;
    }
    const raw = fs.readFileSync(e.file, "utf8");
    entry = { raw, eol: raw.includes("\r\n") ? "\r\n" : "\n", text: raw.replace(/\r\n/g, "\n"), count: 0, already: 0 };
    edited.set(e.file, entry);
  }
  if (entry.text.includes(e.replace)) {
    entry.already++;
    continue;
  }
  const n = entry.text.split(e.find).length - 1;
  if (n === 1) {
    entry.text = entry.text.replace(e.find, () => e.replace);
    entry.count++;
  } else {
    const where = `${e.file}: the block starting "${e.find.split("\n")[0].trim().slice(0, 70)}" was ${n === 0 ? "not found" : `found ${n} times`}`;
    (e.optional ? notes : problems).push(where + (e.optional ? " (optional, skipped)" : ""));
  }
}

const creates = [];
const overwrites = [];
for (const [file, content] of Object.entries(NEW_FILES)) {
  if (!fs.existsSync(file)) creates.push(file);
  else if (fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n") !== content) overwrites.push(file);
}

if (problems.length) {
  exit(1, [
    "STOPPED - nothing was changed. These files do not match what the changes expect:",
    ...problems.map((p) => "  - " + p),
    "",
    "Your copy of these files differs from the one the changes were made against. Send these files to be merged.",
  ]);
}

const editFiles = [...edited].filter(([, v]) => v.count > 0);
const alreadyAll = editFiles.length === 0 && creates.length === 0 && overwrites.length === 0;
const summary = [
  `New files to create: ${creates.length}${creates.length ? " (" + creates.join(", ") + ")" : ""}`,
  ...(overwrites.length ? [`New files that already exist with different content (will be overwritten): ${overwrites.length}`, ...overwrites.map((f) => "  - " + f)] : []),
  `Existing files to edit: ${editFiles.length} (15 edits in total)`,
  ...editFiles.map(([f, v]) => `  - ${f} (${v.count} edit${v.count > 1 ? "s" : ""}${v.already ? `, ${v.already} already applied` : ""})`),
  ...notes.map((n) => "Note: " + n),
];

if (alreadyAll) {
  exit(0, ["NOTHING TO DO - fix 5 is already applied to this copy."]);
}

if (!applyMode) {
  exit(0, ["CHECK PASSED - nothing was changed.", ...summary, "", "Run again with --apply to make these changes: node apply-v2v-fix-5.cjs --apply"]);
}

const backup = `v2v-backup-${new Date().toISOString().replace(/[:.]/g, "-")}`;
const toBackUp = [...editFiles.map(([f]) => f), ...overwrites];
for (const file of toBackUp) {
  fs.mkdirSync(path.dirname(path.join(backup, file)), { recursive: true });
  fs.copyFileSync(file, path.join(backup, file));
}
for (const file of [...creates, ...overwrites]) {
  fs.mkdirSync(path.dirname(file) || ".", { recursive: true });
  fs.writeFileSync(file, NEW_FILES[file]);
}
for (const [file, v] of editFiles) {
  fs.writeFileSync(file, v.eol === "\r\n" ? v.text.replace(/\n/g, "\r\n") : v.text);
}

exit(0, [
  "APPLIED.",
  ...summary,
  toBackUp.length ? `Backups of the ${toBackUp.length} changed files: ${backup}` : "No existing files needed a backup.",
  "",
  "Next, in CloudShell (after running this script there too):",
  "  cd cdk-stacks && npm run build:deploy:all",
]);
