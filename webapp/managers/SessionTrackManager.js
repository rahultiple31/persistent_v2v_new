// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { LOGGER_PREFIX } from "../constants";
import { isStringUndefinedNullEmpty } from "../utils/commonUtility";

// Enum for track types
export const TrackType = {
  FILE: "FILE",
  MIC: "MIC",
  POLLY: "POLLY",
  SILENT: "SILENT",
};

export class SessionTrackManager {
  constructor(peerConnection, audioContext) {
    this.peerConnection = peerConnection;
    this.audioContext = audioContext;
    this.currentTrackType = null;
    this.currentTrack = null;
    this.micStream = null;
    this.silentTrack = null;
  }

  // Create a silent audio track
  createSilentTrack() {
    const silentStream = this.audioContext.createMediaStreamDestination().stream;
    const silentTrack = silentStream.getAudioTracks()[0];
    return silentTrack;
  }

  // Get microphone access and create track
  async createMicTrack(microphoneConstraints) {
    const micStream = await navigator.mediaDevices.getUserMedia(microphoneConstraints);

    const micStreamAudioTrack = micStream.getAudioTracks()[0];
    return micStreamAudioTrack;
  }

  // Create track from file
  createFileTrack(inputFilePath) {
    if (isStringUndefinedNullEmpty(inputFilePath)) throw new Error("Invalid input file path");

    const audio = new Audio(inputFilePath);
    audio.loop = false;
    audio.crossOrigin = "anonymous";
    audio.play();

    const mediaStreamDestination = this.audioContext.createMediaStreamDestination();
    const mediaElementSource = this.audioContext.createMediaElementSource(audio);
    mediaElementSource.connect(mediaStreamDestination);
    const fileStream = mediaStreamDestination.stream;

    const fileStreamAudioTrack = fileStream.getAudioTracks()[0];
    return fileStreamAudioTrack;
  }

  // Replace the current track with a new one
  async replaceTrack(newTrack, newTrackType) {
    // Only skip if it is literally the SAME track object AND same type.
    // Do NOT skip when the type matches but the track is a different object â€”
    // this happens on session restart where a new AudioStreamManager creates a
    // new destination track of the same POLLY type.
    if (this.currentTrackType === newTrackType && this.currentTrack && this.currentTrack === newTrack) {
      return;
    }

    // Clean up existing track if necessary.
    // NOTE: cleanupCurrentTrack() intentionally does NOT stop POLLY tracks â€”
    // they are owned by AudioStreamManager whose Web Audio graph must stay
    // connected until the new track is wired.  Stopping them here would sever
    // the graph and cause packetsCount=0 (silence to customer).
    await this.cleanupCurrentTrack();

    try {
      this.currentTrackType = newTrackType;
      this.currentTrack = newTrack;
      // CRITICAL: must be awaited so that audioSender.replaceTrack() completes
      // before any caller proceeds.  Previously this was fire-and-forget, so
      // async WebRTC errors were silently swallowed as unhandled rejections and
      // the sender track was never actually updated â€” causing packetsCount=0.
      await this.replaceAudioSenderTrack(newTrack);
      return;
    } catch (error) {
      console.error(`${LOGGER_PREFIX} - replaceTrack - Error replacing track:`, error);
      // Fall back to a silent track. `this.silentTrack` was only ever null here
      // â€” createSilentTrack() returns a track but nothing assigned it â€” so this
      // path used to call replaceAudioSenderTrack(null). That happens to mute
      // the sender, but only by accident, and it left dispose() unable to stop
      // anything. Create the track properly.
      if (!this.silentTrack) {
        this.silentTrack = this.createSilentTrack();
      }
      this.currentTrackType = TrackType.SILENT;
      this.currentTrack = this.silentTrack;
      await this.replaceAudioSenderTrack(this.silentTrack);
      return;
    }
  }

  // Clean up the current track
  async cleanupCurrentTrack() {
    if (this.currentTrack) {
      // Do NOT stop POLLY tracks â€” they are owned and managed by
      // AudioStreamManager.  The Web Audio API graph (bufferSource â†’
      // gainNode â†’ mediaStreamDestination) feeds this track; stopping it
      // here severs that graph and produces packetsCount=0 (silence to
      // customer) even after the new track is wired via replaceTrack.
      // AudioStreamManager.dispose() is responsible for track lifecycle.
      if (this.currentTrackType !== TrackType.POLLY) {
        this.currentTrack.stop();
      }
      if (this.currentTrackType === TrackType.MIC && this.micStream) {
        this.micStream.getTracks().forEach((track) => track.stop());
        this.micStream = null;
      }
    }
  }

  // Get current track info
  getCurrentTrackInfo() {
    return {
      type: this.currentTrackType,
      track: this.currentTrack,
      isActive: this.currentTrack ? this.currentTrack.enabled : false,
    };
  }

  // Enable/disable the current track
  setTrackEnabled(enabled) {
    if (this.currentTrack) {
      this.currentTrack.enabled = enabled;
    }
  }

  // Clean up resources
  async dispose() {
    await this.cleanupCurrentTrack();
    if (this.silentTrack) {
      this.silentTrack.stop();
    }
    console.info(`${LOGGER_PREFIX} - dispose - SessionTrackManager disposed`);
  }

  //Replace Audio Sender Track in PeerConnection
  async replaceAudioSenderTrack(newTrack) {
    if (this.peerConnection == null) {
      console.error(`${LOGGER_PREFIX} - replaceAudioSenderTrack - peerConnection is null`);
      return;
    }
    const senders = this.peerConnection.getSenders();
    if (senders == null || senders.length === 0) {
      console.error(`${LOGGER_PREFIX} - replaceAudioSenderTrack - senders is null or empty`);
      return;
    }

    // Use null-safe sender.track access: when a previously stopped track was
    // assigned to a sender, sender.track may be null in some browser
    // implementations, causing .kind to throw a TypeError that was previously
    // silently swallowed (replaceAudioSenderTrack was not awaited).
    const audioSender = senders.find((sender) => sender.track?.kind === "audio");

    if (audioSender == null) {
      console.info(`${LOGGER_PREFIX} - replaceAudioSenderTrack - no audio sender found, adding new track`);
      try {
        this.peerConnection.addTrack(newTrack);
      } catch (e) {
        console.error(`${LOGGER_PREFIX} - replaceAudioSenderTrack - addTrack failed:`, e);
      }
      return;
    }

    console.info(`${LOGGER_PREFIX} - replaceAudioSenderTrack - replacing existing track`);
    try {
      await audioSender.replaceTrack(newTrack);
      console.info(`${LOGGER_PREFIX} - replaceAudioSenderTrack - track replaced successfully`);
    } catch (err) {
      console.error(`${LOGGER_PREFIX} - replaceAudioSenderTrack - replaceTrack() failed:`, err);
      // Fallback: add as a new sender if replace is not supported in the
      // current peer-connection state (e.g. after a WebRTC refresh).
      //
      // addTrack() ADDS a sender, it does not replace one. Calling it while the
      // existing sender still holds a live track leaves TWO live audio senders,
      // so the customer receives the old track and the new one mixed together â€”
      // e.g. the agent's raw microphone alongside the translation. Silence the
      // existing sender first so the fallback can only ever produce one audible
      // outbound stream.
      try {
        await audioSender.replaceTrack(null).catch(() => {
          // Some implementations reject replaceTrack(null); disabling the track
          // achieves the same thing for our purposes.
          if (audioSender.track) audioSender.track.enabled = false;
        });
      } catch {
        if (audioSender.track) audioSender.track.enabled = false;
      }

      try {
        this.peerConnection.addTrack(newTrack);
        console.info(`${LOGGER_PREFIX} - replaceAudioSenderTrack - addTrack fallback succeeded`);
      } catch (e2) {
        console.error(`${LOGGER_PREFIX} - replaceAudioSenderTrack - addTrack fallback also failed:`, e2);
      }
    }
  }
}