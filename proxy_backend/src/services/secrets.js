// Values the proxy keeps in AWS Secrets Manager (AUTH_MODE=bff): the Ping client secret and the session key.
// Each is read at startup and again every refreshMs, so a new value is picked up within minutes without a
// deployment. A failed read keeps the last value, so a Secrets Manager hiccup never breaks sign-in.
// Values are never logged.
import { GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { errorFields } from "../logger.js";

/**
 * @param {object} opts
 * @param {{send(command): Promise<any>}} opts.client - SecretsManagerClient
 * @param {string} opts.secretId - name or ARN
 * @param {boolean} [opts.withPrevious] - also read the AWSPREVIOUS version (the session key, for rotation)
 * @param {number} [opts.refreshMs]
 * @param {number} [opts.retryMs] - while no value has been read yet
 */
export function createSecretSource({ client, secretId, withPrevious = false, refreshMs = 300_000, retryMs = 30_000, label, logger }) {
  let current = null;
  let previous = null;
  let started = false;
  let timer = null;
  let failing = false;
  let reading = null;

  async function read(stage) {
    try {
      const result = await client.send(new GetSecretValueCommand({ SecretId: secretId, VersionStage: stage }));
      return typeof result?.SecretString === "string" ? result.SecretString.trim() : null;
    } catch (err) {
      // A secret with a single version has no AWSPREVIOUS.
      if (stage === "AWSPREVIOUS" && err?.name === "ResourceNotFoundException") return null;
      throw err;
    }
  }

  async function refreshNow() {
    try {
      const [nextCurrent, nextPrevious] = await Promise.all([read("AWSCURRENT"), withPrevious ? read("AWSPREVIOUS") : null]);
      if (!nextCurrent) throw new Error("The secret has no text value");
      if (current && nextCurrent !== current) logger.info("secret changed", { secret: label });
      current = nextCurrent;
      previous = nextPrevious || null;
      if (failing) logger.info("secret readable again", { secret: label });
      failing = false;
    } catch (err) {
      if (!failing) logger.error("could not read a secret; keeping the last value", { secret: label, secretId, hasValue: current != null, ...errorFields(err) });
      failing = true;
    }
    schedule();
    return current != null;
  }

  function schedule() {
    if (!started) return;
    clearTimeout(timer);
    timer = setTimeout(refresh, current ? refreshMs : retryMs);
    timer.unref?.();
  }

  /** Reads now; calls made while a read is running share it. Never throws. */
  function refresh() {
    reading ??= refreshNow().finally(() => {
      reading = null;
    });
    return reading;
  }

  return {
    get current() {
      return current;
    },
    get previous() {
      return previous;
    },
    /** Reads now and then on a timer. Never throws: without a value the caller keeps running and retries. */
    start() {
      started = true;
      return refresh();
    },
    stop() {
      started = false;
      clearTimeout(timer);
      timer = null;
    },
    refresh,
  };
}
