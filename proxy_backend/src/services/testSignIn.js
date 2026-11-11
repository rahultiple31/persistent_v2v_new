// Temporary test sign-in, so the whole path can be tested before the identity
// provider's client exists. One Secrets Manager secret, created by hand in the console, is the switch, read
// every refreshMs:
//
//   the test password (12 characters or more)   on
//   "off", or no secret                          off; every test token stops working within refreshMs
//
// The secret is either plaintext (the password alone) or the console's key/value form with the key
// "password". A secret scheduled for deletion counts as no secret.
// A correct password gets an access token for 8 hours, signed with a key derived from the password, so
// every task accepts it, and a new password also ends every test session. The password is never logged.
// With the server-side sign-in (AUTH_MODE=bff) it gets a session cookie instead (sessionAuth.js), which
// carries keyId and so ends the same way.
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { errorFields } from "../logger.js";

export const TEST_ISSUER = "v2v-test-sign-in";
const MIN_PASSWORD_CHARS = 12;
const TOKEN_LIFETIME_MS = 8 * 60 * 60_000;
// No secret, or one scheduled for deletion: deleting the secret switches the test sign-in off at once, not
// at the end of the recovery window.
const SECRET_GONE = new Set(["ResourceNotFoundException", "InvalidRequestException"]);

const base64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const derive = (password) => createHmac("sha256", TEST_ISSUER).update(password).digest();

class TestSignInError extends Error {
  constructor(name, message) {
    super(message);
    this.name = name;
  }
}

function decodePart(part) {
  try {
    return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

/** The password in the secret: its plaintext, or the "password" key of a key/value secret (null: no such key). */
function passwordIn(secretString) {
  const text = String(secretString ?? "").trim();
  if (!text.startsWith("{")) return text;
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return text; // not key/value: a password that starts with "{"
  }
  return typeof value?.password === "string" ? value.password.trim() : null;
}

/**
 * @param {object} opts
 * @param {{send(command): Promise<any>}} opts.secrets - SecretsManagerClient
 * @param {string} opts.secretId - name or ARN
 */
export function createTestSignIn({ secrets, secretId, refreshMs = 30_000, logger, now = () => Date.now() }) {
  let key = null; // set while the switch is on
  let timer = null;
  let failing = false;
  let reported = null; // the last warning about the secret's value, so it is logged once

  function apply(secretString) {
    const password = passwordIn(secretString);
    let next = null;
    let problem = null;
    if (password == null) {
      problem = 'the test sign-in secret has no "password" key: test sign-in stays off';
    } else if (password && password.toLowerCase() !== "off") {
      if (password.length >= MIN_PASSWORD_CHARS) next = derive(password);
      else problem = `test sign-in password is shorter than ${MIN_PASSWORD_CHARS} characters: test sign-in stays off`;
    }
    if (problem && problem !== reported) logger.warn(problem, { secretId });
    reported = problem;
    if (Boolean(next) !== Boolean(key)) logger.info("test sign-in switched", { secretId, on: Boolean(next) });
    else if (next && !next.equals(key)) logger.info("test sign-in password changed: earlier test sessions end", { secretId });
    key = next;
  }

  async function refresh() {
    try {
      const result = await secrets.send(new GetSecretValueCommand({ SecretId: secretId }));
      apply(result?.SecretString);
      if (failing) logger.info("test sign-in secret readable again", { secretId });
      failing = false;
    } catch (err) {
      if (SECRET_GONE.has(err?.name)) {
        apply("off");
        failing = false;
      } else {
        // A failed read keeps the last state, so a Secrets Manager hiccup never signs testers out.
        if (!failing) logger.warn("could not read the test sign-in secret; keeping the last state", { secretId, ...errorFields(err) });
        failing = true;
      }
    }
    return Boolean(key);
  }

  /** True when the switch is on and `password` is the test password. */
  function check(password) {
    return Boolean(key) && typeof password === "string" && timingSafeEqual(derive(password), key);
  }

  return {
    get on() {
      return key != null;
    },
    /** Identifies the current password without revealing it; null while off. */
    get keyId() {
      return key ? createHash("sha256").update(key).digest("base64url").slice(0, 16) : null;
    },
    sessionMs: TOKEN_LIFETIME_MS,
    /** Reads the parameter now and every refreshMs after. Never throws. */
    start() {
      if (timer) return Promise.resolve(Boolean(key));
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

    check,

    /** An access token for `name`, or null when the switch is off or the password is wrong. */
    signIn({ password, name }) {
      if (!check(password)) return null;
      const iat = Math.floor(now() / 1000);
      const exp = iat + TOKEN_LIFETIME_MS / 1000;
      const data = `${base64url({ alg: "HS256", typ: "JWT" })}.${base64url({ iss: TEST_ISSUER, sub: `test:${name}`, iat, exp })}`;
      return { accessToken: `${data}.${createHmac("sha256", key).update(data).digest("base64url")}`, expiresAt: exp * 1000 };
    },

    /** True for tokens this module issues (whether or not they are still valid). */
    isTestToken(token) {
      const parts = String(token).split(".");
      return parts.length === 3 && decodePart(parts[1])?.iss === TEST_ISSUER;
    },

    async verify(token) {
      if (!key) throw new TestSignInError("TestSignInOffError", "Test sign-in is switched off");
      const [header, payload, signature] = String(token).split(".");
      const expected = createHmac("sha256", key).update(`${header}.${payload}`).digest();
      const actual = Buffer.from(signature ?? "", "base64url");
      if (decodePart(header)?.alg !== "HS256" || actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
        throw new TestSignInError("TestTokenInvalidError", "Test token signature is not valid");
      }
      const claims = decodePart(payload);
      if (!claims || typeof claims.sub !== "string" || !(claims.exp * 1000 > now())) {
        throw new TestSignInError("TestTokenExpiredError", "Test token has expired");
      }
      return { userId: claims.sub, expiresAt: claims.exp * 1000 };
    },
  };
}

/** The proxy's verifier with test tokens checked by testSignIn, and every other token by `verifier`. */
export function withTestSignIn(verifier, testSignIn) {
  return {
    hydrate: () => verifier.hydrate(),
    verify: (token) => (testSignIn.isTestToken(token) ? testSignIn.verify(token) : verifier.verify(token)),
  };
}
