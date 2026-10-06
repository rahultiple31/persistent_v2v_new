export const COGNITO_CONFIG = {
  region: getParamValue(window.WebappConfig.backendRegion),
  cognitoDomain: getParamValue(window.WebappConfig.cognitoDomainURL),
  identityPoolId: getParamValue(window.WebappConfig.identityPoolId),
  userPoolId: getParamValue(window.WebappConfig.userPoolId),
  clientId: getParamValue(window.WebappConfig.userPoolWebClientId),
  // Cognito identity provider name (e.g. "EntraID"). When set, sign-in skips the Cognito page and goes
  // straight to the corporate IdP. Remove it from frontend-config.js to bring the Cognito page back.
  ssoProviderName: getParamValue(window.WebappConfig.ssoProviderName),
  // How long a sign-in lasts before the agent must sign in again (the refresh token's lifetime).
  refreshTokenValidityHours: getParamValue(window.WebappConfig.refreshTokenValidityHours),
};

export const CONNECT_CONFIG = {
  connectInstanceURL: getParamValue(window.WebappConfig.connectInstanceURL),
  connectInstanceRegion: getParamValue(window.WebappConfig.connectInstanceRegion),
};

export const NOVA_SONIC_CONFIG = {
  bedrockRegion: getParamValue(window.WebappConfig.bedrockRegion) || "us-east-1",
  modelId: getParamValue(window.WebappConfig.novaSonicModelId) || "amazon.nova-2-sonic-v1:0",
};

// Regions for Transcribe, Translate and Polly, set per environment through the SSM parameters
// transcribeRegion, translateRegion and pollyRegion. Each falls back to the Bedrock region.
export const TRANSCRIBE_CONFIG = {
  region: getParamValue(window.WebappConfig.transcribeRegion) || NOVA_SONIC_CONFIG.bedrockRegion,
};

export const TRANSLATE_CONFIG = {
  region: getParamValue(window.WebappConfig.translateRegion) || NOVA_SONIC_CONFIG.bedrockRegion,
};

export const POLLY_CONFIG = {
  region: getParamValue(window.WebappConfig.pollyRegion) || NOVA_SONIC_CONFIG.bedrockRegion,
};

// Set per environment through the SSM parameter proxyEnabled. When true, Nova Sonic, Transcribe,
// Translate and Polly are reached through the server-side proxy (same origin: /ws and /api), and the
// browser never obtains AWS credentials. The regions and model ID above are then set on the proxy.
export const PROXY_CONFIG = {
  enabled: String(getParamValue(window.WebappConfig.proxyEnabled)) === "true",
};

// Set per environment through the SSM parameter translationEnabled. When false (Wave 1), the app is a plain
// softphone: the Customer, Agent and Transcription panels are greyed out and nothing starts a translation.
// The CCP, Customer Information and Audio Controls work as usual. A missing value counts as false.
export const TRANSLATION_CONFIG = {
  enabled: String(getParamValue(window.WebappConfig.translationEnabled)) === "true",
};

function getParamValue(param) {
  const SSM_NOT_DEFINED = "not-defined";
  if (param === SSM_NOT_DEFINED) return undefined;
  return param;
}
