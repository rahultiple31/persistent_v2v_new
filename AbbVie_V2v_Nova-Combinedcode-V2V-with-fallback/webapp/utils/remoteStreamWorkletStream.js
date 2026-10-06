// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * RemoteStreamWorkletStream
 *
 * Drop-in async-iterable replacement for MicrophoneStream.setStream()
 * for capturing the customer's WebRTC remote audio stream via AudioWorkletNode
 * instead of the deprecated ScriptProcessorNode.
 *
 * WHY:
 *   captureFromCustomerAudioStream() previously used:
 *     const stream = new MicrophoneStream();
 *     stream.setStream(remoteAudioStream);  ← ScriptProcessorNode internally
 *   This produced irregular chunks on the main thread, causing:
 *     - Nova Sonic USER/ASSISTANT role misfires
 *     - Audio level spikes (9000-13000) after session restart
 *     - Agent unable to hear customer after restart
 *
 * HOW:
 *   - Takes the WebRTC MediaStream directly
 *   - Routes it through AudioWorkletNode (dedicated audio thread)
 *   - Produces consistent 4096-frame Float32Array chunks
 *   - Implements same AsyncIterable interface as MicrophoneStream
 *   - Compatible with novaSonicAdapter.js audio input loop
 */

const WORKLET_URL = new URL("../worklets/remote-stream-processor.js", import.meta.url);

export class RemoteStreamWorkletStream {
  constructor() {
    this._audioContext = null;
    this._sourceNode = null;
    this._workletNode = null;
    this._mediaStream = null;
    this._queue = [];
    this._resolve = null;
    this._destroyed = false;
  }

  /**
   * Factory — creates and fully initialises a RemoteStreamWorkletStream.
   * @param {AudioContext} audioContext - Shared AudioContext from AudioContextMgr
   * @param {MediaStream} remoteMediaStream - WebRTC remote audio stream
   * @returns {Promise<RemoteStreamWorkletStream>}
   */
  static async create(audioContext, remoteMediaStream) {
    const instance = new RemoteStreamWorkletStream();
    await instance._init(audioContext, remoteMediaStream);
    return instance;
  }

  async _init(audioContext, remoteMediaStream) {
    this._audioContext = audioContext;
    this._mediaStream = remoteMediaStream;

    // Register the worklet module (no-op if already registered)
    try {
      await this._audioContext.audioWorklet.addModule(WORKLET_URL);
    } catch (e) {
      if (!e.message?.includes("already")) throw e;
    }

    // Create source node from remote WebRTC stream
    this._sourceNode = this._audioContext.createMediaStreamSource(remoteMediaStream);

    // Create worklet node with consistent 4096-frame buffer
    this._workletNode = new AudioWorkletNode(
      this._audioContext,
      "remote-stream-processor",
      {
        processorOptions: { bufferSize: 4096 },
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [1],
      }
    );

    // Wire: remote stream source → worklet
    this._sourceNode.connect(this._workletNode);
    // Do NOT connect to destination — capture only, no playback duplication

    // Handle incoming audio chunks from the worklet thread
    this._workletNode.port.onmessage = (event) => {
      if (this._destroyed) return;
      const chunk = event.data.audioChunk;
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
   * Cleanly tears down the worklet and source node.
   * Does NOT stop the underlying MediaStream — Connect owns that lifecycle.
   */
  destroy() {
    if (this._destroyed) return;
    this._destroyed = true;

    if (this._resolve) {
      this._resolve({ value: undefined, done: true });
      this._resolve = null;
    }

    try { this._workletNode?.port.close(); } catch { /* ignore */ }
    try { this._workletNode?.disconnect(); } catch { /* ignore */ }
    try { this._sourceNode?.disconnect(); } catch { /* ignore */ }

    this._workletNode = null;
    this._sourceNode = null;
    this._mediaStream = null;
    this._queue = [];
  }
}
