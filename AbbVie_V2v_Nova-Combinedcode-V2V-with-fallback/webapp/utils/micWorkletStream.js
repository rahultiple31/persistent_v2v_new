// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * MicWorkletStream
 *
 * A drop-in async-iterable replacement for the `microphone-stream` npm package
 * that uses AudioWorkletNode instead of the deprecated ScriptProcessorNode.
 *
 * WHY:
 *   The `microphone-stream` package internally uses ScriptProcessorNode which:
 *     - Runs on the MAIN thread (causes jitter under UI load)
 *     - Produces irregular chunk sizes when the main thread is busy
 *     - Is deprecated in all modern browsers
 *   This causes Nova Sonic to receive irregular audio chunks and misassign
 *   the USER/ASSISTANT role for text output — showing translated text in
 *   the source (Agent) text box instead of the original English.
 *
 * HOW:
 *   - Uses AudioWorkletNode (dedicated audio thread, off main thread)
 *   - Produces consistent, evenly-sized Float32Array chunks (4096 frames)
 *   - Implements the same AsyncIterable interface as MicrophoneStream
 *   - Compatible with novaSonicAdapter.js audio input loop
 *
 * USAGE:
 *   const stream = await MicWorkletStream.create(audioContext, micConstraints);
 *   // use stream as async iterable — same as MicrophoneStream
 *   for await (const chunk of stream) { ... }
 *   stream.destroy();
 */

const WORKLET_URL = new URL("../worklets/mic-processor.js", import.meta.url);

export class MicWorkletStream {
  constructor() {
    this._mediaStream = null;
    this._audioContext = null;
    this._sourceNode = null;
    this._workletNode = null;
    this._queue = [];
    this._resolve = null;
    this._destroyed = false;
  }

  /**
   * Factory — creates and fully initialises a MicWorkletStream.
   * @param {AudioContext} audioContext  - Shared AudioContext from AudioContextManager
   * @param {MediaStreamConstraints} micConstraints - getUserMedia constraints
   * @returns {Promise<MicWorkletStream>}
   */
  static async create(audioContext, micConstraints) {
    const instance = new MicWorkletStream();
    await instance._init(audioContext, micConstraints);
    return instance;
  }

  async _init(audioContext, micConstraints) {
    this._audioContext = audioContext;

    // 1. Request microphone access
    this._mediaStream = await navigator.mediaDevices.getUserMedia(micConstraints);

    // 2. Register the worklet module (no-op if already registered)
    try {
      await this._audioContext.audioWorklet.addModule(WORKLET_URL);
    } catch (e) {
      // Already added — safe to ignore
      if (!e.message?.includes("already")) {
        throw e;
      }
    }

    // 3. Create source node from mic stream
    this._sourceNode = this._audioContext.createMediaStreamSource(this._mediaStream);

    // 4. Create worklet node with consistent 4096-frame buffer
    this._workletNode = new AudioWorkletNode(this._audioContext, "mic-processor", {
      processorOptions: { bufferSize: 4096 },
      numberOfInputs: 1,
      numberOfOutputs: 1,
      outputChannelCount: [1],
    });

    // 5. Wire: mic source → worklet
    this._sourceNode.connect(this._workletNode);
    // Do NOT connect workletNode to destination — we only want to capture, not play back

    // 6. Handle incoming audio chunks from the worklet thread
    this._workletNode.port.onmessage = (event) => {
      if (this._destroyed) return;
      const chunk = event.data.audioChunk; // Float32Array
      if (this._resolve) {
        const resolve = this._resolve;
        this._resolve = null;
        resolve({ value: chunk, done: false });
      } else {
        this._queue.push(chunk);
      }
    };
  }

  /**
   * AsyncIterable interface — compatible with novaSonicAdapter.js input loop.
   */
  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this._destroyed) {
          return Promise.resolve({ value: undefined, done: true });
        }
        if (this._queue.length > 0) {
          return Promise.resolve({ value: this._queue.shift(), done: false });
        }
        return new Promise((resolve) => {
          this._resolve = resolve;
        });
      },
      return: () => {
        this.destroy();
        return Promise.resolve({ value: undefined, done: true });
      },
    };
  }

  /**
   * Cleanly tears down the worklet, source node, and mic stream.
   * Mirrors MicrophoneStream.destroy() so call sites are identical.
   */
  destroy() {
    if (this._destroyed) return;
    this._destroyed = true;

    // Unblock any pending iterator
    if (this._resolve) {
      this._resolve({ value: undefined, done: true });
      this._resolve = null;
    }

    try { this._workletNode?.port.close(); } catch { /* ignore */ }
    try { this._workletNode?.disconnect(); } catch { /* ignore */ }
    try { this._sourceNode?.disconnect(); } catch { /* ignore */ }
    try {
      this._mediaStream?.getTracks().forEach((t) => t.stop());
    } catch { /* ignore */ }

    this._workletNode = null;
    this._sourceNode = null;
    this._mediaStream = null;
    this._queue = [];
  }

  /**
   * Returns the underlying MediaStream — used by AudioStreamManager.startMicrophone()
   * if it needs the raw stream.
   */
  getMediaStream() {
    return this._mediaStream;
  }
}
