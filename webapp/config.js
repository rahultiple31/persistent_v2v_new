export const COGNITO_CONFIG = {
  region: getParamValue(window.V2VConfig.backendRegion),
  cognitoDomain: getParamValue(window.V2VConfig.cognitoDomainURL),
  identityPoolId: getParamValue(window.V2VConfig.identityPoolId),
  userPoolId: getParamValue(window.V2VConfig.userPoolId),
  clientId: getParamValue(window.V2VConfig.userPoolWebClientId),
};

export const CONNECT_CONFIG = {
  connectInstanceURL: getParamValue(window.V2VConfig.connectInstanceURL),
  connectInstanceRegion: getParamValue(window.V2VConfig.connectInstanceRegion),
};

export const TRANSCRIBE_CONFIG = {
  transcribeRegion: getParamValue(window.V2VConfig.transcribeRegion),
};

export const TRANSLATE_CONFIG = {
  translateRegion: getParamValue(window.V2VConfig.translateRegion),
  translateProxyEnabled: getBoolParamValue(window.V2VConfig.translateProxyEnabled),
  translateProxyHostname: window.location.hostname, // using Amazon Cloudfront as a proxy
};

export const POLLY_CONFIG = {
  pollyRegion: getParamValue(window.V2VConfig.pollyRegion),
  pollyProxyEnabled: getBoolParamValue(window.V2VConfig.pollyProxyEnabled),
  pollyProxyHostname: window.location.hostname, // using Amazon Cloudfront as a proxy
};

function getParamValue(param) {
  const SSM_NOT_DEFINED = "not-defined";
  if (param === SSM_NOT_DEFINED) return undefined;
  return param;
}

function getBoolParamValue(param) {
  return param === "true";
}
