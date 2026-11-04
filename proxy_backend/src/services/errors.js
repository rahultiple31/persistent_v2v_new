// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

// Upstream error codes whose messages are safe and useful to show the webapp. Anything else (for example
// AccessDeniedException, whose message names the task role and account) is replaced with a generic
// message; the full message is still logged server-side.
const PASS_THROUGH_CODES = new Set([
  "validationException",
  "modelStreamErrorException",
  "modelTimeoutException",
  "throttlingException",
  "serviceUnavailableException",
  "internalServerException",
  "limitExceededException",
  "badRequestException",
]);

const GENERIC_MESSAGE = "The upstream AWS request failed";

/** "ValidationException" -> "validationException", the shape the Nova Sonic event stream uses. */
export function toErrorCode(err) {
  const name = typeof err?.name === "string" && err.name ? err.name : "Error";
  return name.charAt(0).toLowerCase() + name.slice(1);
}

export function clientErrorMessage(code, message) {
  return PASS_THROUGH_CODES.has(code) && typeof message === "string" && message ? message : GENERIC_MESSAGE;
}
