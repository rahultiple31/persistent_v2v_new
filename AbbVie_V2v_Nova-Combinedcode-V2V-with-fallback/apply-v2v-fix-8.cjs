#!/usr/bin/env node
// V2V fix 8 - the translation switch (SSM parameter translationEnabled), for Wave 1 (UI only) and Wave 2 (V2V)
// on the same URL, and reliable delivery of every later deploy to open pages.
//   1. New REQUIRED parameter translationEnabled (true/false, no default: every environment must choose; a
//      deploy without it stops with an error). false = the app is a plain softphone:
//        - the Customer, Agent and Transcription panels are greyed out, marked "Not enabled yet", and cannot be
//          clicked, typed into or reached with Tab; nothing starts a translation (no auto-start on inbound
//          calls, Start and typed text do nothing);
//        - the CCP, Customer Information (filled from the contact attributes, as now) and Audio Controls work
//          as usual;
//        - no proxy is deployed (whatever proxyEnabled says), the browser's Cognito role gets no Bedrock,
//          Transcribe, Translate or Polly permissions, and the Content Security Policy allows no AWS endpoints.
//      true = exactly as now (proxy or direct, from proxyEnabled). One rule decides all of this
//      (translationMode in ssm-params-util.ts), so the page, the proxy and the permissions cannot disagree.
//   2. Open pages check every 5 minutes, and after each call, whether a newer version is deployed (new code or
//      new settings), and show a banner asking the agent to reload between calls ("Voice translation is now
//      available..." when translation was switched on). The page never reloads itself. A deploy that switches
//      translation off stops new translations on open pages at once; calls continue as plain calls.
//   3. Deploys reach agents reliably:
//        - index.html and frontend-config.js are served with Cache-Control: no-cache;
//        - frontend-config.js is written with its real Content-Type. It was stored as binary/octet-stream, which
//          browsers refuse to run under the nosniff header, so a settings-only deploy (such as switching
//          translation on with no code change) would have stopped the page loading;
//        - the webapp copy waits for the settings to be written, so a deploy cannot end with the old settings;
//        - files of earlier builds are kept, so a page that is already open keeps working after a deploy.
//   4. SETUP.md documents the switch, including what a Terraform port must reproduce.
//
// Run from the project root (the folder that contains cdk-stacks, webapp, proxy and SETUP.md):
//   node apply-v2v-fix-8.cjs            check only: reports what it would do, changes nothing
//   node apply-v2v-fix-8.cjs --apply    applies everything, or nothing if any check fails
//
// - Applies on top of fixes 4, 5, 6 and 7. Edits 3 webapp files (main.js, config.js, style.css), 7 CDK files
//   (config.params.json, ssm-params-util.ts, cdk-backend-stack.ts, cdk-frontend-stack.ts, cognito-stack.ts,
//   frontend-s3-deployment-stack.ts, the frontend-config Lambda's index.py) and 2 docs (SETUP.md and
//   proxy/README.md, optional), and adds webapp/utils/appVersionWatch.js. Nothing in the proxy's code. Each
//   edit replaces one exact block of text; if that block is not found exactly once, nothing is changed and the
//   file is reported. Any other changes you have in those files are kept.
// - Reports whether every resulting file matches the version the tests ran against.
// - Backs up every file it modifies to v2v-backup-<timestamp>/ first.
// - Works with either Windows (CRLF) or Unix (LF) line endings, and is safe to run twice.
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const NEW_FILES = {
 "webapp/utils/appVersionWatch.js": "// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.\n// SPDX-License-Identifier: MIT-0\n\n// Notices when the deployed app differs from the one this page is running: new code (index.html points to\n// a different main script) or new settings (frontend-config.js differs, for example translationEnabled switched\n// on). Agents keep the page open all day, so without this a deploy would only reach them at their next sign-in.\n// It only reads two small files from the app's own origin; it never reloads the page itself.\n\nexport const VERSION_CHECK_INTERVAL_MS = 5 * 60 * 1000;\n\n/** The settings object in a frontend-config.js text (\"window.WebappConfig = {...}\"), or null if it is not one. */\nexport function parseWebappConfig(text) {\n  const match = /window\\.WebappConfig\\s*=\\s*(\\{[\\s\\S]*\\})\\s*;?\\s*$/.exec(String(text ?? \"\"));\n  if (!match) return null;\n  try {\n    const value = JSON.parse(match[1]);\n    return value && typeof value === \"object\" && !Array.isArray(value) ? value : null;\n  } catch {\n    return null;\n  }\n}\n\n/** The src of the first module script in an index.html text (the app's own code), or null if there is none. */\nexport function mainScriptOf(html) {\n  for (const tag of String(html ?? \"\").match(/<script\\b[^>]*>/gi) ?? []) {\n    if (!/\\btype\\s*=\\s*[\"']module[\"']/i.test(tag)) continue;\n    const src = /\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']/i.exec(tag);\n    if (src) return src[1];\n  }\n  return null;\n}\n\n/** True when both settings objects have the same keys and values, in any order. */\nexport function sameConfig(a, b) {\n  const normalise = (config) =>\n    JSON.stringify(\n      Object.keys(config)\n        .sort()\n        .map((key) => [key, String(config[key])]),\n    );\n  return normalise(a) === normalise(b);\n}\n\nconst translationOn = (config) => String(config?.translationEnabled) === \"true\";\n\nasync function fetchFresh(url) {\n  const response = await fetch(url, { cache: \"no-store\", credentials: \"same-origin\" });\n  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);\n  return response.text();\n}\n\n/**\n * Compares the deployed app with the loaded one every intervalMs, and whenever check() is called. onChange gets\n * { codeChanged, configChanged, translationNowEnabled, translationNowDisabled } when a different version is\n * deployed (once per version), and null when the deployed version matches the loaded one again. A file that\n * cannot be fetched or read is ignored: no notice is better than a false one.\n */\nexport function createAppVersionWatch({\n  loadedMainScript,\n  loadedConfig,\n  onChange,\n  log = () => {},\n  fetchText = fetchFresh,\n  intervalMs = VERSION_CHECK_INTERVAL_MS,\n  setIntervalFn = (fn, ms) => setInterval(fn, ms),\n  clearIntervalFn = (id) => clearInterval(id),\n}) {\n  let timer = null;\n  let checking = false;\n  let reported = null; // the deployed version last reported to onChange\n\n  async function check() {\n    if (checking) return;\n    checking = true;\n    try {\n      const [html, configText] = await Promise.all([fetchText(\"/index.html\"), fetchText(\"/frontend-config.js\")]);\n      const deployedScript = mainScriptOf(html);\n      const deployedConfig = parseWebappConfig(configText);\n      if (deployedScript == null || deployedConfig == null) {\n        log(\"deployed version could not be read; checking again later\");\n        return;\n      }\n      const codeChanged = loadedMainScript != null && deployedScript !== loadedMainScript;\n      const configChanged = loadedConfig != null && !sameConfig(deployedConfig, loadedConfig);\n      if (!codeChanged && !configChanged) {\n        if (reported !== null) {\n          reported = null;\n          log(\"deployed version matches this page again\");\n          onChange(null);\n        }\n        return;\n      }\n      const version = `${deployedScript}\\n${JSON.stringify(deployedConfig)}`;\n      if (version === reported) return;\n      reported = version;\n      const change = {\n        codeChanged,\n        configChanged,\n        translationNowEnabled: !translationOn(loadedConfig) && translationOn(deployedConfig),\n        translationNowDisabled: translationOn(loadedConfig) && !translationOn(deployedConfig),\n      };\n      log(\n        `a new version is deployed (${[codeChanged && \"code\", configChanged && \"settings\"].filter(Boolean).join(\" and \")} changed` +\n          `${change.translationNowEnabled ? \", translation switched on\" : \"\"}${change.translationNowDisabled ? \", translation switched off\" : \"\"})`,\n      );\n      onChange(change);\n    } catch (error) {\n      log(`version check failed (${error?.message ?? error}); checking again later`);\n    } finally {\n      checking = false;\n    }\n  }\n\n  return {\n    check,\n    start() {\n      if (timer == null) timer = setIntervalFn(check, intervalMs);\n    },\n    stop() {\n      if (timer != null) clearIntervalFn(timer);\n      timer = null;\n    },\n  };\n}\n"
};

const EDITS = [
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "  normalizeForCompare,\n  RecentSpeech,\n  SourceUtterance,\n} from \"./utils/translationGuards\";\nimport { CONNECT_CONFIG, NOVA_SONIC_CONFIG, TRANSCRIBE_CONFIG, TRANSLATE_CONFIG, POLLY_CONFIG, COGNITO_CONFIG, PROXY_CONFIG } from \"./config\";\nimport { fetchTranslationMode, warmProxyConnections } from \"./utils/proxyTransport\";\nimport {\n  BACKUP_MAX_ATTEMPTS,\n  HANDOVER_MIN_RETURNING_MS,\n  HANDOVER_QUIET_AFTER_SENTENCE_MS,",
  "replace": "  normalizeForCompare,\n  RecentSpeech,\n  SourceUtterance,\n} from \"./utils/translationGuards\";\nimport { CONNECT_CONFIG, NOVA_SONIC_CONFIG, TRANSCRIBE_CONFIG, TRANSLATE_CONFIG, POLLY_CONFIG, COGNITO_CONFIG, PROXY_CONFIG, TRANSLATION_CONFIG } from \"./config\";\nimport { fetchTranslationMode, warmProxyConnections } from \"./utils/proxyTransport\";\nimport { createAppVersionWatch } from \"./utils/appVersionWatch\";\nimport {\n  BACKUP_MAX_ATTEMPTS,\n  HANDOVER_MIN_RETURNING_MS,\n  HANDOVER_QUIET_AFTER_SENTENCE_MS,"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "  banner.replaceChildren();\n  const text = document.createElement(\"span\");\n  if (type === \"expiring\") {\n    const time = new Date(expiresAt).toLocaleTimeString([], { hour: \"2-digit\", minute: \"2-digit\" });\n    text.textContent = `Your sign-in ends at ${time}. Sign in again between calls to keep translation running.`;\n    const button = document.createElement(\"button\");\n    button.type = \"button\";\n    button.textContent = \"Sign in again\";\n    button.addEventListener(\"click\", () => {",
  "replace": "  banner.replaceChildren();\n  const text = document.createElement(\"span\");\n  if (type === \"expiring\") {\n    const time = new Date(expiresAt).toLocaleTimeString([], { hour: \"2-digit\", minute: \"2-digit\" });\n    text.textContent = TRANSLATION_CONFIG.enabled\n      ? `Your sign-in ends at ${time}. Sign in again between calls to keep translation running.`\n      : `Your sign-in ends at ${time}. Sign in again between calls.`;\n    const button = document.createElement(\"button\");\n    button.type = \"button\";\n    button.textContent = \"Sign in again\";\n    button.addEventListener(\"click\", () => {"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "      logout();\n    });\n    banner.append(text, button);\n  } else {\n    text.textContent =\n      \"Your sign-in has ended. This call continues, but translation may stop at its next restart. \" +\n      \"You will be asked to sign in when the call ends.\";\n    banner.append(text);\n  }\n}\n\n/**\n * Open the TCP+TLS connections to the AWS endpoints at page load, so the\n * Start button does not pay for DNS, the TCP handshake and the TLS handshake\n * on top of the service call itself.",
  "replace": "      logout();\n    });\n    banner.append(text, button);\n  } else {\n    text.textContent = TRANSLATION_CONFIG.enabled\n      ? \"Your sign-in has ended. This call continues, but translation may stop at its next restart. \" +\n        \"You will be asked to sign in when the call ends.\"\n      : \"Your sign-in has ended. This call continues. You will be asked to sign in when the call ends.\";\n    banner.append(text);\n  }\n}\n\n// ── Translation switch (SSM parameter translationEnabled) ───────────────────\n\n// Set when a deploy switched translation off after this page loaded (see onAppVersionChange).\nlet TranslationSwitchedOff = false;\n\n/**\n * True when a translation may start: this environment has voice translation (translationEnabled), and it has not\n * been switched off since the page loaded. Checked by every way a translation can start.\n */\nfunction translationAllowed() {\n  return TRANSLATION_CONFIG.enabled && !TranslationSwitchedOff;\n}\n\n/** For the start functions: false, with a note to the agent, when translation may not start. */\nfunction checkTranslationAllowed(source) {\n  if (translationAllowed()) return true;\n  console.info(`${LOGGER_PREFIX} - ${source} - translation is not enabled here (translationEnabled); not started`);\n  if (TranslationSwitchedOff) showToast(\"Voice translation has been switched off. Reload this page between calls.\", 6000);\n  return false;\n}\n\n/**\n * translationEnabled=false (Wave 1): the app is a plain softphone. The Customer, Agent and Transcription panels\n * stay in place, greyed out (style.css) and inert: nothing in them can be clicked, typed into or reached with the\n * Tab key. Their elements stay in the page because the code looks them up by ID. The CCP, Customer Information\n * and Audio Controls work as usual.\n */\nfunction disableTranslationUI() {\n  document.body.classList.add(\"translation-disabled\");\n  for (const id of [\"divCustomerControls\", \"divAgentControls\", \"divTranscription\"]) {\n    const panel = document.getElementById(id);\n    if (panel) panel.inert = true;\n  }\n}\n\n// ── New version notice ──────────────────────────────────────────────────────\n\nlet AppVersionWatch = null;\n\n/**\n * Every 5 minutes, and after each call, compares the deployed app with the one this page runs. When a deploy\n * changed it (new code, or a setting such as translationEnabled), a banner asks the agent to reload between\n * calls. The page never reloads itself: a reload drops the softphone and signs the agent in again.\n */\nfunction startAppVersionWatch() {\n  if (AppVersionWatch) return;\n  AppVersionWatch = createAppVersionWatch({\n    loadedMainScript: document.querySelector('script[type=\"module\"][src]')?.getAttribute(\"src\") ?? null,\n    loadedConfig: window.WebappConfig ?? null,\n    onChange: onAppVersionChange,\n    log: (message) => console.info(`${LOGGER_PREFIX} - [VERSION] ${message}`),\n  });\n  AppVersionWatch.start();\n}\n\nfunction onAppVersionChange(change) {\n  // Switching translation off takes effect at once: no new translation starts on this page, and calls continue\n  // as plain calls. Switching it on needs the new page, which the banner asks for.\n  TranslationSwitchedOff = change?.translationNowDisabled === true;\n  if (TranslationSwitchedOff) console.warn(`${LOGGER_PREFIX} - [VERSION] translation switched off by a deploy; no new translation will start`);\n  // fix 6's forceBackupTranslation switch is read through the proxy, which a switch-off removes.\n  if (TranslationSwitchedOff) ModePoller?.stop();\n  else if (TRANSLATION_CONFIG.enabled) ModePoller?.start();\n  if (change) showUpdateNotice(change);\n  else document.getElementById(\"updateNotice\")?.remove();\n}\n\nfunction showUpdateNotice({ translationNowEnabled, translationNowDisabled }) {\n  let banner = document.getElementById(\"updateNotice\");\n  if (!banner) {\n    banner = document.createElement(\"div\");\n    banner.id = \"updateNotice\";\n    banner.setAttribute(\"role\", \"status\");\n    Object.assign(banner.style, {\n      position: \"fixed\",\n      bottom: \"16px\",\n      left: \"50%\",\n      transform: \"translateX(-50%)\",\n      zIndex: \"10000\",\n      maxWidth: \"min(640px, calc(100vw - 32px))\",\n      padding: \"10px 14px\",\n      borderRadius: \"6px\",\n      background: \"#e8f1fb\",\n      color: \"#0b3d6e\",\n      border: \"1px solid #8db8e6\",\n      boxShadow: \"0 2px 8px rgba(0, 0, 0, 0.15)\",\n      display: \"flex\",\n      gap: \"12px\",\n      alignItems: \"center\",\n      fontSize: \"14px\",\n    });\n    document.body.appendChild(banner);\n  }\n  banner.replaceChildren();\n  const text = document.createElement(\"span\");\n  text.textContent = translationNowEnabled\n    ? \"Voice translation is now available. Reload this page between calls to start using it.\"\n    : translationNowDisabled\n      ? \"Voice translation has been switched off. Reload this page between calls.\"\n      : \"A new version of this app is available. Reload this page between calls to get it.\";\n  const button = document.createElement(\"button\");\n  button.type = \"button\";\n  button.textContent = \"Reload\";\n  button.addEventListener(\"click\", () => {\n    if (isOnCall()) {\n      showToast(\"Finish the current call first, then reload.\", 5000);\n      return;\n    }\n    window.location.reload();\n  });\n  banner.append(text, button);\n}\n\n/**\n * Open the TCP+TLS connections to the AWS endpoints at page load, so the\n * Start button does not pay for DNS, the TCP handshake and the TLS handshake\n * on top of the service call itself."
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "}\n\nconst onLoad = async () => {\n  console.info(`${LOGGER_PREFIX} - index loaded`);\n  preconnectAwsEndpoints();\n  // fix 6: the forceBackupTranslation switch, refreshed every 30 seconds.\n  startBackupSwitchWatch();\n  bindUIElements();\n  // ── Conversation Transcript panel (separate module) ──\n  initConversationTranscript(\"divTranscriptContainer\");\n  initEventListeners();",
  "replace": "}\n\nconst onLoad = async () => {\n  console.info(`${LOGGER_PREFIX} - index loaded`);\n  console.info(\n    `${LOGGER_PREFIX} - voice translation is ${TRANSLATION_CONFIG.enabled ? \"enabled\" : \"NOT enabled in this environment (translationEnabled=false)\"}`,\n  );\n  if (TRANSLATION_CONFIG.enabled) {\n    preconnectAwsEndpoints();\n    // fix 6: the forceBackupTranslation switch, refreshed every 30 seconds.\n    startBackupSwitchWatch();\n  } else {\n    disableTranslationUI();\n  }\n  startAppVersionWatch();\n  bindUIElements();\n  // ── Conversation Transcript panel (separate module) ──\n  initConversationTranscript(\"divTranscriptContainer\");\n  initEventListeners();"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "  // populateCustomerInfo reads the \"Customer_Preferred_Language\" attribute\n  // and sets the customer language dropdown BEFORE we inspect it below.\n  populateCustomerInfo(contact);\n\n  // Customer button is hidden (controlled by agent buttons) but keep it\n  // internally enabled so customerStartTranscription() can run freely.\n  CCP_V2V.UI.customerStartTranscriptionButton.disabled = false;\n",
  "replace": "  // populateCustomerInfo reads the \"Customer_Preferred_Language\" attribute\n  // and sets the customer language dropdown BEFORE we inspect it below.\n  populateCustomerInfo(contact);\n\n  // Translation off (translationEnabled=false, or switched off since the page loaded): a plain call. Customer\n  // Information above is filled as usual; no translation starts and the Start buttons stay disabled.\n  if (!translationAllowed()) {\n    console.info(`${LOGGER_PREFIX} - onContactConnected - translation not enabled; plain call`);\n    return;\n  }\n\n  // Customer button is hidden (controlled by agent buttons) but keep it\n  // internally enabled so customerStartTranscription() can run freely.\n  CCP_V2V.UI.customerStartTranscriptionButton.disabled = false;\n"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "\n  // If the sign-in session ended during this call, sign out now that it is over. Deferred a moment so the\n  // agent's contact list no longer includes the destroyed contact.\n  setTimeout(completePendingSignOut, 1000);\n}\n\nasync function onAgentLocalMediaStreamCreated(data) {\n  console.info(",
  "replace": "\n  // If the sign-in session ended during this call, sign out now that it is over. Deferred a moment so the\n  // agent's contact list no longer includes the destroyed contact.\n  setTimeout(completePendingSignOut, 1000);\n\n  // A version deployed during the call is offered now that the call is over.\n  AppVersionWatch?.check();\n}\n\nasync function onAgentLocalMediaStreamCreated(data) {\n  console.info("
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": " *   fix 6: start this side on the backup (switch on, a recent Nova Sonic failure, or Nova Sonic did not\n *   start on the agent side).\n */\nasync function customerStartTranscription({ startOnBackup = null } = {}) {\n  // Immediately hide Start and show the Loading button while the session initialises\n  CCP_V2V.UI.customerStartTranscriptionButton.disabled = true;\n  CCP_V2V.UI.customerStartTranscriptionButton.style.display = \"none\";\n  CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = \"\";",
  "replace": " *   fix 6: start this side on the backup (switch on, a recent Nova Sonic failure, or Nova Sonic did not\n *   start on the agent side).\n */\nasync function customerStartTranscription({ startOnBackup = null } = {}) {\n  // Only agentStartTranscription() calls this, after its own translationAllowed() check. A switch-off that\n  // arrives in between must not leave the agent side running without the customer side, so only the\n  // environment's setting is checked here.\n  if (!TRANSLATION_CONFIG.enabled) return;\n  // Immediately hide Start and show the Loading button while the session initialises\n  CCP_V2V.UI.customerStartTranscriptionButton.disabled = true;\n  CCP_V2V.UI.customerStartTranscriptionButton.style.display = \"none\";\n  CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = \"\";"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "  };\n}\n\nasync function agentStartTranscription() {\n  // Immediately hide Start and show the Loading button while the session initialises\n  CCP_V2V.UI.agentStartTranscriptionButton.disabled = true;\n  CCP_V2V.UI.agentStartTranscriptionButton.style.display = \"none\";\n  CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = \"\";",
  "replace": "  };\n}\n\nasync function agentStartTranscription() {\n  if (!checkTranslationAllowed(\"agentStartTranscription\")) return;\n  // Immediately hide Start and show the Loading button while the session initialises\n  CCP_V2V.UI.agentStartTranscriptionButton.disabled = true;\n  CCP_V2V.UI.agentStartTranscriptionButton.style.display = \"none\";\n  CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = \"\";"
 },
 {
  "file": "webapp/main.js",
  "optional": false,
  "find": "}\n\nasync function handleAgentTranslateText() {\n  console.info(\"Inside handleAgentTranslateText().\");\n  const inputText = CCP_V2V.UI.agentTranslateTextInput.value.trim();\n  if (isStringUndefinedNullEmpty(inputText)) return;\n  // updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, inputText);\n",
  "replace": "}\n\nasync function handleAgentTranslateText() {\n  console.info(\"Inside handleAgentTranslateText().\");\n  if (!checkTranslationAllowed(\"handleAgentTranslateText\")) return;\n  const inputText = CCP_V2V.UI.agentTranslateTextInput.value.trim();\n  if (isStringUndefinedNullEmpty(inputText)) return;\n  // updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, inputText);\n"
 },
 {
  "file": "webapp/config.js",
  "optional": false,
  "find": "export const PROXY_CONFIG = {\n  enabled: String(getParamValue(window.WebappConfig.proxyEnabled)) === \"true\",\n};\n\nfunction getParamValue(param) {\n  const SSM_NOT_DEFINED = \"not-defined\";\n  if (param === SSM_NOT_DEFINED) return undefined;\n  return param;",
  "replace": "export const PROXY_CONFIG = {\n  enabled: String(getParamValue(window.WebappConfig.proxyEnabled)) === \"true\",\n};\n\n// Set per environment through the SSM parameter translationEnabled. When false (Wave 1), the app is a plain\n// softphone: the Customer, Agent and Transcription panels are greyed out and nothing starts a translation.\n// The CCP, Customer Information and Audio Controls work as usual. A missing value counts as false.\nexport const TRANSLATION_CONFIG = {\n  enabled: String(getParamValue(window.WebappConfig.translationEnabled)) === \"true\",\n};\n\nfunction getParamValue(param) {\n  const SSM_NOT_DEFINED = \"not-defined\";\n  if (param === SSM_NOT_DEFINED) return undefined;\n  return param;"
 },
 {
  "file": "webapp/style.css",
  "optional": false,
  "find": "#divCustomerControls h6,\n#divAgentControls h6 {\n  justify-content: space-between;\n}",
  "replace": "#divCustomerControls h6,\n#divAgentControls h6 {\n  justify-content: space-between;\n}\n\n/* Translation switched off (translationEnabled=false, Wave 1): main.js adds .translation-disabled to the body\n   and makes the three panels inert. Their contents are greyed out and each title says \"Not enabled yet\".\n   pointer-events is a fallback for browsers without inert. */\nbody.translation-disabled #divCustomerControls,\nbody.translation-disabled #divAgentControls,\nbody.translation-disabled #divTranscription {\n  pointer-events: none;\n  user-select: none;\n}\nbody.translation-disabled #divCustomerControls .control-group-transcribe,\nbody.translation-disabled #divAgentControls .control-group-transcribe,\nbody.translation-disabled #divTranscription .control-group-transcription {\n  opacity: 0.45;\n  filter: grayscale(1);\n}\nbody.translation-disabled #divCustomerControls h6 .panel-settings-btn,\nbody.translation-disabled #divAgentControls h6 .panel-settings-btn,\nbody.translation-disabled #divTranscription .transcription-latency {\n  display: none;\n}\nbody.translation-disabled #divCustomerControls h6 > span:first-child::after,\nbody.translation-disabled #divAgentControls h6 > span:first-child::after,\nbody.translation-disabled #divTranscription h6 > span:first-child::after {\n  content: \"Not enabled yet\";\n  margin-left: 8px;\n  padding: 1px 8px;\n  border-radius: 10px;\n  background: #eef0f2;\n  color: #5f6b7a;\n  font-size: 11px;\n  font-weight: 500;\n  vertical-align: middle;\n}"
 },
 {
  "file": "cdk-stacks/config/config.params.json",
  "optional": false,
  "find": "      \"description\": \"Cognito SAML identity provider name, exactly as shown in the Cognito console, for example: EntraID. Used only when ssoEnabled is true.\",\n      \"defaultValue\": \"EntraID\",\n      \"required\": false\n    },\n    {\n      \"name\": \"proxyEnabled\",\n      \"cliFormat\": \"proxy-enabled\",\n      \"description\": \"true = deploy the server-side proxy (ECS Fargate behind CloudFront) and route every Bedrock, Transcribe, Translate and Polly call through it, so no AWS credentials ever reach the browser; the Cognito identity pool role then gets no permissions. false = the browser calls AWS directly with identity pool credentials.\",\n      \"boolean\": true,\n      \"defaultValue\": false,\n      \"required\": false\n    },",
  "replace": "      \"description\": \"Cognito SAML identity provider name, exactly as shown in the Cognito console, for example: EntraID. Used only when ssoEnabled is true.\",\n      \"defaultValue\": \"EntraID\",\n      \"required\": false\n    },\n    {\n      \"name\": \"translationEnabled\",\n      \"cliFormat\": \"translation-enabled\",\n      \"description\": \"true = agents can use voice translation (Amazon Bedrock Nova Sonic, Transcribe, Translate, Polly). false = the webapp is a plain softphone: the Customer, Agent and Transcription panels are greyed out, no proxy is deployed and no role gets Bedrock, Transcribe, Translate or Polly permissions; the CCP, Customer Information and Audio Controls work as usual. Required, with no default: every environment must choose. Changing it takes a deploy (npm run build:deploy:all); open pages then ask agents to reload between calls.\",\n      \"boolean\": true,\n      \"required\": true\n    },\n    {\n      \"name\": \"proxyEnabled\",\n      \"cliFormat\": \"proxy-enabled\",\n      \"description\": \"Used only when translationEnabled is true. true = deploy the server-side proxy (ECS Fargate behind CloudFront) and route every Bedrock, Transcribe, Translate and Polly call through it, so no AWS credentials ever reach the browser; the Cognito identity pool role then gets no permissions. false = the browser calls AWS directly with identity pool credentials.\",\n      \"boolean\": true,\n      \"defaultValue\": false,\n      \"required\": false\n    },"
 },
 {
  "file": "cdk-stacks/config/ssm-params-util.ts",
  "optional": false,
  "find": "  }\n  return { ...params, SSM_NOT_DEFINED };\n};\n\n/** Region for an optional per-service parameter (transcribeRegion, ...): its own value, else bedrockRegion. */\nexport const serviceRegion = (ssmParams: any, paramName: string): string =>\n  ssmParams[paramName] === ssmParams.SSM_NOT_DEFINED ? ssmParams.bedrockRegion : ssmParams[paramName];\n",
  "replace": "  }\n  return { ...params, SSM_NOT_DEFINED };\n};\n\n/**\n * How voice translation works in this environment, from translationEnabled and proxyEnabled. Every stack decides\n * from this one rule, so the webapp, the proxy and the permissions can never disagree:\n *  - \"off\": translationEnabled is false. The webapp is a plain softphone with the translation panels greyed out,\n *    no proxy is deployed, and no role has Bedrock, Transcribe, Translate or Polly permissions.\n *  - \"proxy\": the server-side proxy makes the AWS calls; the browser gets no AWS permissions.\n *  - \"direct\": the browser calls AWS itself with identity pool credentials.\n */\nexport const translationMode = (ssmParams: any): \"off\" | \"proxy\" | \"direct\" =>\n  !ssmParams.translationEnabled ? \"off\" : ssmParams.proxyEnabled ? \"proxy\" : \"direct\";\n\n/** Region for an optional per-service parameter (transcribeRegion, ...): its own value, else bedrockRegion. */\nexport const serviceRegion = (ssmParams: any, paramName: string): string =>\n  ssmParams[paramName] === ssmParams.SSM_NOT_DEFINED ? ssmParams.bedrockRegion : ssmParams[paramName];\n"
 },
 {
  "file": "cdk-stacks/lib/cdk-backend-stack.ts",
  "optional": false,
  "find": "import * as cdk from \"aws-cdk-lib\";\nimport { Construct } from \"constructs\";\nimport * as ssm from \"aws-cdk-lib/aws-ssm\";\n\nimport { loadSSMParams, serviceRegion, ssmParameterHierarchy } from \"../config/ssm-params-util\";\nconst configParams = require(\"../config/config.params.json\");\n\nimport { CognitoStack, REFRESH_TOKEN_VALIDITY } from \"./infrastructure/cognito-stack\";\nimport { FrontendConfigStack } from \"./frontend/frontend-config-stack\";",
  "replace": "import * as cdk from \"aws-cdk-lib\";\nimport { Construct } from \"constructs\";\nimport * as ssm from \"aws-cdk-lib/aws-ssm\";\n\nimport { loadSSMParams, serviceRegion, ssmParameterHierarchy, translationMode } from \"../config/ssm-params-util\";\nconst configParams = require(\"../config/config.params.json\");\n\nimport { CognitoStack, REFRESH_TOKEN_VALIDITY } from \"./infrastructure/cognito-stack\";\nimport { FrontendConfigStack } from \"./frontend/frontend-config-stack\";"
 },
 {
  "file": "cdk-stacks/lib/cdk-backend-stack.ts",
  "optional": false,
  "find": "    // follows bedrockRegion, so single-region deployments need no extra settings.\n    this.backendStackOutputs.push({ key: \"transcribeRegion\", value: serviceRegion(ssmParams, \"transcribeRegion\") });\n    this.backendStackOutputs.push({ key: \"translateRegion\", value: serviceRegion(ssmParams, \"translateRegion\") });\n    this.backendStackOutputs.push({ key: \"pollyRegion\", value: serviceRegion(ssmParams, \"pollyRegion\") });\n    // Proxy switch for the webapp: when enabled, every AWS call goes through the server-side proxy.\n    this.backendStackOutputs.push({ key: \"proxyEnabled\", value: String(ssmParams.proxyEnabled) });\n    // Lets the webapp warn the agent before their sign-in session ends.\n    this.backendStackOutputs.push({ key: \"refreshTokenValidityHours\", value: String(REFRESH_TOKEN_VALIDITY.toHours()) });\n    // SSO switch for the webapp: when enabled, sign-in goes straight to the SSO provider instead of the\n    // Cognito sign-in page. The identity provider itself is configured in the Cognito console.",
  "replace": "    // follows bedrockRegion, so single-region deployments need no extra settings.\n    this.backendStackOutputs.push({ key: \"transcribeRegion\", value: serviceRegion(ssmParams, \"transcribeRegion\") });\n    this.backendStackOutputs.push({ key: \"translateRegion\", value: serviceRegion(ssmParams, \"translateRegion\") });\n    this.backendStackOutputs.push({ key: \"pollyRegion\", value: serviceRegion(ssmParams, \"pollyRegion\") });\n    // Translation switch for the webapp: false greys out the translation panels and the app is a plain softphone.\n    this.backendStackOutputs.push({ key: \"translationEnabled\", value: String(translationMode(ssmParams) !== \"off\") });\n    // Proxy switch for the webapp: when enabled, every AWS call goes through the server-side proxy. Never true\n    // while translation is off, because the proxy is then not deployed.\n    this.backendStackOutputs.push({ key: \"proxyEnabled\", value: String(translationMode(ssmParams) === \"proxy\") });\n    // Lets the webapp warn the agent before their sign-in session ends.\n    this.backendStackOutputs.push({ key: \"refreshTokenValidityHours\", value: String(REFRESH_TOKEN_VALIDITY.toHours()) });\n    // SSO switch for the webapp: when enabled, sign-in goes straight to the SSO provider instead of the\n    // Cognito sign-in page. The identity provider itself is configured in the Cognito console."
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "\nimport { FrontendS3DeploymentStack } from \"../lib/frontend/frontend-s3-deployment-stack\";\nimport { FrontendConfigStack } from \"./frontend/frontend-config-stack\";\nimport { ProxyStack } from \"./proxy/proxy-stack\";\nimport { loadSSMParams, optionalParamDefault, ssmParameterHierarchy } from \"../config/ssm-params-util\";\n\nconst configParams = require(\"../config/config.params.json\");\n\n/**",
  "replace": "\nimport { FrontendS3DeploymentStack } from \"../lib/frontend/frontend-s3-deployment-stack\";\nimport { FrontendConfigStack } from \"./frontend/frontend-config-stack\";\nimport { ProxyStack } from \"./proxy/proxy-stack\";\nimport { loadSSMParams, optionalParamDefault, ssmParameterHierarchy, translationMode } from \"../config/ssm-params-util\";\n\nconst configParams = require(\"../config/config.params.json\");\n\n/**"
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "  };\n  const cognito = `https://${ssmParams.cognitoDomainPrefix}.auth.${region}.amazoncognito.com`;\n  const connect = originOf(ssmParams.connectInstanceURL);\n  const connectSignalling = `wss://*.connect-telecom.${ssmParams.connectInstanceRegion}.amazonaws.com`;\n  const directModeAws = ssmParams.proxyEnabled ? [] : [\"https://*.amazonaws.com\", \"wss://*.amazonaws.com:8443\"];\n  const directives = [\n    \"default-src 'self'\",\n    \"script-src 'self'\",\n    // Inline style attributes in index.html, and styles set by Bootstrap and the CCP library.",
  "replace": "  };\n  const cognito = `https://${ssmParams.cognitoDomainPrefix}.auth.${region}.amazoncognito.com`;\n  const connect = originOf(ssmParams.connectInstanceURL);\n  const connectSignalling = `wss://*.connect-telecom.${ssmParams.connectInstanceRegion}.amazonaws.com`;\n  const directModeAws = translationMode(ssmParams) === \"direct\" ? [\"https://*.amazonaws.com\", \"wss://*.amazonaws.com:8443\"] : [];\n  const directives = [\n    \"default-src 'self'\",\n    \"script-src 'self'\",\n    // Inline style attributes in index.html, and styles set by Bootstrap and the CCP library."
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "    });\n\n    // Server-side proxy (proxyEnabled): served from this distribution at /ws (WebSocket) and /api/*, so\n    // the webapp reaches it on its own origin - no CORS, and one TLS endpoint for everything.\n    const ssmParams = loadSSMParams(this);\n    const proxyBehaviors: Record<string, cloudfront.BehaviorOptions> = {};\n    if (ssmParams.proxyEnabled) {\n      const proxyStack = new ProxyStack(this, \"ProxyStack\", {\n        cdkAppName: configParams[\"CdkAppName\"],\n        ssmParams,\n        userPoolId: props.userPoolId,",
  "replace": "    });\n\n    // Server-side proxy (proxyEnabled): served from this distribution at /ws (WebSocket) and /api/*, so\n    // the webapp reaches it on its own origin - no CORS, and one TLS endpoint for everything.\n    // Not deployed while translation is off (translationEnabled=false), whatever proxyEnabled says.\n    const ssmParams = loadSSMParams(this);\n    const proxyBehaviors: Record<string, cloudfront.BehaviorOptions> = {};\n    if (translationMode(ssmParams) === \"proxy\") {\n      const proxyStack = new ProxyStack(this, \"ProxyStack\", {\n        cdkAppName: configParams[\"CdkAppName\"],\n        ssmParams,\n        userPoolId: props.userPoolId,"
 },
 {
  "file": "cdk-stacks/lib/cdk-frontend-stack.ts",
  "optional": false,
  "find": "      cdkAppName: configParams[\"CdkAppName\"],\n      webAppBucket: webAppBucket,\n      backendStackOutputs: props.backendStackOutputs,\n    });\n\n    /**************************************************************************************************************\n     * CDK Outputs *\n     **************************************************************************************************************/",
  "replace": "      cdkAppName: configParams[\"CdkAppName\"],\n      webAppBucket: webAppBucket,\n      backendStackOutputs: props.backendStackOutputs,\n    });\n    // Both write frontend-config.js. The webapp copy waits for the settings to be written, so a deploy can\n    // never finish with the previous settings in it.\n    frontendS3DeploymentStack.webAppDeployment.node.addDependency(frontendConfigStack);\n\n    /**************************************************************************************************************\n     * CDK Outputs *\n     **************************************************************************************************************/"
 },
 {
  "file": "cdk-stacks/lib/infrastructure/cognito-stack.ts",
  "optional": false,
  "find": "import * as cdk from \"aws-cdk-lib\";\nimport * as iam from \"aws-cdk-lib/aws-iam\";\nimport * as cognito from \"aws-cdk-lib/aws-cognito\";\nimport { Construct } from \"constructs\";\nimport { serviceRegion } from \"../../config/ssm-params-util\";\n\n/** How long a sign-in lasts before the agent must sign in again (refresh token lifetime). */\nexport const REFRESH_TOKEN_VALIDITY = cdk.Duration.hours(12);\n",
  "replace": "import * as cdk from \"aws-cdk-lib\";\nimport * as iam from \"aws-cdk-lib/aws-iam\";\nimport * as cognito from \"aws-cdk-lib/aws-cognito\";\nimport { Construct } from \"constructs\";\nimport { serviceRegion, translationMode } from \"../../config/ssm-params-util\";\n\n/** How long a sign-in lasts before the agent must sign in again (refresh token lifetime). */\nexport const REFRESH_TOKEN_VALIDITY = cdk.Duration.hours(12);\n"
 },
 {
  "file": "cdk-stacks/lib/infrastructure/cognito-stack.ts",
  "optional": false,
  "find": "    // calls themselves (GetId, GetCredentialsForIdentity) need no IAM permission.\n    //\n    // Proxy mode: the proxy's task role makes those calls instead and the browser never requests\n    // credentials, so this role gets no permissions at all.\n    if (!props.SSMParams.proxyEnabled) {\n      const inRegion = (paramName: string) => ({\n        StringEquals: { \"aws:RequestedRegion\": serviceRegion(props.SSMParams, paramName) },\n      });\n      authenticatedRole.addToPolicy(",
  "replace": "    // calls themselves (GetId, GetCredentialsForIdentity) need no IAM permission.\n    //\n    // Proxy mode: the proxy's task role makes those calls instead and the browser never requests\n    // credentials, so this role gets no permissions at all.\n    //\n    // Translation off (translationEnabled=false): no permissions either. Greying out the panels is not a\n    // control on its own; without these permissions no translation call can succeed from the browser.\n    if (translationMode(props.SSMParams) === \"direct\") {\n      const inRegion = (paramName: string) => ({\n        StringEquals: { \"aws:RequestedRegion\": serviceRegion(props.SSMParams, paramName) },\n      });\n      authenticatedRole.addToPolicy("
 },
 {
  "file": "cdk-stacks/lib/frontend/frontend-s3-deployment-stack.ts",
  "optional": false,
  "find": "}\n \nexport class FrontendS3DeploymentStack extends cdk.NestedStack {\n  public readonly webAppBucket: s3.IBucket;\n \n  constructor(scope: Construct, id: string, props: FrontendS3DeploymentStackProps) {\n    super(scope, id, props);\n \n    const webAppDeployment = new s3deployment.BucketDeployment(scope, `${props.cdkAppName}-WebAppDeployment`, {\n      destinationBucket: props.webAppBucket,\n      retainOnDelete: false,\n      destinationKeyPrefix: configParams[\"WebAppRootPrefix\"],\n      sources: [\n        s3deployment.Source.asset(\"../webapp/dist\"),\n        s3deployment.Source.bucket(props.webAppBucket, `${configParams[\"WebAppStagingPrefix\"]}frontend-config.zip`),\n      ],",
  "replace": "}\n \nexport class FrontendS3DeploymentStack extends cdk.NestedStack {\n  public readonly webAppBucket: s3.IBucket;\n  public readonly webAppDeployment: s3deployment.BucketDeployment;\n\n  constructor(scope: Construct, id: string, props: FrontendS3DeploymentStackProps) {\n    super(scope, id, props);\n\n    this.webAppDeployment = new s3deployment.BucketDeployment(scope, `${props.cdkAppName}-WebAppDeployment`, {\n      destinationBucket: props.webAppBucket,\n      retainOnDelete: false,\n      destinationKeyPrefix: configParams[\"WebAppRootPrefix\"],\n      // Browsers check with CloudFront on every page load, so a deploy (new code, or a setting such as\n      // translationEnabled) reaches an agent at their next reload. A file that has not changed is not downloaded\n      // again.\n      cacheControl: [s3deployment.CacheControl.noCache()],\n      // Keep the previous build's files. A page that is already open loads parts of the app later (the AWS SDK\n      // clients and the audio worklets, under names that change with every build); deleting them would break\n      // translation on that page until the agent reloads.\n      prune: false,\n      sources: [\n        s3deployment.Source.asset(\"../webapp/dist\"),\n        s3deployment.Source.bucket(props.webAppBucket, `${configParams[\"WebAppStagingPrefix\"]}frontend-config.zip`),\n      ],"
 },
 {
  "file": "cdk-stacks/lambdas/custom-resources/frontend-config/index.py",
  "optional": false,
  "find": "    s3.upload_file(zip_file_complete, bucket_name,\n                   f\"{web_app_staging_object_prefix}{zip_file_name}\")\n\n    # upload to WebAppRoot\n    root_object_url = f\"s3://{bucket_name}/{web_app_root_object_prefix}{object_key}\"\n    logger.info(f\"Uploading frontend config to {root_object_url}\")\n    s3.upload_file(raw_file_complete, bucket_name,\n                   f\"{web_app_root_object_prefix}{object_key}\", ExtraArgs={'Metadata': {'ContentType': object_content_type}})\n\n    shutil.rmtree(workdir)\n\n",
  "replace": "    s3.upload_file(zip_file_complete, bucket_name,\n                   f\"{web_app_staging_object_prefix}{zip_file_name}\")\n\n    # upload to WebAppRoot\n    # ContentType must be the object's real Content-Type (it was user metadata, so S3 served the file as\n    # binary/octet-stream, which browsers refuse to run as a script under X-Content-Type-Options: nosniff).\n    # no-cache: browsers check with CloudFront on every page load, so changed settings reach agents on reload.\n    root_object_url = f\"s3://{bucket_name}/{web_app_root_object_prefix}{object_key}\"\n    logger.info(f\"Uploading frontend config to {root_object_url}\")\n    s3.upload_file(raw_file_complete, bucket_name,\n                   f\"{web_app_root_object_prefix}{object_key}\",\n                   ExtraArgs={'ContentType': object_content_type, 'CacheControl': 'no-cache'})\n\n    shutil.rmtree(workdir)\n\n"
 },
 {
  "file": "SETUP.md",
  "optional": true,
  "find": "3. Deploy: `npm run build:deploy:all` (On Windows devices use `npm run build:deploy:all:gitbash`)\n\nSetting `proxy-enabled` back to `false` and redeploying returns the Webapp to direct calls.\n\n## Clean up\n\nTo remove the solution from your account, please follow these steps:\n",
  "replace": "3. Deploy: `npm run build:deploy:all` (On Windows devices use `npm run build:deploy:all:gitbash`)\n\nSetting `proxy-enabled` back to `false` and redeploying returns the Webapp to direct calls.\n\n## Translation switch (`translation-enabled`)\n\n`translation-enabled` (SSM parameter `<hierarchy>translationEnabled`) is required and has no default, so every environment must choose `true` or `false`; a deploy without it stops with an error.\n\n- `false`: the Webapp is a plain softphone. The CCP, Customer Information and Audio Controls work as usual; the Customer, Agent and Transcription panels are greyed out and cannot be used. No proxy is deployed (whatever `proxy-enabled` says), the Cognito identity pool role gets no Bedrock, Transcribe, Translate or Polly permissions, and the Content Security Policy allows no AWS service endpoints.\n- `true`: voice translation is available, through the proxy when `proxy-enabled` is `true`, else with direct calls from the browser.\n\nTo change it, set the parameter and deploy (`npm run build:deploy:all`). The Webapp URL does not change. Open pages compare themselves with the deployed version every 5 minutes and after each call, and show a banner asking the agent to reload between calls. Switching translation off also stops new translations on open pages at once; calls continue as plain calls.\n\nFor an infrastructure-as-code port of these stacks (for example Terraform), the switch must produce the same result:\n\n- `frontend-config.js` contains `\"translationEnabled\": \"true\"` or `\"false\"`, and `\"proxyEnabled\": \"false\"` whenever translation is off. It is served with `Content-Type: text/javascript` (the CloudFront headers include `X-Content-Type-Options: nosniff`, so any other type stops the page loading) and `Cache-Control: no-cache`, as is `index.html`.\n- With translation off: no proxy resources and no `/ws` or `/api/*` CloudFront behaviours, no Bedrock, Transcribe, Translate or Polly permissions on the identity pool role, and no `*.amazonaws.com` entries in the Content Security Policy.\n- Files from earlier builds are kept in the Webapp bucket (no pruning), because a page that is already open loads parts of the app later.\n\n## Clean up\n\nTo remove the solution from your account, please follow these steps:\n"
 },
 {
  "file": "proxy/README.md",
  "optional": true,
  "find": "BEDROCK_REGION=us-east-1 NOVA_MODEL_ID=amazon.nova-2-sonic-v1:0 \\\nALLOWED_ORIGINS=https://localhost:5173 npm start\n```\n\nThen run the Webapp with `npm run dev` in `webapp` and `proxyEnabled: true` in `webapp/frontend-config.js`. The Vite dev server forwards `/ws` and `/api` to `http://localhost:8080` (override with `V2V_PROXY_TARGET`).\n\n## Latency benchmark\n\n[bench/latency.mjs](bench/latency.mjs) streams the same speech in real time through both paths and reports median and p90 values:",
  "replace": "BEDROCK_REGION=us-east-1 NOVA_MODEL_ID=amazon.nova-2-sonic-v1:0 \\\nALLOWED_ORIGINS=https://localhost:5173 npm start\n```\n\nThen run the Webapp with `npm run dev` in `webapp` and `proxyEnabled: \"true\"` and `translationEnabled: \"true\"` in `webapp/frontend-config.js`. The Vite dev server forwards `/ws` and `/api` to `http://localhost:8080` (override with `V2V_PROXY_TARGET`).\n\n## Latency benchmark\n\n[bench/latency.mjs](bench/latency.mjs) streams the same speech in real time through both paths and reports median and p90 values:"
 }
];

const EXPECTED = {
 "webapp/main.js": "6151be8cd54d835cbcfb17c9204ffac3d8e8220fe90f0e75c8c6ffba45f76ad3",
 "webapp/config.js": "9243c04c847d7b1b921654f8818a3a3906e6203ef78e2fffbc30a69c3d6c2410",
 "webapp/style.css": "e5867a3a7618345c54a41d7216a5c4eb798e34718133c055f2222b9d71c66678",
 "cdk-stacks/config/config.params.json": "29bdb2594e80897bd05efb856ebf299090c7fbe7d068c78123bbe0ba26e05494",
 "cdk-stacks/config/ssm-params-util.ts": "1da73b6824bd3fae298c6a47ac23bbfc4873709a88b748b712fc6db414cad94e",
 "cdk-stacks/lib/cdk-backend-stack.ts": "75a89fd86f95cbdbc17568fea89a38c699464106490e46ac20edf80384c6a95d",
 "cdk-stacks/lib/cdk-frontend-stack.ts": "29a1d3a89a9482b2e44e4249066ae786338ebb332f86c466fe4da0ca1e27f814",
 "cdk-stacks/lib/infrastructure/cognito-stack.ts": "4b45f5426cbc7f6d9ca1ce74592aa5b974d72b83f25a2af8be181d500cf83064",
 "cdk-stacks/lib/frontend/frontend-s3-deployment-stack.ts": "8876637ad5aa98e8d3282349797f61743bb626b1e3c9aee7d2bd17422b4264e3",
 "cdk-stacks/lambdas/custom-resources/frontend-config/index.py": "3dd10540a66c8fe472787d9baabf174d28d5412bd4f3f106c22aad06d3e6fa10",
 "SETUP.md": "677978d03bb2e5610850dbb6053afc7a6a1238b8652bef4f2c603c263f52fe7f",
 "proxy/README.md": "3185de6b45553629dc35929af49886ef96bfc9feeea2ea1f727b6e0867261726",
 "webapp/utils/appVersionWatch.js": "d88cc5e6601d0a73e9baa7cee50971a005a55541f8cf6ba2dcc59ef9a781ba78"
};

// Detects a copy damaged in transfer (cut short, or saved in a non-UTF-8 encoding).
const INTEGRITY = "24f98d1716cf64c997ba60f32e0a2373c0f1c06a66c2b0ed0b0677d83d85fc36";
const actual = crypto.createHash("sha256").update(JSON.stringify({ newFiles: NEW_FILES, edits: EDITS, expected: EXPECTED })).digest("hex");
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
// The tested version of a file: its text with LF line endings and no final newline.
const fingerprint = (text) => crypto.createHash("sha256").update(text.replace(/\r\n/g, "\n").replace(/\n+$/, "")).digest("hex");

if (!fs.existsSync("cdk-stacks") || !fs.existsSync("webapp") || !fs.existsSync("proxy")) {
  exit(1, ["Run this from the project root: the folder that contains cdk-stacks, webapp and proxy.", `Current folder: ${process.cwd()}`]);
}

const problems = [];
const notes = [];
const skipped = new Set();
const edited = new Map(); // file -> { raw, eol, text, count, already }

for (const e of EDITS) {
  let entry = edited.get(e.file);
  if (!entry) {
    if (!fs.existsSync(e.file)) {
      const note = `${e.file}: file not found${e.optional ? " (optional, skipped)" : ""}`;
      if (e.optional) skipped.add(e.file);
      const list = e.optional ? notes : problems;
      if (!list.includes(note)) list.push(note);
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
    if (e.optional) skipped.add(e.file);
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
    "Your copy of these files differs from the one the changes were made against (fixes 4, 5, 6 and 7 applied).",
    "If fix 7 is not applied yet, apply and deploy it first.",
    "Send these files to be merged.",
  ]);
}

// An optional file with a block that did not match keeps its original text entirely.
for (const file of skipped) edited.delete(file);

// Compare each resulting file with the version the tests ran against.
const differing = [];
for (const [file, v] of edited) {
  if (fingerprint(v.text) !== EXPECTED[file]) differing.push(file);
}
const matchLine = differing.length
  ? [
      `These files will contain every change, but also differ from the tested version elsewhere (your own changes`,
      `there are kept): ${differing.join(", ")}`,
    ]
  : [`Every changed file will match the tested version exactly (${edited.size + Object.keys(NEW_FILES).length} files).`];

const editFiles = [...edited].filter(([, v]) => v.count > 0);
const alreadyAll = editFiles.length === 0 && creates.length === 0 && overwrites.length === 0;
const summary = [
  ...(creates.length ? [`New files to create: ${creates.length} (${creates.join(", ")})`] : []),
  ...(overwrites.length ? [`New files that already exist with different content (will be overwritten): ${overwrites.length}`, ...overwrites.map((f) => "  - " + f)] : []),
  `Existing files to edit: ${editFiles.length} (25 edits in total)`,
  ...editFiles.map(([f, v]) => `  - ${f} (${v.count} edit${v.count > 1 ? "s" : ""}${v.already ? `, ${v.already} already applied` : ""})`),
  ...notes.map((n) => "Note: " + n),
  ...matchLine,
];

// The SSM name of the new required parameter, as the CDK app will look it up.
let hierarchy = "<your SSM hierarchy>/";
try {
  const base = (process.env.SSM_PARAMETERS_HIERARCHY || "").trim() || JSON.parse(fs.readFileSync("cdk-stacks/config/config.params.json", "utf8")).hierarchy || "/";
  hierarchy = base.endsWith("/") ? base : `${base}/`;
} catch (_) {
  // config.params.json unreadable: keep the placeholder.
}
const parameterSteps = [
  "Before the next deploy, the new REQUIRED parameter must exist in this account and Region (a deploy without it",
  "stops with an error). Create it once per environment, from the same Region as the stacks:",
  `  where translation is in use (Dev):  aws ssm put-parameter --type String --name "${hierarchy}translationEnabled" --value true`,
  `  Wave 1 (UI only):                    aws ssm put-parameter --type String --name "${hierarchy}translationEnabled" --value false`,
  "  To change it later, add --overwrite, then deploy again. With false, set proxyEnabled to false as well (the proxy",
  "  is not deployed either way, but then the settings say what they do).",
];

if (alreadyAll) {
  exit(0, ["NOTHING TO DO - fix 8 is already applied to this copy.", ...matchLine, "", ...parameterSteps]);
}

if (!applyMode) {
  exit(0, ["CHECK PASSED - nothing was changed.", ...summary, "", ...parameterSteps, "", "Run again with --apply to make these changes: node apply-v2v-fix-8.cjs --apply"]);
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
  "Next, in CloudShell (after running this script there too):",
  ...parameterSteps.map((line) => "  " + line),
  "  Then: cd cdk-stacks && npm run build:deploy:all",
  "  Then check https://<your app URL>/frontend-config.js: it shows \"translationEnabled\":\"true\" (or \"false\").",
  "Fix 8 changes webapp and CDK files (nothing in the proxy's code). Agents get the new version when they reload",
  "the page; from now on open pages ask them to, between calls. A call in progress keeps the version it started with.",
]);
