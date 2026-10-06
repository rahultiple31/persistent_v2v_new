// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import MicrophoneStream from "microphone-stream";
import { NOVA_INTERPRETER_LANGUAGES } from "../constants";

export function translateCodeToLanguageName(code) {
  if (!code) return code;
  const hit = NOVA_INTERPRETER_LANGUAGES.find((l) => l.code === code);
  return hit?.name || code;
}

export function float32ToPcm16LittleEndian(float32Array) {
  const buffer = new ArrayBuffer(float32Array.length * 2);
  const view = new DataView(buffer);
  for (let i = 0; i < float32Array.length; i++) {
    let s = Math.max(-1, Math.min(1, float32Array[i]));
    view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Uint8Array(buffer);
}

export function resamplePcm16Linear(pcm16, fromRate, toRate) {
  if (fromRate === toRate) return pcm16;
  const inSamples = pcm16.length / 2;
  const outSamples = Math.max(1, Math.floor((inSamples * toRate) / fromRate));
  const outBuffer = new ArrayBuffer(outSamples * 2);
  const outView = new DataView(outBuffer);
  const inView = new DataView(pcm16.buffer, pcm16.byteOffset, pcm16.byteLength);
  for (let i = 0; i < outSamples; i++) {
    const srcPos = (i * fromRate) / toRate;
    const i0 = Math.floor(srcPos);
    const i1 = Math.min(i0 + 1, inSamples - 1);
    const frac = srcPos - i0;
    const s0 = inView.getInt16(i0 * 2, true);
    const s1 = inView.getInt16(i1 * 2, true);
    const s = Math.round(s0 * (1 - frac) + s1 * frac);
    outView.setInt16(i * 2, s, true);
  }
  return new Uint8Array(outBuffer);
}

export function encodeMicChunkToNovaPcm16(chunk, inputSampleRate, targetSampleRate = 16000) {
  const input = MicrophoneStream.toRaw(chunk);
  const pcmNative = float32ToPcm16LittleEndian(input);
  return resamplePcm16Linear(pcmNative, inputSampleRate, targetSampleRate);
}

// Taps of the anti-aliasing low-pass filter. Odd, so the filter is symmetric around one centre tap.
// 127 taps at 48 kHz: flat to ~5 kHz, stop band from ~8.2 kHz, delay (taps-1)/2 = 63 samples = 1.3 ms.
const DOWNSAMPLER_TAPS = 127;

/** Windowed-sinc (Blackman) low-pass, normalised to unity gain at 0 Hz. */
function designLowPass(sampleRate, cutoffHz, taps) {
  const h = new Float32Array(taps);
  const mid = (taps - 1) / 2;
  const fc = cutoffHz / sampleRate;
  let sum = 0;
  for (let n = 0; n < taps; n++) {
    const k = n - mid;
    const sinc = k === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * k) / (Math.PI * k);
    const w =
      0.42 -
      0.5 * Math.cos((2 * Math.PI * n) / (taps - 1)) +
      0.08 * Math.cos((4 * Math.PI * n) / (taps - 1));
    h[n] = sinc * w;
    sum += h[n];
  }
  for (let n = 0; n < taps; n++) h[n] /= sum;
  return h;
}

/**
 * Streaming Float32 -> PCM16 converter from the AudioContext rate (usually 48 kHz) to 16 kHz, for
 * Nova Sonic and Transcribe. Create one per stream and pass every chunk through process().
 *
 * WHY: resamplePcm16Linear() has no low-pass filter. At 48 kHz -> 16 kHz (exactly 3:1) it just keeps
 * every third sample, so everything the microphone picks up between 8 and 24 kHz (the top of "s", "sh"
 * and "f" sounds, fan and keyboard noise) folds back into the 0-8 kHz speech band as distortion. The
 * customer's audio comes from the phone network and has almost nothing above ~4 kHz, so only the
 * agent's microphone was affected, for Nova Sonic and Transcribe alike.
 *
 * HOW: a low-pass filter just under the new Nyquist frequency, then resampling. Filter history and the
 * resampling position carry over between chunks, so chunk boundaries leave no seams and no drift.
 */
export function createPcm16Downsampler(fromRate, toRate = 16000) {
  if (!fromRate || fromRate <= toRate) {
    // Nothing to remove when not reducing the rate: convert, and resample as before.
    return {
      process(chunk) {
        const input = chunk instanceof Float32Array ? chunk : MicrophoneStream.toRaw(chunk);
        return resamplePcm16Linear(float32ToPcm16LittleEndian(input), fromRate, toRate);
      },
    };
  }

  const taps = DOWNSAMPLER_TAPS;
  const h = designLowPass(fromRate, 0.45 * toRate, taps);
  const step = fromRate / toRate;
  // The last `taps` input samples of the previous chunk: enough for the filter at input index -1, which
  // resampling needs when an output sample falls between the two chunks.
  let history = new Float32Array(taps);
  let position = 0; // input-sample position of the next output sample, relative to this chunk

  return {
    process(chunk) {
      const input = chunk instanceof Float32Array ? chunk : MicrophoneStream.toRaw(chunk);
      const len = input.length;
      const ext = new Float32Array(taps + len);
      ext.set(history, 0);
      ext.set(input, taps);

      // Filtered value at input index i of this chunk (i >= -1; negative reaches into history).
      const filtered = (i) => {
        const end = i + taps; // index in ext of the newest sample under the filter
        let acc = 0;
        for (let k = 0; k < taps; k++) acc += h[k] * ext[end - k];
        return acc;
      };

      const out = [];
      let t = position;
      for (;;) {
        const i0 = Math.floor(t);
        const frac = t - i0;
        if (i0 > len - 1 || (frac > 0 && i0 + 1 > len - 1)) break;
        const y0 = filtered(i0);
        out.push(frac > 0 ? y0 + (filtered(i0 + 1) - y0) * frac : y0);
        t += step;
      }
      position = t - len;
      history = ext.slice(ext.length - taps);

      const pcm = new Uint8Array(out.length * 2);
      const view = new DataView(pcm.buffer);
      for (let i = 0; i < out.length; i++) {
        const s = Math.max(-1, Math.min(1, out[i]));
        view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
      }
      return pcm;
    },
  };
}

/** Wrap mono 16-bit PCM in a WAV for AudioContext.decodeAudioData */
export function pcm16MonoToWavArrayBuffer(pcmBytes, sampleRate) {
  const numChannels = 1;
  const bitsPerSample = 16;
  const blockAlign = (numChannels * bitsPerSample) / 8;
  const byteRate = sampleRate * blockAlign;
  const dataSize = pcmBytes.byteLength;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);
  const writeStr = (offset, s) => {
    for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
  };
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bitsPerSample, true);
  writeStr(36, "data");
  view.setUint32(40, dataSize, true);
  new Uint8Array(buffer, 44).set(pcmBytes);
  return buffer;
}
