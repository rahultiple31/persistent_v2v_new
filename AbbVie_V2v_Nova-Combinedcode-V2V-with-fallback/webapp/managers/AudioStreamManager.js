// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { LOGGER_PREFIX } from "../constants";
import { isStringUndefinedNullEmpty } from "../utils/commonUtility";

export class AudioStreamManager {
  constructor(audioElement, audioContext) {
    this.audioContext = audioContext;
    this.mediaStreamDestination = this.audioContext.createMediaStreamDestination();
    this.audioElement = audioElement;

    // Set up permanent stream
    this.audioElement.srcObject = this.mediaStreamDestination.stream;
    // Store the audio track
    this.audioTrack = this.mediaStreamDestination.stream.getAudioTracks()[0];
    this.audioElement.play();

    // Queue for managing multiple audio requests
    this.audioQueue = [];
    this.isPlaying = false;

    this.audioFeedbackNode = null;
    this.shouldPlayAudioFeedback = false;

    this.microphoneStream = null;
    this.microphoneGain = null;
    this.isMicrophoneActive = false;
    this.activeMicrophoneDeviceId;

    this.customFeedbackBuffer = null;

    // Set by dispose(). Any callback still in flight (bufferSource.onended,
    // a pending playAudioBuffer) checks this so it cannot resurrect audio on a
    // manager the app has already let go of.
    this.isDisposed = false;
  }

  async startMicrophone(microphoneConstraints) {
    try {
      const microphoneDeviceId = microphoneConstraints?.audio?.deviceId;
      if (microphoneDeviceId == null) throw new Error("Microphone deviceId not provided!");

      if (this.isMicrophoneActive) {
        if (this.activeMicrophoneDeviceId === microphoneDeviceId) {
          console.info(`${LOGGER_PREFIX} - Microphone [${microphoneDeviceId}] already active`);
          return;
        } else {
          this.stopMicrophone();
        }
      }

      // Get microphone stream
      this.activeMicrophoneDeviceId = microphoneDeviceId;
      const stream = await navigator.mediaDevices.getUserMedia(microphoneConstraints);

      // Create source from microphone
      const micSource = this.audioContext.createMediaStreamSource(stream);

      // Create gain node for microphone volume control.
      //
      // Start SILENT, not at 1.0. This node mixes the raw microphone into
      // mediaStreamDestination Ã¢â‚¬â€ the same destination whose track is sent to
      // the customer over WebRTC Ã¢â‚¬â€ so any gain here is untranslated speech on
      // the wire, and none of the translation safety checks can suppress it
      // (they gate playAudioBuffer, not this connection). Opening at full gain
      // meant a window of raw audio before setMicrophoneVolume() was applied,
      // and full gain permanently if that call was ever skipped or passed NaN.
      this.microphoneGain = this.audioContext.createGain();
      this.microphoneGain.gain.setValueAtTime(0, this.audioContext.currentTime);

      // Connect microphone through gain to destination
      micSource.connect(this.microphoneGain);
      this.microphoneGain.connect(this.mediaStreamDestination);

      // Store stream for cleanup
      this.microphoneStream = stream;
      this.isMicrophoneActive = true;

      console.info(`${LOGGER_PREFIX} - Microphone started successfully`);
    } catch (error) {
      console.error(`${LOGGER_PREFIX} - Error starting microphone:`, error);
      throw error;
    }
  }

  stopMicrophone() {
    if (!this.isMicrophoneActive) return;

    if (this.microphoneStream) {
      // Stop all audio tracks
      this.microphoneStream.getTracks().forEach((track) => track.stop());
      this.microphoneStream = null;
    }

    if (this.microphoneGain) {
      this.microphoneGain.disconnect();
      this.microphoneGain = null;
    }

    this.isMicrophoneActive = false;
    this.activeMicrophoneDeviceId = null;
    console.info(`${LOGGER_PREFIX} - Microphone stopped`);
  }

  setMicrophoneVolume(volume) {
    if (!this.microphoneGain) return;
    // NaN fails every comparison, so the old `volume >= 0 && volume <= 1` guard
    // turned a bad value into a silent no-op that left the previous gain in
    // place. Callers pass parseFloat(slider.value), which yields NaN whenever
    // the slider is empty or non-numeric. Treat anything invalid as 0: for a
    // node wired to the customer's outbound stream, the safe failure is silence,
    // not whatever gain happened to be set.
    const safeVolume = Number.isFinite(volume) ? Math.min(Math.max(volume, 0), 1) : 0;
    if (safeVolume !== volume) {
      console.warn(
        `${LOGGER_PREFIX} - setMicrophoneVolume: invalid volume ${volume} Ã¢â‚¬â€ using ${safeVolume}`
      );
    }
    this.microphoneGain.gain.setValueAtTime(safeVolume, this.audioContext.currentTime);
  }

  isMicrophoneEnabled() {
    return this.isMicrophoneActive;
  }

  async loadAudioFile(filePath) {
    try {
      if (isStringUndefinedNullEmpty(filePath)) throw new Error("Invalid file path");

      const response = await fetch(filePath);
      let reader = response.body.getReader();
      let chunks = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
      }
      let blob = new Blob(chunks);
      let arrayBuffer = await blob.arrayBuffer();
      const audioBuffer = await this.audioContext.decodeAudioData(arrayBuffer);

      return audioBuffer;
    } catch (error) {
      console.error(`${LOGGER_PREFIX} - Error loading audio file:`, error);
      throw error;
    }
  }

  // Create audio feedback
  createAudioFeedback() {
    if (this.customFeedbackBuffer) {
      const audioFeedback = this.audioContext.createBufferSource();
      audioFeedback.buffer = this.customFeedbackBuffer;
      audioFeedback.loop = true;

      // Add gain node to control volume
      const gainNode = this.audioContext.createGain();
      gainNode.gain.value = 0.05; // Adjust volume here (0-1)

      audioFeedback.connect(gainNode);
      gainNode.connect(this.mediaStreamDestination);
      return audioFeedback;
    }

    const bufferSize = 2 * this.audioContext.sampleRate;
    const audioFeedbackBuffer = this.audioContext.createBuffer(1, bufferSize, this.audioContext.sampleRate);
    const output = audioFeedbackBuffer.getChannelData(0);

    for (let i = 0; i < bufferSize; i++) {
      output[i] = Math.random() * 2 - 1;
    }

    const audioFeedback = this.audioContext.createBufferSource();
    audioFeedback.buffer = audioFeedbackBuffer;
    audioFeedback.loop = true;

    // Add gain node to control volume
    const gainNode = this.audioContext.createGain();
    gainNode.gain.value = 0.005; // Adjust volume here (0-1)

    audioFeedback.connect(gainNode);
    gainNode.connect(this.mediaStreamDestination);

    console.info(`${LOGGER_PREFIX} - createAudioFeedback - white noise:`, audioFeedback);
    return audioFeedback;
  }

  startAudioFeedback() {
    //console.info(`${LOGGER_PREFIX} - startAudioFeedback`);
    if (this.isDisposed) return; // never resurrect audio after dispose()
    if (!this.audioFeedbackNode) {
      this.audioFeedbackNode = this.createAudioFeedback();
      this.audioFeedbackNode.start();
    }
  }

  stopAudioFeedback() {
    if (this.audioFeedbackNode) {
      //console.info(`${LOGGER_PREFIX} - stopAudioFeedback`);
      this.audioFeedbackNode.stop();
      this.audioFeedbackNode = null;
    }
  }

  async enableAudioFeedback(filePath = null) {
    if (filePath != null) {
      try {
        this.customFeedbackBuffer = await this.loadAudioFile(filePath);
      } catch (error) {
        console.error(`${LOGGER_PREFIX} - Failed to load custom audio feedback:`, error);
        this.customFeedbackBuffer = null;
        // Continue with default white noise
      }
    } else {
      this.customFeedbackBuffer = null;
    }

    console.info(`${LOGGER_PREFIX} - enableAudioFeedback`);
    this.shouldPlayAudioFeedback = true;
    if (!this.isPlaying) {
      this.startAudioFeedback();
    }
  }

  disableAudioFeedback() {
    console.info(`${LOGGER_PREFIX} - disableAudioFeedback`);
    this.shouldPlayAudioFeedback = false;
    this.stopAudioFeedback();
  }

  // Getter for the audio track
  getAudioTrack() {
    return this.audioTrack;
  }

  async playAudio(audioData, volume = 1.0) {
    return new Promise(async (resolve, reject) => {
      try {
        const audioDataArray = await audioData.transformToByteArray();
        const audioBuffer = await this.audioContext.decodeAudioData(audioDataArray.buffer);

        // Add to queue
        this.audioQueue.push({
          buffer: audioBuffer,
          volume: volume,
          resolve: resolve,
        });

        // Start processing queue if not already playing
        if (!this.isPlaying) {
          this.processQueue();
        }
      } catch (error) {
        reject(error);
      }
    });
  }

  async playAudioBuffer(audioDataArray, volume = 1.0) {
    // The Translate+Polly fallback can resolve after the call has ended;
    // enqueueing then would play audio into a disposed manager.
    if (this.isDisposed) return;
    return new Promise(async (resolve, reject) => {
      try {
        const audioBuffer = await this.audioContext.decodeAudioData(audioDataArray.buffer);

        // Add to queue
        this.audioQueue.push({
          buffer: audioBuffer,
          volume: volume,
          resolve: resolve,
        });

        // Start processing queue if not already playing
        if (!this.isPlaying) {
          this.processQueue();
        }
      } catch (error) {
        reject(error);
      }
    });
  }

  async processQueue() {
    if (this.isDisposed) {
      this.audioQueue = [];
      this.isPlaying = false;
      return;
    }
    if (this.audioQueue.length === 0) {
      this.isPlaying = false;
      // Start audio feedback when queue is empty
      if (this.shouldPlayAudioFeedback) {
        this.startAudioFeedback();
      }
      return;
    }

    // Stop audio feedback when there's something to play
    this.stopAudioFeedback();

    this.isPlaying = true;
    const current = this.audioQueue.shift();

    // Create and set up source
    const bufferSource = this.audioContext.createBufferSource();
    bufferSource.buffer = current.buffer;

    // Create gain node for volume control
    const gainNode = this.audioContext.createGain();
    gainNode.gain.value = current.volume; // Set the volume (0.0 to 1.0)

    bufferSource.connect(gainNode);
    gainNode.connect(this.mediaStreamDestination);

    //bufferSource.connect(this.mediaStreamDestination);

    // Handle completion
    bufferSource.onended = () => {
      current.resolve();
      this.processQueue();
    };

    // Start playing
    bufferSource.start();
  }

  async resume() {
    if (this.audioContext.state === "suspended") {
      await this.audioContext.resume();
    }
  }

  async suspend() {
    if (this.audioContext.state === "running") {
      await this.audioContext.suspend();
    }
  }

  clearQueue() {
    this.audioQueue = [];
  }

  getState() {
    return {
      contextState: this.audioContext.state,
      queueLength: this.audioQueue.length,
      isPlaying: this.isPlaying,
      currentTime: this.audioContext.currentTime,
    };
  }

  //Clean up resources
  async dispose() {
    console.info(`${LOGGER_PREFIX} - dispose - AudioStreamManager disposed`);
    // Mark disposed BEFORE stopping anything.
    //
    // processQueue() re-arms the comfort noise whenever the queue drains:
    //   if (this.audioQueue.length === 0) { ... if (this.shouldPlayAudioFeedback)
    //   this.startAudioFeedback(); }
    // A bufferSource.onended callback that fires after dispose() therefore
    // restarted the looping white noise on a mediaStreamDestination that is
    // deliberately left alive â€” and because the caller nulls its reference to
    // this manager immediately afterwards, nothing could ever stop it again.
    // That is why background noise kept playing after the call ended, until a
    // page refresh. Clearing the flag and gating the restart fixes it.
    this.isDisposed = true;
    this.shouldPlayAudioFeedback = false;
    this.clearQueue();
    this.stopAudioFeedback();
    this.stopMicrophone();
    // Do NOT stop audioTrack here.
    // This track is the output of mediaStreamDestination and is wired to the
    // WebRTC RTCRtpSender via RTCSessionTrackManager.replaceTrack().  Stopping
    // it while the sender still holds a reference severs the Web Audio graph
    // before the new track can be substituted, producing a window of silence
    // (packetsCount=0) that persists even after the new track is wired.
    // RTCSessionTrackManager.cleanupCurrentTrack() skips POLLY tracks for the
    // same reason Ã¢â‚¬â€ the track lifecycle is managed by replaceTrack(), not here.
  }

  // Mute methods
  muteTrack() {
    if (this.audioTrack) {
      this.audioTrack.enabled = false;
    }
  }

  unmuteTrack() {
    if (this.audioTrack) {
      this.audioTrack.enabled = true;
    }
  }

  toggleTrackMute() {
    if (this.audioTrack) {
      this.audioTrack.enabled = !this.audioTrack.enabled;
    }
  }

  isTrackMuted() {
    return this.audioTrack ? !this.audioTrack.enabled : true;
  }

  muteAudioElement() {
    if (this.audioElement) {
      this.audioElement.muted = true;
    }
  }

  unmuteAudioElement() {
    if (this.audioElement) {
      this.audioElement.muted = false;
    }
  }

  toggleAudioElementMute() {
    if (this.audioElement) {
      this.audioElement.muted = !this.audioElement.muted;
    }
  }

  isAudioElementMuted() {
    return this.audioElement ? this.audioElement.muted : true;
  }
}