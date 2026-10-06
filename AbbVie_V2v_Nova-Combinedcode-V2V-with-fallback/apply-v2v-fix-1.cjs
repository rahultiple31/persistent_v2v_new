#!/usr/bin/env node
// V2V server-side proxy - fix 1: Transcribe through the proxy never started (it waited for Transcribe to
// accept the stream before sending audio, but Transcribe only accepts a stream once audio arrives).
// Apply on top of apply-v2v-fix-1.cjs.
//
// Run from the project root (the folder that contains cdk-stacks, webapp and SETUP.md):
//   node apply-v2v-fix-1.cjs            check only: reports what it would do, changes nothing
//   node apply-v2v-fix-1.cjs --apply    applies everything, or nothing if any check fails
//
// - Edits 5 existing files in place (7 edits). Each edit replaces one exact block of
//   text; if that block is not found exactly once, nothing is changed and the file is reported.
//   Any other changes you have in those files are kept.
// - Backs up every file it modifies or overwrites to v2v-backup-<timestamp>/ first.
// - Works with either Windows (CRLF) or Unix (LF) line endings, and is safe to run twice.
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const NEW_FILES = {};

const EDITS = [
 {
  "file": "webapp/adapters/TranscribeStreamAdapter.js",
  "optional": false,
  "find": "import { openTranscribeProxyStream } from \"../utils/proxyTransport\";",
  "replace": "import { startTranscribeProxyStream } from \"../utils/proxyTransport\";"
 },
 {
  "file": "webapp/adapters/TranscribeStreamAdapter.js",
  "optional": false,
  "find": "  async _startViaProxy() {\n    const stream = await this._connectProxy();\n    if (!stream) return;\n    this._audioIterator = this._audioGenerator();\n    this._runProxy(stream).catch((e) => {\n      if (!this._stopped) this._onError(e);\n    });\n    console.info(`${LOGGER_PREFIX} - TranscribeStreamAdapter started via proxy (lang: ${this._languageCode})`);\n  }\n\n  /** Same retry policy as the direct path. Returns null (after reporting) when every attempt fails. */\n  async _connectProxy() {\n    for (let attempt = 1; attempt <= MAX_START_ATTEMPTS; attempt++) {\n      try {\n        const stream = await openTranscribeProxyStream({\n          languageCode: this._languageCode,\n          sampleRate: TRANSCRIBE_SAMPLE_RATE,\n        });\n        if (this._stopped) {\n          stream.close();\n          return null;\n        }\n        return stream;\n      } catch (e) {",
  "replace": "  async _startViaProxy() {\n    this._audioIterator = this._audioGenerator();\n    const session = await this._connectProxy();\n    if (!session) return;\n    this._runProxy(session).catch((e) => {\n      if (!this._stopped) this._onError(e);\n    });\n    console.info(`${LOGGER_PREFIX} - TranscribeStreamAdapter started via proxy (lang: ${this._languageCode})`);\n  }\n\n  /**\n   * Opens a proxy stream and feeds it audio straight away. Transcribe only\n   * accepts a stream once audio arrives, so waiting for \"ready\" before sending\n   * audio never completes: that is what timed out every attempt after 15 s.\n   * The direct path never hit this because the SDK starts reading the audio\n   * generator as soon as the request is sent.\n   * Resolves once Transcribe has accepted the stream.\n   */\n  async _openProxySession() {\n    const stream = await startTranscribeProxyStream({\n      languageCode: this._languageCode,\n      sampleRate: TRANSCRIBE_SAMPLE_RATE,\n    });\n    const pump = this._pumpProxy(stream);\n    try {\n      await stream.ready;\n    } catch (e) {\n      stream.close();\n      await pump;\n      throw e;\n    }\n    return { stream, pump };\n  }\n\n  /** Same retry policy as the direct path. Returns null (after reporting) when every attempt fails. */\n  async _connectProxy() {\n    for (let attempt = 1; attempt <= MAX_START_ATTEMPTS; attempt++) {\n      try {\n        const session = await this._openProxySession();\n        if (this._stopped) {\n          session.stream.close();\n          return null;\n        }\n        return session;\n      } catch (e) {"
 },
 {
  "file": "webapp/adapters/TranscribeStreamAdapter.js",
  "optional": false,
  "find": "  async _runProxy(stream) {\n    let reconnects = 0;\n    while (stream && !this._stopped) {\n      const streamStartedAt = Date.now();\n      const outcome = await this._pumpProxy(stream);\n      if (outcome === \"audioEnded\" || this._stopped) return;\n\n      if (Date.now() - streamStartedAt >= PROXY_STABLE_STREAM_MS) reconnects = 0;\n      if (++reconnects > MAX_PROXY_RECONNECTS) {\n        throw new Error(`Transcribe proxy stream closed ${MAX_PROXY_RECONNECTS} times in a row (${outcome})`);\n      }\n      console.warn(`${LOGGER_PREFIX} - TranscribeStreamAdapter proxy stream ended (${outcome}) — reconnecting`);\n      stream = await this._connectProxy();\n    }\n  }",
  "replace": "  async _runProxy(session) {\n    let reconnects = 0;\n    while (session && !this._stopped) {\n      const streamStartedAt = Date.now();\n      const outcome = await session.pump;\n      if (outcome === \"audioEnded\" || this._stopped) return;\n\n      if (Date.now() - streamStartedAt >= PROXY_STABLE_STREAM_MS) reconnects = 0;\n      if (++reconnects > MAX_PROXY_RECONNECTS) {\n        throw new Error(`Transcribe proxy stream closed ${MAX_PROXY_RECONNECTS} times in a row (${outcome})`);\n      }\n      console.warn(`${LOGGER_PREFIX} - TranscribeStreamAdapter proxy stream ended (${outcome}) — reconnecting`);\n      session = await this._connectProxy();\n    }\n  }"
 },
 {
  "file": "webapp/utils/proxyTransport.js",
  "optional": false,
  "find": "/**\n * Opens a Transcribe stream through the proxy and resolves once Transcribe has accepted it.\n * Send PCM16 chunks with sendBinary(); read { control: { type: \"transcript\", text } } from messages().\n */\nexport async function openTranscribeProxyStream({ languageCode, sampleRate }) {\n  const stream = await startStream({ type: \"start\", service: \"transcribe\", languageCode, sampleRate });\n  await stream.ready;\n  return stream;\n}",
  "replace": "/**\n * Starts a Transcribe stream through the proxy WITHOUT waiting for Transcribe to accept it. Send PCM16\n * chunks with sendBinary() straight away, then await `stream.ready`: Transcribe only accepts a stream once\n * audio arrives, so waiting first would never complete. Read { control: { type: \"transcript\", text } }\n * from messages().\n */\nexport async function startTranscribeProxyStream({ languageCode, sampleRate }) {\n  return startStream({ type: \"start\", service: \"transcribe\", languageCode, sampleRate });\n}"
 },
 {
  "file": "proxy/test/helpers.js",
  "optional": false,
  "find": "/** Transcribe fake: for every audio chunk emits a partial and a final result. */\nexport function fakeTranscribe() {\n  return {\n    commands: [],\n    async send(command) {\n      this.commands.push(command);\n      const audio = command.input.AudioStream;\n      return {\n        TranscriptResultStream: (async function* () {\n          let n = 0;\n          for await (const event of audio) {\n            n++;\n            const bytes = event.AudioEvent.AudioChunk.length;",
  "replace": "/**\n * Transcribe fake: for every audio chunk emits a partial and a final result. Like the real service, it\n * accepts the stream (send() resolves) only once the first audio chunk has arrived.\n */\nexport function fakeTranscribe() {\n  return {\n    commands: [],\n    async send(command) {\n      this.commands.push(command);\n      const audio = command.input.AudioStream[Symbol.asyncIterator]();\n      const first = await audio.next();\n      return {\n        TranscriptResultStream: (async function* () {\n          let n = 0;\n          for (let event = first; !event.done; event = await audio.next()) {\n            n++;\n            const bytes = event.value.AudioEvent.AudioChunk.length;"
 },
 {
  "file": "proxy/test/server.test.js",
  "optional": false,
  "find": "  const bad = await runClient(server.wsUrl, [auth(), start(\"transcribe\", { languageCode: \"es\", sampleRate: 16000 })]);\n  assert.equal(bad.code, CLOSE_CODES.BAD_REQUEST);\n  await server.close();\n});",
  "replace": "  const bad = await runClient(server.wsUrl, [auth(), start(\"transcribe\", { languageCode: \"es\", sampleRate: 16000 })]);\n  assert.equal(bad.code, CLOSE_CODES.BAD_REQUEST);\n  await server.close();\n});\n\ntest(\"Transcribe: 'ready' only arrives once audio flows, so clients must send audio before waiting for it\", async () => {\n  const server = await startTestServer();\n  const ws = new WebSocket(server.wsUrl, { origin: \"https://app.example.com\" });\n  const messages = [];\n  ws.on(\"message\", (data) => messages.push(JSON.parse(data.toString())));\n  await new Promise((resolve) => ws.on(\"open\", resolve));\n  ws.send(auth());\n  ws.send(start(\"transcribe\", { languageCode: \"en-US\", sampleRate: 16000 }));\n\n  await new Promise((resolve) => setTimeout(resolve, 200));\n  assert.deepEqual(messages, [], \"no ready before any audio\");\n\n  ws.send(Buffer.alloc(3200), { binary: true });\n  await new Promise((resolve) => setTimeout(resolve, 200));\n  assert.deepEqual(messages.slice(0, 2), [{ type: \"ready\" }, { type: \"transcript\", text: \"final 1 3200\" }]);\n  ws.close();\n  await server.close();\n});"
 },
 {
  "file": "proxy/bench/latency.mjs",
  "optional": false,
  "find": "  const stream = transport(\"transcribe\", { languageCode: \"en-US\", sampleRate: SAMPLE_RATE });\n  const { readyMs, connectMs, outputs } = await stream.open();\n  let finalAt = null;\n  let readerError = null;\n  const reader = (async () => {\n    for await (const output of outputs) {\n      if (output.transcript && finalAt == null) {\n        finalAt = now();\n        return;\n      }\n    }\n  })().catch((err) => {\n    readerError = err;\n  });\n  const endOfSpeech = await streamRealtime(speech, (chunk) => stream.send(chunk), () => finalAt != null || readerError != null);\n  stream.end();\n  await Promise.race([reader, sleep(3000)]);\n  stream.close();\n  if (readerError) throw readerError;\n  if (finalAt == null) throw new Error(\"Transcribe returned no final transcript\");\n  return { readyMs, connectMs, finalMs: finalAt - endOfSpeech };",
  "replace": "  const stream = transport(\"transcribe\", { languageCode: \"en-US\", sampleRate: SAMPLE_RATE });\n  // Audio starts straight away: Transcribe only accepts the stream once audio arrives, so waiting for\n  // open() before streaming would never complete.\n  const opened = stream.open();\n  let finalAt = null;\n  let readerError = null;\n  const reader = opened\n    .then(async ({ outputs }) => {\n      for await (const output of outputs) {\n        if (output.transcript && finalAt == null) {\n          finalAt = now();\n          return;\n        }\n      }\n    })\n    .catch((err) => {\n      readerError = err;\n    });\n  const endOfSpeech = await streamRealtime(speech, (chunk) => stream.send(chunk), () => finalAt != null || readerError != null);\n  stream.end();\n  await Promise.race([reader, sleep(3000)]);\n  stream.close();\n  if (readerError) throw readerError;\n  const { readyMs, connectMs } = await opened;\n  if (finalAt == null) throw new Error(\"Transcribe returned no final transcript\");\n  return { readyMs, connectMs, finalMs: finalAt - endOfSpeech };"
 }
];

// Detects a copy damaged in transfer (cut short, or saved in a non-UTF-8 encoding).
const INTEGRITY = "791dcf5fffa39e69e78931d8d2b2f72cf11f00246c1c824e4f7cc6f06201c76c";
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
const edited = new Map(); // file -> { raw, eol, text, count }

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
const summary = [
  `New files to create: ${creates.length}`,
  ...(overwrites.length ? [`New files that already exist with different content (will be overwritten): ${overwrites.length}`, ...overwrites.map((f) => "  - " + f)] : []),
  `Existing files to edit: ${editFiles.length}`,
  ...editFiles.map(([f, v]) => `  - ${f} (${v.count} edit${v.count > 1 ? "s" : ""}${v.already ? `, ${v.already} already applied` : ""})`),
  ...notes.map((n) => "Note: " + n),
];

if (!applyMode) {
  exit(0, ["CHECK PASSED - nothing was changed.", ...summary, "", "Run again with --apply to make these changes: node apply-v2v-fix-1.cjs --apply"]);
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
  "Next:",
  "  Redeploy the webapp: cd cdk-stacks && npm run build:deploy:all   (in CloudShell)",
  "  Only the webapp changed; the proxy container is unchanged and is not rebuilt.",
]);
