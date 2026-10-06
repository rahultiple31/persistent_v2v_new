// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 
import { LOGGER_PREFIX } from "../constants";
 
const INTERACTION_EVENTS = ["click", "touchstart", "keydown"];
 
// AudioWorklet modules used when translation starts, loaded as soon as the AudioContext exists so Start
// finds them already loaded instead of downloading them.
const WORKLET_URLS = [
  new URL("../worklets/mic-processor.js", import.meta.url),
  new URL("../worklets/remote-stream-processor.js", import.meta.url),
];
 
// SPDX-License-Identifier: MIT-0
export class AudioContextManager {
  constructor() {
    this.audioContext = new AudioContext();
    this.interactionPromise = null;
    this.isWaitingForInteraction = this.audioContext.state === "suspended"; // AudioContext is suspended until the user makes an interaction with the webpage
    this.setupUserInteractionListeners();
    this.preloadWorklets();
  }
 
  // Loads the worklet modules in the background; if this fails they simply load at Start as before.
  preloadWorklets() {
    for (const url of WORKLET_URLS) {
      this.audioContext.audioWorklet.addModule(url).catch((error) => {
        console.warn(`${LOGGER_PREFIX} - worklet preload failed; it will load when translation starts`, error);
      });
    }
  }
 
  //add event listeners to detect if the user has interacted with webpage
  setupUserInteractionListeners() {
    const handleInteraction = async () => {
      console.info(`${LOGGER_PREFIX} - User interaction detected`);
      if (this.isWaitingForInteraction) {
        await this.audioContext.resume();
        console.info(`${LOGGER_PREFIX} - AudioContext state is [${this.audioContext.state}]`);
        // Remove listeners once we've successfully resumed
        this.removeUserInteractionListeners();
      }
    };
 
    this.boundHandleInteraction = handleInteraction.bind(this);
    console.info(`${LOGGER_PREFIX} - Setting up user interaction listeners`);
    INTERACTION_EVENTS.forEach((eventType) => {
      document.addEventListener(eventType, this.boundHandleInteraction, { once: true });
    });
  }
 
  //once interaction is detected, remove the event listeners
  removeUserInteractionListeners() {
    INTERACTION_EVENTS.forEach((eventType) => {
      document.removeEventListener(eventType, this.boundHandleInteraction);
    });
    this.isWaitingForInteraction = false;
  }
 
  promptForInteraction() {
    if (this.interactionPromise) {
      return this.interactionPromise;
    }
 
    this.interactionPromise = new Promise((resolve) => {
      // Create modal overlay
      const overlay = document.createElement("div");
      overlay.style.cssText = `
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: rgba(0, 0, 0, 0.7);
            display: flex;
            align-items: center;
            justify-content: center;
            z-index: 1000;
        `;
 
      // Create prompt container
      const promptContainer = document.createElement("div");
      promptContainer.style.cssText = `
            background: white;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            max-width: 80%;
        `;
 
      // Create button
      const button = document.createElement("button");
      button.textContent = "Click to Enable Audio";
      button.style.cssText = `
            padding: 10px 20px;
            font-size: 16px;
            cursor: pointer;
            background: #007bff;
            color: white;
            border: none;
            border-radius: 4px;
            margin-top: 10px;
        `;
 
      const handleInteraction = async () => {
        try {
          await this.audioContext.resume();
          console.info(`${LOGGER_PREFIX} - AudioContext state is [${this.audioContext.state}]`);
          this.removeUserInteractionListeners();
          overlay.remove();
          resolve();
        } catch (error) {
          console.error(`${LOGGER_PREFIX} - Failed to resume AudioContext:`, error);
        }
      };
 
      button.addEventListener("click", handleInteraction);
      promptContainer.appendChild(button);
      overlay.appendChild(promptContainer);
      document.body.appendChild(overlay);
    });
 
    return this.interactionPromise;
  }
 
  async getAudioContext() {
    if (this.audioContext?.state === "suspended") {
      if (this.isWaitingForInteraction) {
        await this.promptForInteraction();
      } else {
        await this.audioContext.resume(); // AudioContext can resume if the user has already interacted with the webpage
      }
    }
 
    console.info(`${LOGGER_PREFIX} - AudioContext state is [${this.audioContext.state}]`);
    return this.audioContext;
  }
 
  async resume() {
    if (this.audioContext?.state === "suspended") {
      await this.audioContext.resume();
    }
  }
 
  async suspend() {
    if (this.audioContext?.state === "running") {
      await this.audioContext.suspend();
    }
  }
 
  async dispose() {
    if (this.audioContext) {
      await this.audioContext.close();
    }
  }
 
  getState() {
    return this.audioContext?.state;
  }
 
  getActualSampleRate() {
    // Return the rate of the context the capture worklets ACTUALLY run on.
    //
    // This used to spin up a throwaway `new AudioContext()` and report ITS rate.
    // That reports the current hardware default, which is not necessarily the
    // rate of the long-lived shared context - the two diverge as soon as the
    // default changes (plugging in a headset, switching output device), and the
    // shared context keeps whatever rate it was constructed with for its whole
    // lifetime. The returned value is passed to Nova Sonic as `inputSampleRate`
    // and used by encodeMicChunkToNovaPcm16() to resample the mic down to
    // 16 kHz, so a mismatch resamples by the wrong ratio and feeds Nova Sonic
    // pitch- and tempo-shifted speech. That degrades its transcription, which
    // makes it far more likely to echo the source language instead of
    // translating.
    if (this.audioContext?.sampleRate) return this.audioContext.sampleRate;
 
    // No shared context yet - fall back to probing the hardware default.
    const tmpAudioContext = new AudioContext();
    const actualSampleRate = tmpAudioContext.sampleRate;
    tmpAudioContext.close();
    return actualSampleRate;
  }
}