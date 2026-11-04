// Encrypted cookies for the server-side sign-in (AUTH_MODE=bff, sessionAuth.js).
//
// The session lives in the agent's browser as a cookie that page scripts cannot read (HttpOnly), and only
// this server can read or change it: its content is encrypted and signed with AES-256-GCM under the session
// key from Secrets Manager. Both tasks hold the same key, so either one accepts a cookie the other made, and
// no session store is needed.
//
// Key rotation: new cookies are sealed with the current key (AWSCURRENT), and cookies sealed with the
// previous key (AWSPREVIOUS) are still accepted, so putting a new key value signs nobody out. Rotating twice
// in a row makes every existing cookie invalid.
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

const VERSION = "v1";
const IV_BYTES = 12;
const TAG_BYTES = 16;
// Rules from the OAuth browser-based apps standard (RFC 10017, 6.1.3.2): Secure, HttpOnly, Path=/, no Domain,
// and an "__Host-Http-" name, which browsers only accept when it is set that way over HTTPS by the server.
export const SESSION_COOKIE = "__Host-Http-v2v-session";
// The sign-in in progress (state, nonce, PKCE verifier), from /auth/login until Ping sends the agent back.
export const SIGN_IN_COOKIE = "__Host-Http-v2v-signin";

function deriveKey(secret) {
  const key = createHash("sha256").update(`v2v-session-key:${secret}`).digest();
  return { key, id: createHash("sha256").update(key).digest("base64url").slice(0, 8) };
}

/**
 * @param {object} opts
 * @param {() => Array<string|null|undefined>} opts.keys - the current key first, then the previous one
 */
export function createSealer({ keys }) {
  let cachedFrom = null;
  let cached = [];
  // Derived again only when a key value changes (the secret source re-reads them every few minutes).
  function derived() {
    const values = keys().filter((value) => typeof value === "string" && value.length > 0);
    const signature = values.join("\u0000");
    if (signature !== cachedFrom) {
      cachedFrom = signature;
      cached = values.map(deriveKey);
    }
    return cached;
  }

  return {
    /** False until the session key has been read: no cookie can be made or read. */
    get ready() {
      return derived().length > 0;
    },

    /** Encrypts `payload` (JSON) for the cookie called `name`. Throws when no key is loaded. */
    seal(name, payload) {
      const [current] = derived();
      if (!current) throw new Error("Session key not loaded");
      const iv = randomBytes(IV_BYTES);
      const cipher = createCipheriv("aes-256-gcm", current.key, iv);
      // The cookie's name is authenticated too, so one kind of cookie can never be passed off as the other.
      cipher.setAAD(Buffer.from(name));
      const body = Buffer.concat([cipher.update(JSON.stringify(payload), "utf8"), cipher.final(), cipher.getAuthTag()]);
      return [VERSION, current.id, iv.toString("base64url"), body.toString("base64url")].join(".");
    },

    /**
     * Decrypts a cookie value made by seal(). Returns { payload, stale } (stale: sealed with the previous key,
     * so it should be sealed again), or null when it is missing, damaged, forged or from an unknown key.
     */
    open(name, value) {
      if (typeof value !== "string") return null;
      const [version, keyId, ivText, bodyText] = value.split(".");
      if (version !== VERSION || !ivText || !bodyText) return null;
      const all = derived();
      const index = all.findIndex((candidate) => candidate.id === keyId);
      if (index < 0) return null;
      try {
        const iv = Buffer.from(ivText, "base64url");
        const body = Buffer.from(bodyText, "base64url");
        if (iv.length !== IV_BYTES || body.length <= TAG_BYTES) return null;
        const decipher = createDecipheriv("aes-256-gcm", all[index].key, iv);
        decipher.setAAD(Buffer.from(name));
        decipher.setAuthTag(body.subarray(body.length - TAG_BYTES));
        const text = Buffer.concat([decipher.update(body.subarray(0, body.length - TAG_BYTES)), decipher.final()]).toString("utf8");
        return { payload: JSON.parse(text), stale: index > 0 };
      } catch {
        return null;
      }
    },
  };
}

/** The cookies of a request, as a Map (the first value wins when a name repeats). */
export function parseCookies(header) {
  const cookies = new Map();
  for (const part of String(header || "").split(";")) {
    const index = part.indexOf("=");
    if (index < 0) continue;
    const name = part.slice(0, index).trim();
    if (name && !cookies.has(name)) cookies.set(name, part.slice(index + 1).trim());
  }
  return cookies;
}

/**
 * A Set-Cookie value. maxAgeSeconds 0 deletes the cookie. sameSite "Strict" for the session; "Lax" only for
 * the sign-in cookie, which must come along on the redirect back from Ping (a navigation from another site).
 */
export function cookieHeader(name, value, { maxAgeSeconds, sameSite = "Strict" }) {
  return `${name}=${value}; Path=/; Secure; HttpOnly; SameSite=${sameSite}; Max-Age=${Math.max(0, Math.floor(maxAgeSeconds))}`;
}

export function clearCookieHeader(name, sameSite = "Strict") {
  return cookieHeader(name, "", { maxAgeSeconds: 0, sameSite });
}
