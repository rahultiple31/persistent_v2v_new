// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

// Notices when the deployed app differs from the one this page is running: new code (index.html points to
// a different main script) or new settings (frontend-config.js differs, for example translationEnabled switched
// on). Agents keep the page open all day, so without this a deploy would only reach them at their next sign-in.
// It only reads two small files from the app's own origin; it never reloads the page itself.

export const VERSION_CHECK_INTERVAL_MS = 5 * 60 * 1000;

/** The settings object in a frontend-config.js text ("window.WebappConfig = {...}"), or null if it is not one. */
export function parseWebappConfig(text) {
  const match = /window\.WebappConfig\s*=\s*(\{[\s\S]*\})\s*;?\s*$/.exec(String(text ?? ""));
  if (!match) return null;
  try {
    const value = JSON.parse(match[1]);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

/** The src of the first module script in an index.html text (the app's own code), or null if there is none. */
export function mainScriptOf(html) {
  for (const tag of String(html ?? "").match(/<script\b[^>]*>/gi) ?? []) {
    if (!/\btype\s*=\s*["']module["']/i.test(tag)) continue;
    const src = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(tag);
    if (src) return src[1];
  }
  return null;
}

/** True when both settings objects have the same keys and values, in any order. */
export function sameConfig(a, b) {
  const normalise = (config) =>
    JSON.stringify(
      Object.keys(config)
        .sort()
        .map((key) => [key, String(config[key])]),
    );
  return normalise(a) === normalise(b);
}

const translationOn = (config) => String(config?.translationEnabled) === "true";

async function fetchFresh(url) {
  const response = await fetch(url, { cache: "no-store", credentials: "same-origin" });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.text();
}

/**
 * Compares the deployed app with the loaded one every intervalMs, and whenever check() is called. onChange gets
 * { codeChanged, configChanged, translationNowEnabled, translationNowDisabled } when a different version is
 * deployed (once per version), and null when the deployed version matches the loaded one again. A file that
 * cannot be fetched or read is ignored: no notice is better than a false one.
 */
export function createAppVersionWatch({
  loadedMainScript,
  loadedConfig,
  onChange,
  log = () => {},
  fetchText = fetchFresh,
  intervalMs = VERSION_CHECK_INTERVAL_MS,
  setIntervalFn = (fn, ms) => setInterval(fn, ms),
  clearIntervalFn = (id) => clearInterval(id),
}) {
  let timer = null;
  let checking = false;
  let reported = null; // the deployed version last reported to onChange

  async function check() {
    if (checking) return;
    checking = true;
    try {
      const [html, configText] = await Promise.all([fetchText("/index.html"), fetchText("/frontend-config.js")]);
      const deployedScript = mainScriptOf(html);
      const deployedConfig = parseWebappConfig(configText);
      if (deployedScript == null || deployedConfig == null) {
        log("deployed version could not be read; checking again later");
        return;
      }
      const codeChanged = loadedMainScript != null && deployedScript !== loadedMainScript;
      const configChanged = loadedConfig != null && !sameConfig(deployedConfig, loadedConfig);
      if (!codeChanged && !configChanged) {
        if (reported !== null) {
          reported = null;
          log("deployed version matches this page again");
          onChange(null);
        }
        return;
      }
      const version = `${deployedScript}\n${JSON.stringify(deployedConfig)}`;
      if (version === reported) return;
      reported = version;
      const change = {
        codeChanged,
        configChanged,
        translationNowEnabled: !translationOn(loadedConfig) && translationOn(deployedConfig),
        translationNowDisabled: translationOn(loadedConfig) && !translationOn(deployedConfig),
      };
      log(
        `a new version is deployed (${[codeChanged && "code", configChanged && "settings"].filter(Boolean).join(" and ")} changed` +
          `${change.translationNowEnabled ? ", translation switched on" : ""}${change.translationNowDisabled ? ", translation switched off" : ""})`,
      );
      onChange(change);
    } catch (error) {
      log(`version check failed (${error?.message ?? error}); checking again later`);
    } finally {
      checking = false;
    }
  }

  return {
    check,
    start() {
      if (timer == null) timer = setIntervalFn(check, intervalMs);
    },
    stop() {
      if (timer != null) clearIntervalFn(timer);
      timer = null;
    },
  };
}
