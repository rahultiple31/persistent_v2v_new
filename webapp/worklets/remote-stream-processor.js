// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * RemoteStreamProcessorWorklet
 *
 * AudioWorklet processor for capturing the customer's WebRTC remote audio
 * stream (replaces the deprecated MicrophoneStream / ScriptProcessorNode
 * used by captureFromCustomerAudioStream()).
 *
 * WHY:
 *   The old MicrophoneStream.setStream() internally uses ScriptProcessorNode
 *   which runs on the main thread and produces irregular audio chunks.
 *   For the customer remote WebRTC stream this causes:
 *     - Irregular chunk sizes → Nova Sonic role misassignment
 *     - Main thread jitter during UI activity
 *     - Deprecation warnings in all modern browsers
 *
 * HOW:
 *   - Runs on dedicated audio thread (off main thread)
 *   - Produces consistent 4096-frame Float32Array chunks
 *   - Same interface as mic-processor.js for symmetry
 */
class RemoteStreamProcessorWorklet extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this._bufferSize =
      (options &&
        options.processorOptions &&
        options.processorOptions.bufferSize) ||
      4096;
    this._buffer = new Float32Array(this._bufferSize);
    this._writePos = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;

    const channel = input[0];

    for (let i = 0; i < channel.length; i++) {
      this._buffer[this._writePos++] = channel[i];

      if (this._writePos >= this._bufferSize) {
        this.port.postMessage({ audioChunk: this._buffer.slice(0) });
        this._writePos = 0;
      }
    }

    return true;
  }
}

registerProcessor("remote-stream-processor", RemoteStreamProcessorWorklet);
