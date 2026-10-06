#!/usr/bin/env node
// V2V fix 2 - sign-in hardening and browser security headers. Apply on top of apply-v2v-fix-1.cjs.
//   - PKCE + state on sign-in, refresh token revoked at sign-out, 12-hour sign-in sessions that never end
//     during a call (the agent is warned 30 minutes before);
//   - app client keeps SSO-only sign-in (the SSO provider named in CDK);
//   - CloudFront security headers: HSTS, nosniff, frame DENY, referrer policy, and a Content Security Policy
//     (report-only until cspEnforced=true); the inline script in index.html moves to public/ui-controls.js.
//
// Run from the project root (the folder that contains cdk-stacks, webapp and SETUP.md):
//   node apply-v2v-fix-2.cjs            check only: reports what it would do, changes nothing
//   node apply-v2v-fix-2.cjs --apply    applies everything, or nothing if any check fails
//
// - Edits 8 existing files in place (21 edits). Each edit replaces one exact block of
//   text; if that block is not found exactly once, nothing is changed and the file is reported.
//   Any other changes you have in those files are kept.
// - Backs up every file it modifies or overwrites to v2v-backup-<timestamp>/ first.
// - Works with either Windows (CRLF) or Unix (LF) line endings, and is safe to run twice.
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const NEW_FILES = {
 "webapp/public/ui-controls.js": "// Panel settings popup toggle, customer-information scroll arrows and the user profile tray.\n// Pure UI. Moved out of index.html unchanged, so the Content Security Policy can forbid inline scripts.\ndocument.addEventListener('DOMContentLoaded', function () {\n  // Toggle each panel settings popup on gear-btn click\n  document.querySelectorAll('.panel-settings-btn').forEach(function (btn) {\n    btn.addEventListener('click', function (e) {\n      e.stopPropagation();\n      var popupId = btn.getAttribute('data-popup');\n      var popup = document.getElementById(popupId);\n      if (!popup) return;\n      // Close all other open popups first\n      document.querySelectorAll('.panel-settings-popup.popup-open').forEach(function (p) {\n        if (p !== popup) p.classList.remove('popup-open');\n      });\n      popup.classList.toggle('popup-open');\n    });\n  });\n  // Close popup on outside click\n  document.addEventListener('click', function () {\n    document.querySelectorAll('.panel-settings-popup.popup-open').forEach(function (p) {\n      p.classList.remove('popup-open');\n    });\n  });\n  // Prevent clicks inside popup from closing it\n  document.querySelectorAll('.panel-settings-popup').forEach(function (p) {\n    p.addEventListener('click', function (e) { e.stopPropagation(); });\n  });\n\n  // ── Customer Information horizontal scroll arrows ──────────────────\n  (function () {\n    var body = document.getElementById('customerInfoBody');\n    var btnL = document.getElementById('ciScrollLeft');\n    var btnR = document.getElementById('ciScrollRight');\n    if (!body || !btnL || !btnR) return;\n\n    var STEP = 160; // px scrolled per click\n\n    // Update arrow opacity based on current scroll position\n    function updateArrows() {\n      var atStart = body.scrollLeft <= 0;\n      var atEnd = body.scrollLeft >= body.scrollWidth - body.clientWidth - 1;\n\n      // Left arrow: faded when at start, active when scrolled right\n      btnL.classList.toggle('ci-arrow-faded', atStart);\n      btnL.classList.toggle('ci-arrow-active', !atStart);\n\n      // Right arrow: faded when at end, active when there is more to scroll\n      btnR.classList.toggle('ci-arrow-faded', atEnd);\n      btnR.classList.toggle('ci-arrow-active', !atEnd);\n    }\n\n    // Smooth scroll on click\n    btnL.addEventListener('click', function () {\n      body.scrollBy({ left: -STEP, behavior: 'smooth' });\n    });\n    btnR.addEventListener('click', function () {\n      body.scrollBy({ left: STEP, behavior: 'smooth' });\n    });\n\n    // Re-evaluate arrows on every scroll event\n    body.addEventListener('scroll', updateArrows);\n\n    // Initial state on page load\n    updateArrows();\n  })();\n  // ─────────────────────────────────────────────────────────────────────\n\n  // User profile icon — toggle logout tray\n  var userProfileBtn = document.getElementById('userProfileButton');\n  var userProfileDropdown = document.getElementById('userProfileDropdown');\n  if (userProfileBtn && userProfileDropdown) {\n    userProfileBtn.addEventListener('click', function (e) {\n      e.stopPropagation();\n      userProfileDropdown.classList.toggle('hidden');\n    });\n    // Close tray on outside click\n    document.addEventListener('click', function () {\n      userProfileDropdown.classList.add('hidden');\n    });\n    // Prevent clicks inside tray from closing it\n    userProfileDropdown.addEventListener('click', function (e) {\n      e.stopPropagation();\n    });\n  }\n});\n"
};

const EDITS = [
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "function getRedirectURI() {\n  return localStorage.getItem(\"redirectUri\");\n}\n\n// Generate the Cognito hosted UI URL\nexport function getLoginUrl() {\n  const params = new URLSearchParams({\n    client_id: COGNITO_CONFIG.clientId,\n    response_type: \"code\",\n    scope: \"email openid profile\",\n    redirect_uri: getRedirectURI(),\n  });",
  "replace": "function getRedirectURI() {\n  return localStorage.getItem(\"redirectUri\");\n}\n\n// PKCE verifier and state for the sign-in in progress. They live in this tab's sessionStorage from the\n// redirect to Cognito until the redirect back, and are removed as soon as they are used.\nconst PKCE_VERIFIER_KEY = \"v2vPkceVerifier\";\nconst OAUTH_STATE_KEY = \"v2vOAuthState\";\n\nfunction base64Url(bytes) {\n  let binary = \"\";\n  bytes.forEach((b) => {\n    binary += String.fromCharCode(b);\n  });\n  return btoa(binary).replace(/\\+/g, \"-\").replace(/\\//g, \"_\").replace(/=+$/, \"\");\n}\n\nfunction randomToken(byteLength) {\n  return base64Url(crypto.getRandomValues(new Uint8Array(byteLength)));\n}\n\n// Generate the Cognito hosted UI URL.\n//  - PKCE (S256): Cognito only exchanges the code together with the verifier kept in this tab, so an\n//    authorization code taken from browser history, logs or an extension is useless on its own.\n//  - state: the redirect back is accepted only if it answers the sign-in this tab started, which stops a\n//    forged redirect from signing the browser in as someone else (login CSRF).\nexport async function getLoginUrl() {\n  const verifier = randomToken(32);\n  const state = randomToken(16);\n  const challenge = base64Url(new Uint8Array(await crypto.subtle.digest(\"SHA-256\", new TextEncoder().encode(verifier))));\n  sessionStorage.setItem(PKCE_VERIFIER_KEY, verifier);\n  sessionStorage.setItem(OAUTH_STATE_KEY, state);\n\n  const params = new URLSearchParams({\n    client_id: COGNITO_CONFIG.clientId,\n    response_type: \"code\",\n    scope: \"email openid profile\",\n    redirect_uri: getRedirectURI(),\n    state,\n    code_challenge: challenge,\n    code_challenge_method: \"S256\",\n  });"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "  const urlParams = new URLSearchParams(window.location.search);\n  const code = urlParams.get(\"code\");\n\n  if (code) {\n    try {\n      // Exchange the code for tokens\n      const tokens = await getTokens(code);\n      // Store tokens\n      setTokens(tokens);\n      // Remove code from URL\n      window.history.replaceState({}, document.title, window.location.pathname);\n      return true;\n    } catch (error) {",
  "replace": "  const urlParams = new URLSearchParams(window.location.search);\n  const code = urlParams.get(\"code\");\n\n  if (code) {\n    const expectedState = sessionStorage.getItem(OAUTH_STATE_KEY);\n    const verifier = sessionStorage.getItem(PKCE_VERIFIER_KEY);\n    // One use only, and the code leaves the address bar whatever happens next.\n    sessionStorage.removeItem(OAUTH_STATE_KEY);\n    sessionStorage.removeItem(PKCE_VERIFIER_KEY);\n    window.history.replaceState({}, document.title, window.location.pathname);\n\n    if (!expectedState || !verifier || urlParams.get(\"state\") !== expectedState) {\n      console.error(`${LOGGER_PREFIX} - handleRedirect - sign-in response rejected: it does not match a sign-in started in this tab`);\n      return false;\n    }\n    try {\n      // Exchange the code for tokens\n      const tokens = await getTokens(code, verifier);\n      // Store tokens\n      setTokens(tokens);\n      return true;\n    } catch (error) {"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "async function getTokens(code) {\n  const params = new URLSearchParams({\n    grant_type: \"authorization_code\",\n    client_id: COGNITO_CONFIG.clientId,\n    code: code,\n    redirect_uri: getRedirectURI(),\n  });",
  "replace": "async function getTokens(code, codeVerifier) {\n  const params = new URLSearchParams({\n    grant_type: \"authorization_code\",\n    client_id: COGNITO_CONFIG.clientId,\n    code: code,\n    redirect_uri: getRedirectURI(),\n    code_verifier: codeVerifier,\n  });"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "    console.error(`${LOGGER_PREFIX} - refreshTokens - Error refreshing tokens:`, error);\n    // Clear stored tokens and redirect to login\n    logout();\n    throw error;",
  "replace": "    console.error(`${LOGGER_PREFIX} - refreshTokens - Error refreshing tokens:`, error);\n    // Sign out, but never in the middle of a call (see endSession).\n    endSession(\"refresh failed\");\n    throw error;"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "  const refreshToken = localStorage.getItem(\"refreshToken\");\n\n  if (refreshToken == null) {\n    console.error(`${LOGGER_PREFIX} - getValidTokens - No refresh token available`);\n    // Clear stored tokens and redirect to login\n    logout();\n    return;\n  }\n\n  if (isTokenExpired(idToken) || isTokenExpired(accessToken)) {\n    try {\n      await refreshTokens();\n    } catch (error) {\n      console.error(`${LOGGER_PREFIX} - getValidTokens - Error refreshing tokens:`, error);\n      // Clear stored tokens and redirect to login\n      logout();\n      return;\n    }\n  }",
  "replace": "  const refreshToken = localStorage.getItem(\"refreshToken\");\n\n  // The session has already ended and sign-out is waiting for the current call to finish.\n  if (pendingSignOut) return;\n\n  if (refreshToken == null) {\n    console.error(`${LOGGER_PREFIX} - getValidTokens - No refresh token available`);\n    endSession(\"no refresh token\");\n    return;\n  }\n\n  if (isTokenExpired(idToken) || isTokenExpired(accessToken)) {\n    try {\n      await refreshTokens();\n    } catch (error) {\n      console.error(`${LOGGER_PREFIX} - getValidTokens - Error refreshing tokens:`, error);\n      // refreshTokens() has already ended the session (or deferred it until the call ends).\n      return;\n    }\n  }"
 },
 {
  "file": "webapp/utils/authUtility.js",
  "optional": false,
  "find": "export function logout() {\n  const params = new URLSearchParams({\n    client_id: COGNITO_CONFIG.clientId,\n    logout_uri: getRedirectURI(),\n  });\n\n  // Clear local storage\n  localStorage.removeItem(\"accessToken\");\n  localStorage.removeItem(\"idToken\");\n  localStorage.removeItem(\"refreshToken\");\n  _awsCredentials = null;",
  "replace": "// ── Session end: never during a call ────────────────────────────────────────\n//\n// The refresh token lasts one shift (refreshTokenValidityHours). Signing out navigates away from the\n// page, which would drop the softphone and any call in progress. So when the session can no longer be\n// renewed during a call, sign-out waits until the call has ended; streams that are already running keep\n// working meanwhile, only new Nova Sonic / Transcribe sessions need a valid token. The agent is warned\n// SESSION_WARNING_MS before the end so they can sign in again between calls.\n\nconst SESSION_WARNING_MS = 30 * 60 * 1000;\nlet isCallActive = () => false;\nlet notifySession = () => {};\nlet pendingSignOut = false;\n\n/**\n * main.js registers how to tell whether a call is in progress, and how to show session notices:\n * notify({ type: \"expiring\", expiresAt }) before the end, notify({ type: \"expired\" }) when it ended during a call.\n */\nexport function registerSessionHooks({ callActive, notify }) {\n  if (typeof callActive === \"function\") isCallActive = callActive;\n  if (typeof notify === \"function\") notifySession = notify;\n}\n\n/** When the refresh token stops working: the original sign-in time plus refreshTokenValidityHours. */\nexport function getSessionExpiresAt() {\n  const idToken = localStorage.getItem(\"idToken\");\n  if (!idToken) return null;\n  const payload = decodeToken(idToken);\n  const hours = Number(COGNITO_CONFIG.refreshTokenValidityHours);\n  if (!payload?.auth_time || !hours) return null;\n  return (payload.auth_time + hours * 3600) * 1000;\n}\n\n/** Warns the agent SESSION_WARNING_MS before the session ends. Call once the agent is signed in. */\nexport function startSessionExpiryWatch() {\n  const expiresAt = getSessionExpiresAt();\n  if (!expiresAt) return;\n  const warnIn = expiresAt - SESSION_WARNING_MS - Date.now();\n  setTimeout(() => {\n    if (Date.now() < expiresAt) notifySession({ type: \"expiring\", expiresAt });\n  }, Math.max(0, warnIn));\n}\n\nfunction endSession(reason) {\n  if (isCallActive()) {\n    if (!pendingSignOut) {\n      pendingSignOut = true;\n      console.warn(`${LOGGER_PREFIX} - session ended (${reason}) during a call: signing out when the call ends`);\n      notifySession({ type: \"expired\" });\n    }\n    return;\n  }\n  logout();\n}\n\n/** main.js calls this when a call has fully ended, to carry out a sign-out that was waiting for it. */\nexport function completePendingSignOut() {\n  if (pendingSignOut && !isCallActive()) logout();\n}\n\nexport async function logout() {\n  const params = new URLSearchParams({\n    client_id: COGNITO_CONFIG.clientId,\n    logout_uri: getRedirectURI(),\n  });\n  const refreshToken = localStorage.getItem(\"refreshToken\");\n\n  // Clear local storage\n  localStorage.removeItem(\"accessToken\");\n  localStorage.removeItem(\"idToken\");\n  localStorage.removeItem(\"refreshToken\");\n  _awsCredentials = null;\n\n  // Revoke the refresh token, so a copy of it cannot mint new access tokens after sign-out. Bounded, so\n  // a slow or failed request never holds up the sign-out itself.\n  if (refreshToken) {\n    try {\n      await Promise.race([\n        fetch(`${COGNITO_CONFIG.cognitoDomain}/oauth2/revoke`, {\n          method: \"POST\",\n          headers: { \"Content-Type\": \"application/x-www-form-urlencoded\" },\n          body: new URLSearchParams({ token: refreshToken, client_id: COGNITO_CONFIG.clientId }).toString(),\n          keepalive: true,\n        }),\n        new Promise((resolve) => setTimeout(resolve, 2000)),\n      ]);\n    } catch (error) {\n      console.warn(`${LOGGER_PREFIX} - logout - refresh token revocation failed`, error);\n    }\n  }"
 },
 {
  "file": "webapp/config.js",
  "optional": false,
  "find": "  ssoProviderName: getParamValue(window.WebappConfig.ssoProviderName),\n};",
  "replace": "  ssoProviderName: getParamValue(window.WebappConfig.ssoProviderName),\n  // How long a sign-in lasts before the agent must sign in again (the refresh token's lifetime).\n  refreshTokenValidityHours: getParamValue(window.WebappConfig.refreshTokenValidityHours),\n};"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "import {\n  getLoginUrl,\n  getValidTokens,\n  handleRedirect,\n  isAuthenticated,\n  logout,\n  setRedirectURI,\n  startTokenRefreshTimer,\n} from \"./utils/authUtility\";",
  "replace": "import {\n  completePendingSignOut,\n  getLoginUrl,\n  getValidTokens,\n  handleRedirect,\n  isAuthenticated,\n  logout,\n  registerSessionHooks,\n  setRedirectURI,\n  startSessionExpiryWatch,\n  startTokenRefreshTimer,\n} from \"./utils/authUtility\";"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "function redirectToLogin() {\n  const now = Date.now();",
  "replace": "async function redirectToLogin() {\n  const now = Date.now();"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "    // Storage unavailable: redirect anyway.\n  }\n  window.location.href = getLoginUrl();\n}\n\nfunction showApp() {\n  onLoad();\n}",
  "replace": "    // Storage unavailable: redirect anyway.\n  }\n  window.location.href = await getLoginUrl();\n}\n\nfunction showApp() {\n  initSessionGuard();\n  onLoad();\n}\n\n// ── Sign-in session: never ended during a call ──────────────────────────────\n\n// The Connect agent, once the CCP has initialised (set in onConnectInitialized).\nlet SessionAgent = null;\n\n/** True while the agent has any contact, including after-call work. */\nfunction isOnCall() {\n  try {\n    return SessionAgent != null && SessionAgent.getContacts().length > 0;\n  } catch {\n    return false;\n  }\n}\n\nfunction initSessionGuard() {\n  registerSessionHooks({ callActive: isOnCall, notify: showSessionNotice });\n  startSessionExpiryWatch();\n}\n\n/**\n * Persistent banner for sign-in session notices. Signing in again reloads the\n * page, which would drop the softphone, so it is only offered between calls.\n */\nfunction showSessionNotice({ type, expiresAt }) {\n  let banner = document.getElementById(\"sessionNotice\");\n  if (!banner) {\n    banner = document.createElement(\"div\");\n    banner.id = \"sessionNotice\";\n    banner.setAttribute(\"role\", \"alert\");\n    Object.assign(banner.style, {\n      position: \"fixed\",\n      top: \"8px\",\n      left: \"50%\",\n      transform: \"translateX(-50%)\",\n      zIndex: \"10000\",\n      maxWidth: \"min(640px, calc(100vw - 32px))\",\n      padding: \"10px 14px\",\n      borderRadius: \"6px\",\n      background: \"#fff4e5\",\n      color: \"#5c3b00\",\n      border: \"1px solid #f0b95e\",\n      boxShadow: \"0 2px 8px rgba(0, 0, 0, 0.15)\",\n      display: \"flex\",\n      gap: \"12px\",\n      alignItems: \"center\",\n      fontSize: \"14px\",\n    });\n    document.body.appendChild(banner);\n  }\n  banner.replaceChildren();\n  const text = document.createElement(\"span\");\n  if (type === \"expiring\") {\n    const time = new Date(expiresAt).toLocaleTimeString([], { hour: \"2-digit\", minute: \"2-digit\" });\n    text.textContent = `Your sign-in ends at ${time}. Sign in again between calls to keep translation running.`;\n    const button = document.createElement(\"button\");\n    button.type = \"button\";\n    button.textContent = \"Sign in again\";\n    button.addEventListener(\"click\", () => {\n      if (isOnCall()) {\n        showToast(\"Finish the current call first, then sign in again.\", 5000);\n        return;\n      }\n      logout();\n    });\n    banner.append(text, button);\n  } else {\n    text.textContent =\n      \"Your sign-in has ended. This call continues, but translation may stop at its next restart. \" +\n      \"You will be asked to sign in when the call ends.\";\n    banner.append(text);\n  }\n}"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "const onConnectInitialized = (connectAgent) => {\n  connect = window.connect;\n  connect.core.initSoftphoneManager({ allowFramedSoftphone: true });",
  "replace": "const onConnectInitialized = (connectAgent) => {\n  connect = window.connect;\n  SessionAgent = connectAgent;\n  connect.core.initSoftphoneManager({ allowFramedSoftphone: true });"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "  // captureSessionConfig().\n\n  clearTranscriptCards();\n}",
  "replace": "  // captureSessionConfig().\n\n  clearTranscriptCards();\n\n  // If the sign-in session ended during this call, sign out now that it is over. Deferred a moment so the\n  // agent's contact list no longer includes the destroyed contact.\n  setTimeout(completePendingSignOut, 1000);\n}"
 },
 {
  "file": "cdk-stacks/lib/infrastructure/cognito-stack.ts",
  "optional": false,
  "find": "export interface CognitoStackProps extends cdk.NestedStackProps {",
  "replace": "/** How long a sign-in lasts before the agent must sign in again (refresh token lifetime). */\nexport const REFRESH_TOKEN_VALIDITY = cdk.Duration.hours(12);\n\nexport interface CognitoStackProps extends cdk.NestedStackProps {"
 },
 {
  "file": "cdk-stacks/lib/infrastructure/cognito-stack.ts",
  "optional": false,
  "find": "    //Enable Cognito Managed Login Pages\n    supportedIdentityProviders.push(cognito.UserPoolClientIdentityProvider.COGNITO);\n\n    //create a User Pool Client\n    const userPoolClient = new cognito.UserPoolClient(this, \"UserPoolClient\", {\n      userPool: userPool,\n      userPoolClientName: props.SSMParams.CdkFrontendStack,\n      generateSecret: false,\n      supportedIdentityProviders: supportedIdentityProviders,",
  "replace": "    // Sign-in options offered by the app client. With SSO enabled, only the corporate identity provider:\n    // password sign-in on the Cognito page is off. The provider itself is created in the Cognito console;\n    // naming it here keeps it on the app client when a deploy updates the client, instead of the list\n    // being reset to COGNITO (which would turn password sign-in back on and break SSO).\n    if (props.SSMParams.ssoEnabled) {\n      supportedIdentityProviders.push(cognito.UserPoolClientIdentityProvider.custom(props.SSMParams.ssoProviderName));\n    } else {\n      supportedIdentityProviders.push(cognito.UserPoolClientIdentityProvider.COGNITO);\n    }\n\n    //create a User Pool Client\n    const userPoolClient = new cognito.UserPoolClient(this, \"UserPoolClient\", {\n      userPool: userPool,\n      userPoolClientName: props.SSMParams.CdkFrontendStack,\n      generateSecret: false,\n      supportedIdentityProviders: supportedIdentityProviders,\n      // One working shift. The webapp warns the agent 30 minutes before, and never signs out during a call.\n      refreshTokenValidity: REFRESH_TOKEN_VALIDITY,\n      // Lets the webapp revoke the refresh token at sign-out (/oauth2/revoke).\n      enableTokenRevocation: true,"
 },
 {
  "file": "cdk-stacks/lib/cdk-backend-stack.ts",
  "optional": false,
  "find": "import { CognitoStack } from \"./infrastructure/cognito-stack\";",
  "replace": "import { CognitoStack, REFRESH_TOKEN_VALIDITY } from \"./infrastructure/cognito-stack\";"
 },
 {
  "file": "cdk-stacks/lib/cdk-backend-stack.ts",
  "optional": false,
  "find": "    // Proxy switch for the webapp: when enabled, every AWS call goes through the server-side proxy.\n    this.backendStackOutputs.push({ key: \"proxyEnabled\", value: String(ssmParams.proxyEnabled) });",
  "replace": "    // Proxy switch for the webapp: when enabled, every AWS call goes through the server-side proxy.\n    this.backendStackOutputs.push({ key: \"proxyEnabled\", value: String(ssmParams.proxyEnabled) });\n    // Lets the webapp warn the agent before their sign-in session ends.\n    this.backendStackOutputs.push({ key: \"refreshTokenValidityHours\", value: String(REFRESH_TOKEN_VALIDITY.toHours()) });"
 },
 {
  "file": "cdk-stacks/config/config.params.json",
  "optional": false,
  "find": "      \"description\": \"Optional comma-separated names of exactly 2 Availability Zones for the proxy, for example us-east-1a,us-east-1b. CloudFront VPC origins do not support every AZ (in us-east-1 not AZ ID use1-az3), and AZ names map to different AZ IDs in each account. Leave not-defined to use the first 2 AZs.\",\n      \"required\": false\n    }\n  ]",
  "replace": "      \"description\": \"Optional comma-separated names of exactly 2 Availability Zones for the proxy, for example us-east-1a,us-east-1b. CloudFront VPC origins do not support every AZ (in us-east-1 not AZ ID use1-az3), and AZ names map to different AZ IDs in each account. Leave not-defined to use the first 2 AZs.\",\n      \"required\": false\n    },\n    {\n      \"name\": \"cspEnforced\",\n      \"cliFormat\": \"csp-enforced\",\n      \"description\": \"false = the webapp's Content Security Policy is sent report-only: the browser console lists what it would block, nothing is blocked. true = the policy is enforced. Run test calls in report-only mode first, and enforce once the console shows no Content Security Policy reports.\",\n      \"boolean\": true,\n      \"defaultValue\": false,\n      \"required\": false\n    }\n  ]"
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "export interface CdkFrontendStackProps extends cdk.StackProps {",
  "replace": "/**\n * Content Security Policy for the webapp:\n *  - scripts, styles, fonts and images only from the app's own origin (no inline scripts);\n *  - network connections only to the app itself (including the proxy at /ws and /api), the Cognito\n *    domain, the Amazon Connect instance and Connect's softphone signalling; plus AWS endpoints in\n *    direct mode, where the browser calls AWS itself;\n *  - frames only from the Connect instance (the CCP), and the app itself cannot be framed.\n * If a stolen or injected script runs anyway, it cannot send tokens or call data to any other site.\n */\nfunction contentSecurityPolicy(ssmParams: any, region: string, enforced: boolean): string {\n  const originOf = (url: string): string | undefined => {\n    try {\n      return new URL(url).origin;\n    } catch {\n      return undefined; // placeholder value during the first CDK synth pass\n    }\n  };\n  const cognito = `https://${ssmParams.cognitoDomainPrefix}.auth.${region}.amazoncognito.com`;\n  const connect = originOf(ssmParams.connectInstanceURL);\n  const connectSignalling = `wss://*.connect-telecom.${ssmParams.connectInstanceRegion}.amazonaws.com`;\n  const directModeAws = ssmParams.proxyEnabled ? [] : [\"https://*.amazonaws.com\", \"wss://*.amazonaws.com:8443\"];\n  const directives = [\n    \"default-src 'self'\",\n    \"script-src 'self'\",\n    // Inline style attributes in index.html, and styles set by Bootstrap and the CCP library.\n    \"style-src 'self' 'unsafe-inline'\",\n    \"img-src 'self' data: blob:\",\n    \"font-src 'self' data:\",\n    \"media-src 'self' blob: data:\",\n    `connect-src 'self' ${[cognito, connect, connectSignalling, ...directModeAws].filter(Boolean).join(\" \")}`,\n    `frame-src ${connect ?? \"'none'\"}`,\n    \"worker-src 'self' blob:\",\n    \"object-src 'none'\",\n    \"base-uri 'self'\",\n    \"form-action 'self'\",\n    \"frame-ancestors 'none'\",\n    ...(enforced ? [\"upgrade-insecure-requests\"] : []),\n  ];\n  return directives.join(\"; \");\n}\n\nexport interface CdkFrontendStackProps extends cdk.StackProps {"
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "    const webAppCloudFrontDistribution = new cloudfront.Distribution(this, `${configParams[\"CdkAppName\"]}-WebAppDistribution`, {",
  "replace": "    // Security headers for the webapp. The Content Security Policy is report-only until cspEnforced is true:\n    // the browser console then lists anything the policy would block, without blocking it.\n    const csp = (enforced: boolean) => contentSecurityPolicy(ssmParams, this.region, enforced);\n    const securityHeadersPolicy = new cloudfront.ResponseHeadersPolicy(this, \"WebAppSecurityHeaders\", {\n      comment: `Security headers for ${configParams[\"CdkAppName\"]}`,\n      securityHeadersBehavior: {\n        strictTransportSecurity: { accessControlMaxAge: cdk.Duration.days(365), includeSubdomains: true, override: true },\n        contentTypeOptions: { override: true },\n        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },\n        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN, override: true },\n        ...(ssmParams.cspEnforced ? { contentSecurityPolicy: { contentSecurityPolicy: csp(true), override: true } } : {}),\n      },\n      ...(ssmParams.cspEnforced\n        ? {}\n        : { customHeadersBehavior: { customHeaders: [{ header: \"Content-Security-Policy-Report-Only\", value: csp(false), override: true }] } }),\n    });\n\n    const webAppCloudFrontDistribution = new cloudfront.Distribution(this, `${configParams[\"CdkAppName\"]}-WebAppDistribution`, {"
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "        compress: true,\n        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,\n      },\n      additionalBehaviors: proxyBehaviors,",
  "replace": "        compress: true,\n        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,\n        responseHeadersPolicy: securityHeadersPolicy,\n      },\n      additionalBehaviors: proxyBehaviors,"
 },
 {
  "file": "webapp/index.html",
  "optional": false,
  "find": "  <!-- Panel settings popup toggle — pure UI, no existing JS logic touched -->\n  <script>\n    document.addEventListener('DOMContentLoaded', function () {\n      // Toggle each panel settings popup on gear-btn click\n      document.querySelectorAll('.panel-settings-btn').forEach(function (btn) {\n        btn.addEventListener('click', function (e) {\n          e.stopPropagation();\n          var popupId = btn.getAttribute('data-popup');\n          var popup = document.getElementById(popupId);\n          if (!popup) return;\n          // Close all other open popups first\n          document.querySelectorAll('.panel-settings-popup.popup-open').forEach(function (p) {\n            if (p !== popup) p.classList.remove('popup-open');\n          });\n          popup.classList.toggle('popup-open');\n        });\n      });\n      // Close popup on outside click\n      document.addEventListener('click', function () {\n        document.querySelectorAll('.panel-settings-popup.popup-open').forEach(function (p) {\n          p.classList.remove('popup-open');\n        });\n      });\n      // Prevent clicks inside popup from closing it\n      document.querySelectorAll('.panel-settings-popup').forEach(function (p) {\n        p.addEventListener('click', function (e) { e.stopPropagation(); });\n      });\n\n      // ── Customer Information horizontal scroll arrows ──────────────────\n      (function () {\n        var body = document.getElementById('customerInfoBody');\n        var btnL = document.getElementById('ciScrollLeft');\n        var btnR = document.getElementById('ciScrollRight');\n        if (!body || !btnL || !btnR) return;\n\n        var STEP = 160; // px scrolled per click\n\n        // Update arrow opacity based on current scroll position\n        function updateArrows() {\n          var atStart = body.scrollLeft <= 0;\n          var atEnd = body.scrollLeft >= body.scrollWidth - body.clientWidth - 1;\n\n          // Left arrow: faded when at start, active when scrolled right\n          btnL.classList.toggle('ci-arrow-faded', atStart);\n          btnL.classList.toggle('ci-arrow-active', !atStart);\n\n          // Right arrow: faded when at end, active when there is more to scroll\n          btnR.classList.toggle('ci-arrow-faded', atEnd);\n          btnR.classList.toggle('ci-arrow-active', !atEnd);\n        }\n\n        // Smooth scroll on click\n        btnL.addEventListener('click', function () {\n          body.scrollBy({ left: -STEP, behavior: 'smooth' });\n        });\n        btnR.addEventListener('click', function () {\n          body.scrollBy({ left: STEP, behavior: 'smooth' });\n        });\n\n        // Re-evaluate arrows on every scroll event\n        body.addEventListener('scroll', updateArrows);\n\n        // Initial state on page load\n        updateArrows();\n      })();\n      // ─────────────────────────────────────────────────────────────────────\n\n      // User profile icon — toggle logout tray\n      var userProfileBtn = document.getElementById('userProfileButton');\n      var userProfileDropdown = document.getElementById('userProfileDropdown');\n      if (userProfileBtn && userProfileDropdown) {\n        userProfileBtn.addEventListener('click', function (e) {\n          e.stopPropagation();\n          userProfileDropdown.classList.toggle('hidden');\n        });\n        // Close tray on outside click\n        document.addEventListener('click', function () {\n          userProfileDropdown.classList.add('hidden');\n        });\n        // Prevent clicks inside tray from closing it\n        userProfileDropdown.addEventListener('click', function (e) {\n          e.stopPropagation();\n        });\n      }\n    });\n\n\n  </script>",
  "replace": "  <!-- Panel settings popups, customer-information scroll arrows and the profile tray: public/ui-controls.js.\n       An external file, so the Content Security Policy can forbid inline scripts. -->\n  <script src=\"./ui-controls.js\"></script>"
 }
];

// Detects a copy damaged in transfer (cut short, or saved in a non-UTF-8 encoding).
const INTEGRITY = "67cf2112801467f2a6aa08976100de7fb28c0505284ef47d593dbd0604b8dfc6";
const actual = crypto.createHash("sha256").update(JSON.stringify({ newFiles: NEW_FILES, edits: EDITS })).digest("hex");
if (actual !== INTEGRITY) {
  console.log("STOPPED - nothing was changed. This script was damaged when it was copied (text cut short or saved in a");
  console.log("non-UTF-8 encoding). Copy it again and save it as UTF-8.");
  process.exit(1);
}

const applyMode = process.argv.includes("--apply");
const exit = (code, lines) => {
  console.log(lines.join("\n"));
  process.exit(code);
};

if (!fs.existsSync("cdk-stacks") || !fs.existsSync("webapp")) {
  exit(1, ["Run this from the project root: the folder that contains cdk-stacks and webapp.", `Current folder: ${process.cwd()}`]);
}

const problems = [];
const notes = [];
const edited = new Map(); // file -> { raw, eol, text, count }

for (const e of EDITS) {
  let entry = edited.get(e.file);
  if (!entry) {
    if (!fs.existsSync(e.file)) {
      (e.optional ? notes : problems).push(`${e.file}: file not found${e.optional ? " (optional, skipped)" : ""}`);
      continue;
    }
    const raw = fs.readFileSync(e.file, "utf8");
    entry = { raw, eol: raw.includes("\r\n") ? "\r\n" : "\n", text: raw.replace(/\r\n/g, "\n"), count: 0, already: 0 };
    edited.set(e.file, entry);
  }
  if (entry.text.includes(e.replace)) {
    entry.already++;
    continue;
  }
  const n = entry.text.split(e.find).length - 1;
  if (n === 1) {
    entry.text = entry.text.replace(e.find, () => e.replace);
    entry.count++;
  } else {
    const where = `${e.file}: the block starting "${e.find.split("\n")[0].trim().slice(0, 70)}" was ${n === 0 ? "not found" : `found ${n} times`}`;
    (e.optional ? notes : problems).push(where + (e.optional ? " (optional, skipped)" : ""));
  }
}

const creates = [];
const overwrites = [];
for (const [file, content] of Object.entries(NEW_FILES)) {
  if (!fs.existsSync(file)) creates.push(file);
  else if (fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n") !== content) overwrites.push(file);
}

if (problems.length) {
  exit(1, [
    "STOPPED - nothing was changed. These files do not match what the changes expect:",
    ...problems.map((p) => "  - " + p),
    "",
    "Your copy of these files differs from the one the changes were made against. Send these files to be merged.",
  ]);
}

const editFiles = [...edited].filter(([, v]) => v.count > 0);
const summary = [
  `New files to create: ${creates.length}`,
  ...(overwrites.length ? [`New files that already exist with different content (will be overwritten): ${overwrites.length}`, ...overwrites.map((f) => "  - " + f)] : []),
  `Existing files to edit: ${editFiles.length}`,
  ...editFiles.map(([f, v]) => `  - ${f} (${v.count} edit${v.count > 1 ? "s" : ""}${v.already ? `, ${v.already} already applied` : ""})`),
  ...notes.map((n) => "Note: " + n),
];

if (!applyMode) {
  exit(0, ["CHECK PASSED - nothing was changed.", ...summary, "", "Run again with --apply to make these changes: node apply-v2v-fix-2.cjs --apply"]);
}

const backup = `v2v-backup-${new Date().toISOString().replace(/[:.]/g, "-")}`;
const toBackUp = [...editFiles.map(([f]) => f), ...overwrites];
for (const file of toBackUp) {
  fs.mkdirSync(path.dirname(path.join(backup, file)), { recursive: true });
  fs.copyFileSync(file, path.join(backup, file));
}
for (const file of [...creates, ...overwrites]) {
  fs.mkdirSync(path.dirname(file) || ".", { recursive: true });
  fs.writeFileSync(file, NEW_FILES[file]);
}
for (const [file, v] of editFiles) {
  fs.writeFileSync(file, v.eol === "\r\n" ? v.text.replace(/\n/g, "\r\n") : v.text);
}

exit(0, [
  "APPLIED.",
  ...summary,
  toBackUp.length ? `Backups of the ${toBackUp.length} changed files: ${backup}` : "No existing files needed a backup.",
  "",
  "Next:",
  "  Check the SSO settings first (see the deploy notes). Then in CloudShell:",
  "  cd cdk-stacks && npm run cdk:remove:context && npx cdk diff --all    (review the diff)",
  "  npm run build:deploy:all",
]);
