// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

/**
 * JSON-lines logger for CloudWatch.
 *
 * Never pass tokens, transcripts, translated text or audio in `fields`: log metadata only
 * (ids, sizes, durations, error names). Calls carry employee and caller personal data.
 */
export function createLogger(level = "info", sink = process.stdout) {
  const min = LEVELS[level] ?? LEVELS.info;
  const write = (lvl, msg, fields) => {
    if (LEVELS[lvl] < min) return;
    sink.write(`${JSON.stringify({ time: new Date().toISOString(), level: lvl, msg, ...fields })}\n`);
  };
  return {
    debug: (msg, fields) => write("debug", msg, fields),
    info: (msg, fields) => write("info", msg, fields),
    warn: (msg, fields) => write("warn", msg, fields),
    error: (msg, fields) => write("error", msg, fields),
  };
}

/** Error details safe to log: the name, message, code and HTTP status, never the request. */
export function errorFields(err) {
  return {
    errorName: err?.name,
    errorMessage: err?.message,
    // Network failures are plain Errors; the code (ECONNRESET, ETIMEDOUT, ERR_HTTP2_...) says which.
    errorCode: err?.code,
    errorStatus: err?.$metadata?.httpStatusCode,
  };
}
