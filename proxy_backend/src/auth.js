// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { JwtVerifier } from "aws-jwt-verify";

/**
 * Verifies access tokens from the corporate OIDC identity provider (PingFederate) locally against its JWKS:
 * signature, issuer, expiry, audience, and optionally that the group claim names one of allowedGroups.
 * The JWKS is downloaded from jwksUri and cached, so after `hydrate()` verification needs no network call;
 * tests pass the key set as `jwks` instead.
 */
export function createOidcVerifier({ issuer, audience, jwksUri, groupClaim, allowedGroups }, { jwks } = {}) {
  const verifier = JwtVerifier.create({
    issuer,
    audience,
    jwksUri,
    customJwtCheck: ({ payload }) => {
      if (typeof payload.sub !== "string" || !payload.sub) throw new MissingClaimError("sub");
      if (allowedGroups.length && !tokenGroups(payload[groupClaim]).some((group) => allowedGroups.includes(group))) {
        throw new GroupNotAllowedError();
      }
    },
  });
  if (jwks) verifier.cacheJwks(jwks);
  return {
    hydrate: () => verifier.hydrate(),
    async verify(token) {
      const payload = await verifier.verify(token);
      return { userId: payload.sub, expiresAt: payload.exp * 1000 };
    },
  };
}

/** Rejects every token: used until the identity provider's client exists (no OIDC_ISSUER yet). */
export function createRejectingVerifier() {
  return {
    hydrate: async () => {},
    async verify() {
      throw new AuthNotConfiguredError();
    },
  };
}

// A group claim is a list, or a single value. Values are compared whole (a directory group's DN contains commas).
export function tokenGroups(claim) {
  if (Array.isArray(claim)) return claim.filter((group) => typeof group === "string");
  return typeof claim === "string" ? [claim] : [];
}

class MissingClaimError extends Error {
  name = "MissingClaimError";
  constructor(claim) {
    super(`Token has no ${claim} claim`);
  }
}

class GroupNotAllowedError extends Error {
  name = "GroupNotAllowedError";
  message = "User is not in an allowed group";
}

class AuthNotConfiguredError extends Error {
  name = "AuthNotConfiguredError";
  message = "No identity provider is configured";
}
