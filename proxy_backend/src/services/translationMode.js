// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { GetParameterCommand } from "@aws-sdk/client-ssm";
import { errorFields } from "../logger.js";

/**
 * fix 6: the forceBackupTranslation switch. Read from Parameter Store every refreshMs, so an
 * administrator can switch every call to the backup translation (Transcribe + Translate + Polly), and
 * back, without a deployment. The webapp asks for it through GET /api/translation-mode.
 *
 * Off unless the parameter's value is "true" (case and surrounding spaces ignored): a missing parameter,
 * or no parameter name configured, is off. A failed read keeps the last value, so a Parameter Store
 * hiccup never flips the calls.
 *
 * @param {object} opts
 * @param {{send(command): Promise<any>}|null} opts.ssm  SSM client, or null when the switch is not configured
 * @param {string|null} opts.parameterName
 */
export function createTranslationModeSource({ ssm, parameterName, refreshMs = 30_000, logger }) {
  const enabled = Boolean(ssm && parameterName);
  let forceBackup = false;
  let timer = null;
  let failing = false;
  let reportedMissing = false;

  async function refresh() {
    if (!enabled) return forceBackup;
    try {
      const result = await ssm.send(new GetParameterCommand({ Name: parameterName }));
      const next = String(result?.Parameter?.Value ?? "").trim().toLowerCase() === "true";
      if (next !== forceBackup) logger.info("translation mode changed", { parameterName, forceBackup: next });
      if (failing) logger.info("translation mode parameter readable again", { parameterName, forceBackup: next });
      forceBackup = next;
      failing = false;
      reportedMissing = false;
    } catch (err) {
      if (err?.name === "ParameterNotFound") {
        if (forceBackup) logger.info("translation mode changed", { parameterName, forceBackup: false, reason: "parameterNotFound" });
        else if (!reportedMissing) logger.info("translation mode parameter not found: backup switch is off", { parameterName });
        reportedMissing = true;
        forceBackup = false;
        failing = false;
      } else {
        if (!failing) {
          logger.warn("could not read the translation mode parameter; keeping the last value", {
            parameterName,
            forceBackup,
            ...errorFields(err),
          });
        }
        failing = true;
      }
    }
    return forceBackup;
  }

  return {
    get enabled() {
      return enabled;
    },
    /** Reads the parameter now and every refreshMs after. Never throws. */
    start() {
      if (!enabled || timer) return Promise.resolve(forceBackup);
      timer = setInterval(() => {
        refresh();
      }, refreshMs);
      timer.unref?.();
      return refresh();
    },
    stop() {
      clearInterval(timer);
      timer = null;
    },
    refresh,
    current() {
      return { forceBackup };
    },
  };
}
