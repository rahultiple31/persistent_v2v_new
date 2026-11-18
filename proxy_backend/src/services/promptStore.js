// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { GetParameterCommand } from "@aws-sdk/client-ssm";
import { errorFields } from "../logger.js";
import { BUILT_IN_TEMPLATES, PROMPT_LANGUAGES, checkTemplate, fillPrompt, promptLanguageFor } from "../prompts/builtinPrompts.js";

/** The version name reported for a built-in prompt. */
export const BUILT_IN = "built-in";

const sleep = (ms) =>
  new Promise((resolve) => {
    setTimeout(resolve, ms).unref?.();
  });

/**
 * Reads the approved version number of a promptVersions value: a whole number from 1, or digits in a string.
 * Returns null for anything else.
 */
function versionNumber(value) {
  if (typeof value === "string" && /^\d{1,6}$/.test(value.trim())) value = Number(value.trim());
  return Number.isInteger(value) && value > 0 ? value : null;
}

/**
 * The interpreter system prompts, kept in Parameter Store so they can change without a release.
 *
 *   <promptPrefix><language>   SecureString, one per prompt language (en es fr de it pt). Every save is a new
 *                              version; an edit is not used until it is approved.
 *   <versionsParameter>        String, the approved version of each: {"en":1,"es":3,...}. Changing a number
 *                              is the approval (or the rollback); a language left out uses the built-in prompt.
 *
 * Both are read every refreshMs, so a change applies to new sessions within about that time. Each prompt
 * version is read once and kept. A version that cannot be read, or that fails checkTemplate, is not used:
 * the language keeps its last good prompt (or the built-in one) and a warning is logged.
 *
 * Without an SSM client or the two names, every call uses the built-in prompts.
 *
 * @param {object} opts
 * @param {{send(command): Promise<any>}|null} [opts.ssm]
 * @param {string|null} [opts.versionsParameter]  full name of the promptVersions parameter
 * @param {string|null} [opts.promptPrefix]       the prompts' names without the language, ending in "/"
 */
export function createPromptStore({ ssm = null, versionsParameter = null, promptPrefix = null, refreshMs = 30_000, startWaitMs = 5_000, logger }) {
  const enabled = Boolean(ssm && versionsParameter && promptPrefix);
  /** language -> { version, template }, for each language using an approved stored prompt */
  const inUse = new Map();
  /** problem key -> true: each problem is logged once, until it is fixed */
  const reported = new Set();
  let timer = null;
  let running = null;

  function reportOnce(key, level, message, fields) {
    if (reported.has(key)) return;
    reported.add(key);
    logger[level](message, fields);
  }

  function resolved(prefix) {
    for (const key of reported) if (key.startsWith(prefix)) reported.delete(key);
  }

  /** The approved versions, or null when they cannot be read (the prompts in use then stay as they are). */
  async function readVersions() {
    let value;
    try {
      const result = await ssm.send(new GetParameterCommand({ Name: versionsParameter }));
      value = result?.Parameter?.Value ?? "";
    } catch (err) {
      if (err?.name === "ParameterNotFound") {
        reportOnce("versions:missing", "info", "prompt versions parameter not found: every language uses the built-in prompt", { versionsParameter });
        resolved("versions:read");
        return {};
      }
      reportOnce("versions:read", "warn", "could not read the prompt versions; keeping the prompts in use", { versionsParameter, ...errorFields(err) });
      return null;
    }
    resolved("versions:read");
    resolved("versions:missing");

    let parsed;
    try {
      parsed = value.trim() ? JSON.parse(value) : {};
    } catch {
      parsed = undefined;
    }
    if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) {
      reportOnce(`versions:invalid:${value}`, "warn", 'prompt versions are not a JSON object such as {"en":1,"es":2}; keeping the prompts in use', {
        versionsParameter,
      });
      return null;
    }
    resolved("versions:invalid");

    const versions = {};
    for (const [language, raw] of Object.entries(parsed)) {
      if (!PROMPT_LANGUAGES.includes(language)) {
        reportOnce(`versions:language:${language}`, "warn", "prompt versions name a language with no prompt; ignored", {
          language,
          promptLanguages: PROMPT_LANGUAGES,
        });
        continue;
      }
      const version = versionNumber(raw);
      if (version == null) {
        reportOnce(`versions:number:${language}:${raw}`, "warn", "prompt version is not a whole number from 1; keeping this language's prompt", {
          language,
          value: raw,
        });
        versions[language] = undefined; // keep what is in use
        continue;
      }
      versions[language] = version;
    }
    return versions;
  }

  /** One stored prompt version's text, or null if it cannot be read or fails the checks. */
  async function readPrompt(language, version) {
    const name = `${promptPrefix}${language}`;
    const key = `prompt:${language}:${version}`;
    let template;
    try {
      const result = await ssm.send(new GetParameterCommand({ Name: `${name}:${version}`, WithDecryption: true }));
      template = result?.Parameter?.Value;
    } catch (err) {
      reportOnce(key, "warn", "could not read the approved prompt version; keeping this language's prompt in use", {
        parameterName: name,
        language,
        version,
        ...errorFields(err),
      });
      return null;
    }
    const check = checkTemplate(template);
    if (!check.ok) {
      reportOnce(key, "warn", "approved prompt version rejected; keeping this language's prompt in use", {
        parameterName: name,
        language,
        version,
        reason: check.reason,
      });
      return null;
    }
    resolved(`prompt:${language}:`);
    return template;
  }

  async function update() {
    const versions = await readVersions();
    if (!versions) return;
    for (const language of PROMPT_LANGUAGES) {
      if (language in versions && versions[language] === undefined) continue; // invalid number: keep
      const wanted = versions[language] ?? null;
      const current = inUse.get(language)?.version ?? null;
      if (wanted === current) continue;
      if (wanted == null) {
        inUse.delete(language);
        resolved(`prompt:${language}:`);
        logger.info("prompt version in use", { language, version: BUILT_IN, previous: current });
        continue;
      }
      const template = await readPrompt(language, wanted);
      if (template == null) continue;
      inUse.set(language, { version: wanted, template });
      logger.info("prompt version in use", { language, version: wanted, previous: current ?? BUILT_IN });
    }
  }

  /** Reads the approved versions and any newly approved prompt. Never throws; never runs twice at once. */
  function refresh() {
    if (!enabled) return Promise.resolve();
    running ??= update()
      .catch((err) => logger.error("prompt refresh failed", errorFields(err)))
      .finally(() => {
        running = null;
      });
    return running;
  }

  return {
    get enabled() {
      return enabled;
    },

    /**
     * Reads the prompts now and every refreshMs after. Resolves when the first read is done, or after
     * startWaitMs at most (the built-in prompts are used until it is). Never throws.
     */
    start() {
      if (!enabled || timer) return Promise.resolve();
      timer = setInterval(() => {
        refresh();
      }, refreshMs);
      timer.unref?.();
      return Promise.race([refresh(), sleep(startWaitMs)]);
    },

    stop() {
      clearInterval(timer);
      timer = null;
    },

    refresh,

    /**
     * The system prompt for one Nova Sonic session.
     * @param {{source: string, target: string, mode: "speech"|"typed"}} call
     * @returns {{text: string, language: string, version: number|string}} version: the approved version
     *   number, or BUILT_IN
     */
    resolve({ source, target, mode }) {
      const language = promptLanguageFor(target);
      const stored = inUse.get(language);
      return {
        text: fillPrompt(stored?.template ?? BUILT_IN_TEMPLATES[language], { promptLanguage: language, source, target, mode }),
        language,
        version: stored?.version ?? BUILT_IN,
      };
    },

    /** The version in use for each prompt language, for the log. */
    versions() {
      return Object.fromEntries(PROMPT_LANGUAGES.map((language) => [language, inUse.get(language)?.version ?? BUILT_IN]));
    },
  };
}
