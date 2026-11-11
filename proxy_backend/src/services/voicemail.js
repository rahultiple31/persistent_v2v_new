// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Voicemail playback. VMX3 saves each voicemail in its recordings bucket as
// <year>/<month>/<day>/<contact ID of the call>.wav (vmx3_recording_processor.py) and puts that name on the
// voicemail task as the vmx3_recording_key attribute. The page sends the name; the proxy reads the file from
// S3 with the task role and streams it back, so the browser needs no S3 access and no signed link.
//
// The name comes from the page, so only names of exactly that form are read, and only from the one bucket.
import { pipeline } from "node:stream/promises";
import { GetObjectCommand } from "@aws-sdk/client-s3";

const RECORDING_KEY =
  /^\d{4}\/(0[1-9]|1[0-2])\/(0[1-9]|[12]\d|3[01])\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.wav$/i;

export const isRecordingKey = (key) => typeof key === "string" && RECORDING_KEY.test(key);

/**
 * Reads one recording and streams it to `res`. Never throws: returns what happened, for the log.
 *
 * @returns {Promise<{ status: number, bytes?: number, error?: string, cause?: Error }>} status 499 = the
 *   browser went away first.
 */
export async function sendRecording({ s3, bucket, key, res, sendJson }) {
  // Stop reading from S3 if the browser goes away (agent closed the task, page reloaded).
  const abort = new AbortController();
  const onClose = () => {
    if (!res.writableFinished) abort.abort();
  };
  res.once("close", onClose);
  try {
    let object;
    try {
      object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }), { abortSignal: abort.signal });
    } catch (err) {
      if (abort.signal.aborted) return { status: 499 };
      // Without s3:ListBucket, S3 answers a missing file with AccessDenied too, so a 502 can also mean the
      // file does not exist; the log has S3's answer.
      const notFound = err?.name === "NoSuchKey" || err?.$metadata?.httpStatusCode === 404;
      const result = notFound ? { status: 404, error: "recordingNotFound" } : { status: 502, error: "recordingUnavailable" };
      sendJson(res, result.status, { error: result.error });
      return { ...result, cause: err };
    }

    res.writeHead(200, {
      // Always WAV (VMX3 writes .wav only); S3's stored type is not trusted.
      "Content-Type": "audio/wav",
      ...(Number.isFinite(object.ContentLength) ? { "Content-Length": object.ContentLength } : {}),
      // A caller's message: never kept in the browser's or any other cache.
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Cross-Origin-Resource-Policy": "same-origin",
    });
    try {
      await pipeline(object.Body, res);
    } catch (err) {
      // The headers are sent, so the browser sees a cut download; pipeline has closed both ends. A premature
      // close is the browser leaving; anything else is the read from S3 failing (stall, reset).
      return err?.code === "ERR_STREAM_PREMATURE_CLOSE" ? { status: 499 } : { status: 502, error: "recordingStreamFailed", cause: err };
    }
    return { status: 200, bytes: object.ContentLength };
  } finally {
    res.off("close", onClose);
  }
}
