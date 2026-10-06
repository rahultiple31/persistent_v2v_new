// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import MicrophoneStream from "microphone-stream";

export async function createMicrophoneStream(microphoneConstraints) {
  const micStream = new MicrophoneStream();
  micStream.setStream(await navigator.mediaDevices.getUserMedia(microphoneConstraints));
  return micStream;
}
