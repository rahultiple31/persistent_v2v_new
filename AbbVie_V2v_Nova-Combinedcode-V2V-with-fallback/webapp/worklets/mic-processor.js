// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * MicProcessorWorklet
 *
 * Runs inside the AudioWorklet thread (off the main thread).
 * Replaces the deprecated ScriptProcessorNode used by the microphone-stream
 * npm package. Benefits:
 *   - Runs on a dedicated audio thread — no main-thread blocking
 *   - Produces consistent, evenly-sized Float32 chunks
 *   - No jitter or irregular chunk sizing that confused Nova Sonic's
 *     internal role assignment (causing translated text to appear in
 *     the source/USER text box)
 *
 * The processor accumulates incoming Float32 samples into a fixed-size
 * buffer (default 4096 frames = 256ms @ 16kHz) and posts each complete
 * buffer to the main thread via MessagePort.
 */
class MicProcessorWorklet extends AudioWorkletProcessor {
  constructor(options) {
    super();
    // Buffer size in frames — matches legacy ScriptProcessorNode default
    // so downstream resampling math stays identical.
    this._bufferSize = (options && options.processorOptions && options.processorOptions.bufferSize) || 4096;
    this._buffer = new Float32Array(this._bufferSize);
    this._writePos = 0;
  }

  process(inputs) {
    // inputs[0] is the first input, inputs[0][0] is channel 0 (mono)
    const input = inputs[0];
    if (!input || !input[0]) return true;

    const channel = input[0];

    for (let i = 0; i < channel.length; i++) {
      this._buffer[this._writePos++] = channel[i];

      if (this._writePos >= this._bufferSize) {
        // Post a copy — the worklet thread retains ownership of _buffer
        this.port.postMessage({ audioChunk: this._buffer.slice(0) });
        this._writePos = 0;
      }
    }

    // Return true to keep the processor alive
    return true;
  }
}

registerProcessor("mic-processor", MicProcessorWorklet);
