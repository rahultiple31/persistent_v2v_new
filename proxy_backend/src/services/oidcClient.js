// The proxy's side of OpenID Connect with Ping (AUTH_MODE=bff). The proxy is a confidential client: every
// call to Ping's token and revocation endpoints carries the client secret in the Authorization header
// (HTTP Basic, the method the OAuth standard prefers, RFC 6749 2.3.1), and it is made from this server,
// never from the browser.
import https from "node:https";
import { JwtVerifier } from "aws-jwt-verify";
import { SimpleFetcher } from "aws-jwt-verify/https";
import { SimpleJwksCache } from "aws-jwt-verify/jwk";

// Every call to the identity provider looks up IPv4 addresses only. The VPC has no IPv6, and AbbVie's DNS
// answers the IPv6 (AAAA) question for Ping's names with SERVFAIL or not at all (tested 2026-10-27). The
// container's resolver (Alpine, musl) asks for both and then fails the whole lookup with EAI_AGAIN, even
// though the IPv4 answer is correct. Asking for IPv4 only sends just the A question.
const IPV4_ONLY = { family: 4 };
const MAX_RESPONSE_BYTES = 1024 * 1024;

/** A small fetch() over node:https with IPv4-only lookups. Network failures look like fetch's (TypeError + cause). */
export function ipv4Fetch(url, { method = "GET", headers = {}, body, signal } = {}) {
  return new Promise((resolve, reject) => {
    const fail = (err) => reject(signal?.aborted ? signal.reason : Object.assign(new TypeError("fetch failed"), { cause: err }));
    const req = https.request(url, { method, headers, signal, ...IPV4_ONLY }, (res) => {
      const chunks = [];
      let size = 0;
      res.on("data", (chunk) => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) req.destroy(new Error(`Response larger than ${MAX_RESPONSE_BYTES} bytes`));
        else chunks.push(chunk);
      });
      res.on("end", () => {
        const noBody = [204, 205, 304].includes(res.statusCode);
        resolve(new Response(noBody ? null : Buffer.concat(chunks), { status: res.statusCode, headers: { "content-type": res.headers["content-type"] ?? "" } }));
      });
      res.on("error", fail);
    });
    req.on("error", fail);
    if (body) req.write(body);
    req.end();
  });
}

export class OidcError extends Error {
  name = "OidcError";
  constructor(code, message, { status } = {}) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

// RFC 6749 2.3.1: the client ID and secret are form-encoded before they are joined and base64-encoded.
const formEncode = (value) => encodeURIComponent(value).replace(/%20/g, "+");
// aws-jwt-verify's errors are all named "Error"; their class says what was wrong.
const errorClass = (err) => (err?.name && err.name !== "Error" ? err.name : err?.constructor?.name) || "Error";

// fetch() reports every network failure as "TypeError: fetch failed"; its cause says which one, for example
// "ENOTFOUND getaddrinfo ENOTFOUND host" (name lookup), "ECONNREFUSED connect ECONNREFUSED ip:443", a TLS
// certificate error, or "UND_ERR_CONNECT_TIMEOUT". Logged so the network team can see the exact failure.
function networkCause(err) {
  let cause = err?.cause;
  if (Array.isArray(cause?.errors) && cause.errors.length) cause = cause.errors[0]; // several addresses tried
  return [cause?.code, cause?.message].filter(Boolean).join(" ");
}

/**
 * @param {object} oidc - config.bff.oidc
 * @param {object} deps
 * @param {{current: string|null, refresh(): Promise<unknown>}} deps.clientSecret - from services/secrets.js
 * @param {typeof fetch} [deps.fetchImpl]
 * @param {object} [deps.jwks] - tests: the key set, instead of downloading it from oidc.jwksUri
 */
export function createOidcClient(oidc, { clientSecret, fetchImpl = ipv4Fetch, jwks, timeoutMs = 8_000 }) {
  // The ID token: signed by Ping (keys from its JWKS), for this client, not expired (60 s allowed for clocks).
  // The key download uses IPv4-only lookups too.
  const idTokenVerifier = JwtVerifier.create(
    { issuer: oidc.issuer, audience: oidc.clientId, jwksUri: oidc.jwksUri, graceSeconds: 60 },
    { jwksCache: new SimpleJwksCache({ fetcher: new SimpleFetcher({ defaultRequestOptions: IPV4_ONLY }) }) },
  );
  if (jwks) idTokenVerifier.cacheJwks(jwks);

  async function call(url, init) {
    try {
      return await fetchImpl(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    } catch (err) {
      const cause = networkCause(err);
      throw new OidcError("unreachable", `The identity provider could not be reached (${errorClass(err)}${cause ? `: ${cause}` : ""}) at ${new URL(url).host}`);
    }
  }

  async function postForm(url, form, { retried = false } = {}) {
    const secret = clientSecret.current;
    if (!secret) throw new OidcError("client_secret_unavailable", "The client secret has not been read from Secrets Manager yet");
    const response = await call(url, {
      method: "POST",
      headers: {
        Authorization: `Basic ${Buffer.from(`${formEncode(oidc.clientId)}:${formEncode(secret)}`).toString("base64")}`,
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: new URLSearchParams(form).toString(),
    });
    const text = await response.text();
    let body = null;
    try {
      body = text ? JSON.parse(text) : {};
    } catch {
      body = null;
    }
    if (response.ok) {
      if (body === null || typeof body !== "object") throw new OidcError("bad_response", "The identity provider's answer is not JSON", { status: response.status });
      return body;
    }
    const code = typeof body?.error === "string" ? body.error : `http_${response.status}`;
    // A new secret is picked up from Secrets Manager every few minutes. When Ping rejects the one in memory,
    // read it at once and try again, so a rotation never blocks sign-in for those minutes.
    if (code === "invalid_client" && !retried) {
      await clientSecret.refresh();
      if (clientSecret.current && clientSecret.current !== secret) return postForm(url, form, { retried: true });
    }
    const description = typeof body?.error_description === "string" ? body.error_description : `HTTP ${response.status}`;
    throw new OidcError(code, description, { status: response.status });
  }

  /** Checks an ID token from the token endpoint; `nonce` at sign-in, `sub` when it comes with a renewal. */
  async function verifyIdToken(idToken, { nonce, sub } = {}) {
    if (typeof idToken !== "string" || !idToken) throw new OidcError("no_id_token", "The identity provider returned no ID token");
    let payload;
    try {
      payload = await idTokenVerifier.verify(idToken);
    } catch (err) {
      const name = errorClass(err);
      if (/Fetch|NotAvailable/i.test(name)) {
        throw new OidcError("unreachable", `The identity provider's signing keys could not be downloaded (${name}: ${err?.message ?? ""})`);
      }
      const alg = (() => {
        try {
          return JSON.parse(Buffer.from(idToken.split(".")[0], "base64url").toString("utf8")).alg;
        } catch {
          return undefined;
        }
      })();
      const hint = /^HS/.test(alg ?? "") ? `; it is signed with ${alg}, ask the Identity team for RS256` : "";
      throw new OidcError("invalid_id_token", `The ID token is not valid (${name}${hint})`);
    }
    if (typeof payload.sub !== "string" || !payload.sub) throw new OidcError("invalid_id_token", "The ID token has no sub claim");
    if (nonce !== undefined && payload.nonce !== nonce) throw new OidcError("invalid_id_token", "The ID token does not belong to this sign-in (nonce)");
    if (sub !== undefined && payload.sub !== sub) throw new OidcError("invalid_id_token", "The renewed ID token is for another user");
    return payload;
  }

  return {
    /** Where /auth/login sends the browser: authorization code flow with PKCE (S256), state and nonce. */
    authorizationUrl({ state, nonce, codeChallenge }) {
      const params = new URLSearchParams({
        client_id: oidc.clientId,
        response_type: "code",
        scope: oidc.scope,
        redirect_uri: oidc.redirectUri,
        state,
        nonce,
        code_challenge: codeChallenge,
        code_challenge_method: "S256",
      });
      return `${oidc.authorizationEndpoint}?${params}`;
    },

    /** Swaps the sign-in code for tokens and checks the ID token. */
    async exchangeCode({ code, codeVerifier, nonce }) {
      const tokens = await postForm(oidc.tokenEndpoint, {
        grant_type: "authorization_code",
        code,
        redirect_uri: oidc.redirectUri,
        code_verifier: codeVerifier,
      });
      const claims = await verifyIdToken(tokens.id_token, { nonce });
      return { claims, accessToken: tokens.access_token || null, refreshToken: tokens.refresh_token || null };
    },

    /** Renews with the refresh token: Ping refuses (invalid_grant) once the user may no longer sign in. */
    async refresh({ refreshToken, sub }) {
      const tokens = await postForm(oidc.tokenEndpoint, { grant_type: "refresh_token", refresh_token: refreshToken });
      const claims = tokens.id_token ? await verifyIdToken(tokens.id_token, { sub }) : null;
      // Ping may hand out a new refresh token each time (rotation); otherwise the old one stays valid.
      return { claims, accessToken: tokens.access_token || null, refreshToken: tokens.refresh_token || refreshToken };
    },

    /** RFC 7009: the refresh token stops working at Ping. */
    async revoke(refreshToken) {
      if (!oidc.revocationEndpoint || !refreshToken) return;
      await postForm(oidc.revocationEndpoint, { token: refreshToken, token_type_hint: "refresh_token" });
    },

    /** The claims Ping's userinfo endpoint returns for an access token (where some providers put the groups). */
    async userinfo(accessToken) {
      if (!oidc.userinfoEndpoint || !accessToken) return null;
      const response = await call(oidc.userinfoEndpoint, { headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" } });
      if (!response.ok) throw new OidcError(`http_${response.status}`, `The userinfo request failed (HTTP ${response.status})`, { status: response.status });
      const body = await response.json().catch(() => null);
      return body && typeof body === "object" ? body : null;
    },

    /** Ping's sign-out page, which returns to the site afterwards. Null when no end-session endpoint is set. */
    logoutUrl() {
      if (!oidc.endSessionEndpoint) return null;
      const params = new URLSearchParams({ client_id: oidc.clientId, post_logout_redirect_uri: oidc.postLogoutRedirectUri });
      return `${oidc.endSessionEndpoint}?${params}`;
    },
  };
}
