#!/usr/bin/env node
// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Latency benchmark: the same speech, streamed in real time, straight to AWS ("direct", what the browser
// does today) and through the proxy ("proxy"), from the machine this runs on. Run it from where the
// agents are, against the deployed proxy, for numbers that mean something.
//
// Measures, per path:
//   nova.ready        stream request -> stream accepted            (Start-button cost)
//   nova.firstAudio   end of speech -> first translated audio      (what the listener waits for)
//   transcribe.ready  stream request -> stream accepted
//   transcribe.final  end of speech -> first final transcript
//   proxy.connect     WebSocket handshake (the webapp pre-opens these, so it is excluded from ready)
//
// Usage (see README.md):
//   AWS_PROFILE=dev PROXY_TOKEN=<Cognito access token> \
//     node bench/latency.mjs --proxy-url https://dxxxx.cloudfront.net --runs 5
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";
import { readFile, writeFile } from "node:fs/promises";
import { WebSocket } from "ws";
import { BedrockRuntimeClient, InvokeModelWithBidirectionalStreamCommand } from "@aws-sdk/client-bedrock-runtime";
import { StartStreamTranscriptionCommand, TranscribeStreamingClient } from "@aws-sdk/client-transcribe-streaming";
import { PollyClient, SynthesizeSpeechCommand } from "@aws-sdk/client-polly";
import { NodeHttp2Handler } from "@smithy/node-http-handler";
import { AsyncQueue } from "../src/asyncQueue.js";

const { values: args } = parseArgs({
  options: {
    "proxy-url": { type: "string" },
    origin: { type: "string" },
    runs: { type: "string", default: "5" },
    paths: { type: "string", default: "direct,proxy" },
    services: { type: "string", default: "nova,transcribe" },
    audio: { type: "string" },
    phrase: { type: "string", default: "Hello, thank you for calling. Could you please tell me your employee ID so I can look up your record?" },
    "bedrock-region": { type: "string", default: process.env.BEDROCK_REGION || "us-east-1" },
    "model-id": { type: "string", default: process.env.NOVA_MODEL_ID || "amazon.nova-2-sonic-v1:0" },
    "transcribe-region": { type: "string" },
    output: { type: "string" },
  },
});

const SAMPLE_RATE = 16000;
const CHUNK_MS = 100;
const CHUNK_BYTES = (SAMPLE_RATE * 2 * CHUNK_MS) / 1000;
const MAX_TRAILING_SILENCE_MS = 8000;
const runs = Number(args.runs);
const paths = args.paths.split(",").map((p) => p.trim());
const services = args.services.split(",").map((s) => s.trim());
const bedrockRegion = args["bedrock-region"];
const transcribeRegion = args["transcribe-region"] || bedrockRegion;
const token = process.env.PROXY_TOKEN;

if (paths.includes("proxy") && (!args["proxy-url"] || !token)) {
  console.error("The proxy path needs --proxy-url and the PROXY_TOKEN environment variable (a Cognito access token).");
  process.exit(1);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const now = () => performance.now();

// ── Test audio ──────────────────────────────────────────────────────────────

async function loadSpeech() {
  if (args.audio) return readFile(args.audio); // raw PCM16 LE mono 16 kHz
  const polly = new PollyClient({ region: bedrockRegion });
  const speech = await polly.send(
    new SynthesizeSpeechCommand({ Text: args.phrase, OutputFormat: "pcm", SampleRate: String(SAMPLE_RATE), VoiceId: "Joanna", Engine: "neural" }),
  );
  return Buffer.from(await speech.AudioStream.transformToByteArray());
}

/** Streams speech then silence in real time. Returns the time the last speech chunk was sent. */
async function streamRealtime(speech, send, isDone) {
  const silence = Buffer.alloc(CHUNK_BYTES);
  const speechChunks = Math.ceil(speech.length / CHUNK_BYTES);
  const total = speechChunks + MAX_TRAILING_SILENCE_MS / CHUNK_MS;
  const startedAt = now();
  let endOfSpeech = null;
  for (let i = 0; i < total && !isDone(); i++) {
    send(i < speechChunks ? speech.subarray(i * CHUNK_BYTES, (i + 1) * CHUNK_BYTES) : silence);
    if (i === speechChunks - 1) endOfSpeech = now();
    await sleep(Math.max(0, startedAt + (i + 1) * CHUNK_MS - now()));
  }
  return endOfSpeech;
}

// ── Transports ──────────────────────────────────────────────────────────────

const bedrock = new BedrockRuntimeClient({
  region: bedrockRegion,
  requestHandler: new NodeHttp2Handler({ requestTimeout: 300_000, sessionTimeout: 300_000, disableConcurrentStreams: false, maxConcurrentStreams: 20 }),
});
const transcribe = new TranscribeStreamingClient({ region: transcribeRegion });

/** Direct: one AWS SDK stream. `open` resolves when AWS accepts the stream. */
function directStream(service, startParams) {
  const input = new AsyncQueue();
  const t0 = now();
  const opened =
    service === "nova"
      ? bedrock.send(new InvokeModelWithBidirectionalStreamCommand({ modelId: args["model-id"], body: input }))
      : transcribe.send(
          new StartStreamTranscriptionCommand({
            LanguageCode: startParams.languageCode,
            MediaSampleRateHertz: SAMPLE_RATE,
            MediaEncoding: "pcm",
            EnablePartialResultsStabilization: true,
            PartialResultsStability: "high",
            AudioStream: (async function* () {
              for await (const chunk of input) yield { AudioEvent: { AudioChunk: chunk } };
            })(),
          }),
        );
  return {
    send: (bytes) => input.push(service === "nova" ? { chunk: { bytes } } : bytes),
    end: () => input.close(),
    close: () => input.close(),
    async open() {
      const response = await opened;
      const readyMs = now() - t0;
      const body = service === "nova" ? response.body : response.TranscriptResultStream;
      return {
        readyMs,
        outputs: (async function* () {
          for await (const event of body) {
            if (event.chunk?.bytes) yield { nova: JSON.parse(Buffer.from(event.chunk.bytes).toString()) };
            else if (event.TranscriptEvent) {
              for (const r of event.TranscriptEvent.Transcript?.Results ?? []) if (!r.IsPartial) yield { transcript: r.Alternatives?.[0]?.Transcript };
            }
          }
        })(),
      };
    },
  };
}

/** Proxy: one WebSocket, auth + start + input pipelined exactly as the webapp does. */
function proxyStream(service, startParams) {
  const url = new URL("/ws", args["proxy-url"]);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const origin = args.origin || new URL(args["proxy-url"]).origin;
  const inbox = new AsyncQueue();
  const pending = [];
  const t0 = now();
  let connectMs = null;
  let resolveReady;
  let rejectReady;
  const ready = new Promise((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });

  const ws = new WebSocket(url, { origin, perMessageDeflate: false });
  ws.on("open", () => {
    connectMs = now() - t0;
    ws.send(JSON.stringify({ type: "auth", token }));
    ws.send(JSON.stringify({ type: "start", service, ...startParams }));
    for (const frame of pending.splice(0)) ws.send(frame);
  });
  ws.on("message", (data, isBinary) => {
    if (isBinary) return inbox.push({ nova: JSON.parse(data.toString()) });
    const message = JSON.parse(data.toString());
    if (message.type === "ready") resolveReady(now() - t0);
    else if (message.type === "transcript") inbox.push({ transcript: message.text });
    else if (message.type === "error") rejectReady(new Error(`${message.code}: ${message.message}`));
  });
  ws.on("close", (code, reason) => {
    rejectReady(new Error(`closed ${code} ${reason}`));
    inbox.close();
  });
  ws.on("error", (err) => rejectReady(err));

  const sendFrame = (frame) => (ws.readyState === WebSocket.OPEN ? ws.send(frame) : pending.push(frame));
  return {
    send: (bytes) => sendFrame(bytes),
    end: () => sendFrame(JSON.stringify({ type: "end" })),
    close: () => ws.close(),
    async open() {
      const readyMs = await ready;
      // The webapp keeps authenticated sockets open, so its Start pays ready minus the handshake.
      return { readyMs: readyMs - connectMs, connectMs, outputs: inbox };
    },
  };
}

// ── Sessions ────────────────────────────────────────────────────────────────

const novaEvent = (event) => Buffer.from(JSON.stringify({ event }));

async function runNova(transport, speech) {
  const promptName = randomUUID();
  const systemName = randomUUID();
  const audioName = randomUUID();
  const stream = transport("nova", {});
  stream.send(novaEvent({ sessionStart: { inferenceConfiguration: { maxTokens: 1024, topP: 0.7, temperature: 0.1 } } }));
  stream.send(
    novaEvent({
      promptStart: {
        promptName,
        textOutputConfiguration: { mediaType: "text/plain" },
        audioOutputConfiguration: { mediaType: "audio/lpcm", sampleRateHertz: 24000, sampleSizeBits: 16, channelCount: 1, voiceId: "lupe", encoding: "base64", audioType: "SPEECH" },
      },
    }),
  );
  stream.send(novaEvent({ contentStart: { promptName, contentName: systemName, type: "TEXT", interactive: true, role: "SYSTEM", textInputConfiguration: { mediaType: "text/plain" } } }));
  stream.send(
    novaEvent({
      textInput: {
        promptName,
        contentName: systemName,
        content: "You are an interpreter. Translate everything the user says from English into Spanish. Reply only with the translation.",
      },
    }),
  );
  stream.send(novaEvent({ contentEnd: { promptName, contentName: systemName } }));
  stream.send(
    novaEvent({
      contentStart: {
        promptName,
        contentName: audioName,
        type: "AUDIO",
        interactive: true,
        role: "USER",
        audioInputConfiguration: { mediaType: "audio/lpcm", sampleRateHertz: SAMPLE_RATE, sampleSizeBits: 16, channelCount: 1, audioType: "SPEECH", encoding: "base64" },
      },
    }),
  );

  const { readyMs, connectMs, outputs } = await stream.open();
  let firstAudioAt = null;
  let readerError = null;
  const reader = (async () => {
    for await (const output of outputs) {
      if (output.nova?.event?.audioOutput && firstAudioAt == null) firstAudioAt = now();
      if (firstAudioAt != null) return;
    }
  })().catch((err) => {
    readerError = err;
  });
  const endOfSpeech = await streamRealtime(
    speech,
    (chunk) => stream.send(novaEvent({ audioInput: { promptName, contentName: audioName, content: chunk.toString("base64") } })),
    () => firstAudioAt != null || readerError != null,
  );
  stream.send(novaEvent({ contentEnd: { promptName, contentName: audioName } }));
  stream.send(novaEvent({ promptEnd: { promptName } }));
  stream.send(novaEvent({ sessionEnd: {} }));
  stream.end();
  await Promise.race([reader, sleep(3000)]);
  stream.close();
  if (readerError) throw readerError;
  if (firstAudioAt == null) throw new Error("Nova Sonic returned no audio");
  return { readyMs, connectMs, firstAudioMs: firstAudioAt - endOfSpeech };
}

async function runTranscribe(transport, speech) {
  const stream = transport("transcribe", { languageCode: "en-US", sampleRate: SAMPLE_RATE });
  // Audio starts straight away: Transcribe only accepts the stream once audio arrives, so waiting for
  // open() before streaming would never complete.
  const opened = stream.open();
  let finalAt = null;
  let readerError = null;
  const reader = opened
    .then(async ({ outputs }) => {
      for await (const output of outputs) {
        if (output.transcript && finalAt == null) {
          finalAt = now();
          return;
        }
      }
    })
    .catch((err) => {
      readerError = err;
    });
  const endOfSpeech = await streamRealtime(speech, (chunk) => stream.send(chunk), () => finalAt != null || readerError != null);
  stream.end();
  await Promise.race([reader, sleep(3000)]);
  stream.close();
  if (readerError) throw readerError;
  const { readyMs, connectMs } = await opened;
  if (finalAt == null) throw new Error("Transcribe returned no final transcript");
  return { readyMs, connectMs, finalMs: finalAt - endOfSpeech };
}

// ── Report ──────────────────────────────────────────────────────────────────

function stats(values) {
  const sorted = values.filter((v) => v != null).sort((a, b) => a - b);
  if (!sorted.length) return null;
  const pick = (q) => sorted[Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1)];
  return { median: pick(0.5), p90: pick(0.9), min: sorted[0], max: sorted.at(-1), n: sorted.length };
}

const fmt = (s) => (s ? `${Math.round(s.median)} / ${Math.round(s.p90)}` : "-");

async function main() {
  const speech = await loadSpeech();
  console.log(`Speech: ${(speech.length / (SAMPLE_RATE * 2)).toFixed(1)} s | runs: ${runs} (+1 warm-up) | paths: ${paths.join(", ")}\n`);

  const transports = { direct: directStream, proxy: proxyStream };
  const results = {};
  for (const service of services) {
    for (const pathName of paths) {
      const samples = [];
      for (let i = 0; i <= runs; i++) {
        const run = service === "nova" ? runNova : runTranscribe;
        try {
          const sample = await run(transports[pathName], speech);
          if (i > 0) samples.push(sample); // run 0 warms connections, as the webapp's first Start does
          process.stdout.write(`  ${service}/${pathName} run ${i}${i === 0 ? " (warm-up)" : ""}: ${JSON.stringify(sample, (k, v) => (typeof v === "number" ? Math.round(v) : v))}\n`);
        } catch (err) {
          process.stdout.write(`  ${service}/${pathName} run ${i}: FAILED ${err.message}\n`);
        }
        await sleep(500);
      }
      results[`${service}/${pathName}`] = samples;
    }
  }

  const row = (label, key, metric) => {
    const cells = paths.map((p) => fmt(stats((results[`${key}/${p}`] ?? []).map((s) => s[metric]))));
    console.log(`${label.padEnd(40)}${cells.map((c) => c.padStart(18)).join("")}`);
  };
  console.log(`\n${"median / p90 (ms)".padEnd(40)}${paths.map((p) => p.padStart(18)).join("")}`);
  if (services.includes("nova")) {
    row("nova: stream ready (Start)", "nova", "readyMs");
    row("nova: end of speech -> first audio", "nova", "firstAudioMs");
  }
  if (services.includes("transcribe")) {
    row("transcribe: stream ready", "transcribe", "readyMs");
    row("transcribe: end of speech -> final", "transcribe", "finalMs");
  }
  if (paths.includes("proxy")) row("proxy: websocket connect (pre-opened)", services[0], "connectMs");

  const output = args.output || `bench/results-${new Date().toISOString().replace(/[:.]/g, "-")}.json`;
  await writeFile(output, JSON.stringify({ args, results }, null, 2));
  console.log(`\nRaw samples written to ${output}`);
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
