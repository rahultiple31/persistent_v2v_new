// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { CognitoJwtVerifier } from "aws-jwt-verify";

/**
 * Verifies Cognito access tokens locally against the user pool's JWKS (signature, issuer, expiry,
 * token_use=access, client_id, and optionally cognito:groups). JWKS is cached, so after `hydrate()`
 * verification needs no network call.
 */
export function createCognitoVerifier({ userPoolId, clientId, allowedGroups }) {
  const verifier = CognitoJwtVerifier.create({
    userPoolId,
    clientId,
    tokenUse: "access",
    ...(allowedGroups.length ? { groups: allowedGroups } : {}),
  });
  return {
    hydrate: () => verifier.hydrate(),
    async verify(token) {
      const payload = await verifier.verify(token);
      return { userId: payload.sub, expiresAt: payload.exp * 1000 };
    },
  };
}
