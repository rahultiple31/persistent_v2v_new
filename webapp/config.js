// The webapp's settings, served by the proxy as /frontend-config.js (window.WebappConfig) and set at deploy time
// from cdk-stacks/config/private-poc.config.ts. Nova Sonic, Transcribe, Translate and Polly are reached through
// the proxy (same origin: /ws and /api), so the browser never obtains AWS credentials; their Regions and the
// model ID are set on the proxy, not here.
const settings = window.WebappConfig ?? {};

// Sign-in, set by authMode. Not set: the page signs in with the corporate identity provider itself (OIDC,
// PingFederate: authorization code with PKCE). "bff": the proxy signs the agent in with the identity provider's
// client secret (utils/serverSession.js), and the page needs no identity provider settings.
export const AUTH_CONFIG =
  settings.authMode === "bff"
    ? { mode: "bff" }
    : {
        mode: "oidc",
        issuer: settings.oidcIssuer,
        clientId: settings.oidcClientId,
        scope: settings.oidcScope || "openid profile email",
        // Optional. Without them the endpoints come from the issuer's discovery document
        // (<issuer>/.well-known/openid-configuration).
        authorizationEndpoint: settings.oidcAuthorizationEndpoint,
        tokenEndpoint: settings.oidcTokenEndpoint,
        endSessionEndpoint: settings.oidcEndSessionEndpoint,
        revocationEndpoint: settings.oidcRevocationEndpoint,
        // How long a sign-in lasts before the agent must sign in again (the refresh token's lifetime).
        refreshTokenValidityHours: settings.refreshTokenValidityHours,
      };

export const CONNECT_CONFIG = {
  connectInstanceURL: settings.connectInstanceURL,
  connectInstanceRegion: settings.connectInstanceRegion,
  // Only for a Connect instance that signs in with SAML (SSO): where the softphone's login pop-up starts the
  // sign-in, at the identity provider (for example the Connect app's link in the AWS access portal). A SAML
  // instance cannot be signed in to from its own address ("Session expired"). Not set: Connect's own login page.
  connectLoginUrl: settings.connectLoginUrl,
};
