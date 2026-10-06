// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import { PHONE_COUNTRY_CODE_LANGUAGE_MAP, NOVA_INTERPRETER_LANGUAGES } from "../constants";
import { LOGGER_PREFIX } from "../constants";

/**
 * Parses an E.164 phone number (e.g. "+919876543210") and returns the
 * matching NOVA_INTERPRETER_LANGUAGES code (e.g. "hi" for India).
 *
 * The map is already ordered longest-prefix first, so the first match
 * is always the most specific one — no ambiguity between e.g. +1 and +1868.
 *
 * @param {string} phoneNumber - E.164 formatted phone number from Amazon Connect
 * @returns {string|null} - Language code (e.g. "hi", "es", "en") or null if not found
 */
export function getLanguageCodeFromPhoneNumber(phoneNumber) {
  if (!phoneNumber || typeof phoneNumber !== "string") {
    console.warn(`${LOGGER_PREFIX} - getLanguageCodeFromPhoneNumber - invalid phone number:`, phoneNumber);
    return null;
  }

  // Normalise: strip spaces/dashes, ensure leading +
  const normalised = phoneNumber.replace(/[\s\-().]/g, "");

  if (!normalised.startsWith("+")) {
    console.warn(`${LOGGER_PREFIX} - getLanguageCodeFromPhoneNumber - phone number is not in E.164 format:`, phoneNumber);
    return null;
  }

  // Walk the map (longest prefix first) and return on first match
  for (const { prefix, language } of PHONE_COUNTRY_CODE_LANGUAGE_MAP) {
    if (normalised.startsWith(prefix)) {
      console.info(`${LOGGER_PREFIX} - getLanguageCodeFromPhoneNumber - matched prefix "${prefix}" → language "${language}" for number "${normalised}"`);
      return language;
    }
  }

  console.warn(`${LOGGER_PREFIX} - getLanguageCodeFromPhoneNumber - no language mapping found for number:`, normalised);
  return null;
}

/**
 * Checks whether a given language code exists as an option in the
 * NOVA_INTERPRETER_LANGUAGES list (i.e. is loaded into the dropdown).
 *
 * @param {string} languageCode - e.g. "hi", "es", "zh-TW"
 * @returns {boolean}
 */
export function isLanguageSupported(languageCode) {
  return NOVA_INTERPRETER_LANGUAGES.some(({ code }) => code === languageCode);
}

/**
 * Given a phone number, sets the customer "translate from" language
 * dropdown to the detected language and persists it to localStorage.
 *
 * Silently does nothing if:
 *  - phone number cannot be mapped to a language
 *  - the mapped language is not present in the dropdown options
 *
 * @param {string} phoneNumber        - E.164 phone number from Amazon Connect endpoint
 * @param {HTMLSelectElement} selectEl - The customerTranslateFromLanguageSelect DOM element
 * @param {Function} persistFn        - addUpdateLocalStorageKey(key, value) from commonUtility
 */
export function autoSetCustomerLanguageFromPhone(phoneNumber, selectEl, persistFn) {
  const languageCode = getLanguageCodeFromPhoneNumber(phoneNumber);

  if (!languageCode) {
    console.info(`${LOGGER_PREFIX} - autoSetCustomerLanguageFromPhone - could not determine language, keeping current selection`);
    return;
  }

  if (!isLanguageSupported(languageCode)) {
    console.warn(`${LOGGER_PREFIX} - autoSetCustomerLanguageFromPhone - language "${languageCode}" is not in the supported list, keeping current selection`);
    return;
  }

  // Check the option actually exists in the rendered <select>
  const optionExists = Array.from(selectEl.options).some((opt) => opt.value === languageCode);
  if (!optionExists) {
    console.warn(`${LOGGER_PREFIX} - autoSetCustomerLanguageFromPhone - option "${languageCode}" not found in dropdown, keeping current selection`);
    return;
  }

  console.info(`${LOGGER_PREFIX} - autoSetCustomerLanguageFromPhone - auto-selecting language "${languageCode}" from phone number "${phoneNumber}"`);
  selectEl.value = languageCode;

  // Persist so it survives page refresh (same key used by manual save flow)
  if (typeof persistFn === "function") {
    persistFn("customerTranslateFromLanguage", languageCode);
  }
}

/**
 * Sets the customer "translate from" language dropdown from the
 * "Customer_Preferred_Language" CCP contact attribute (INBOUND calls only).
 *
 * Rules:
 *  - If the attribute value matches a supported language code (or name) → use it.
 *  - If the attribute is missing, empty, or unsupported               → default to "en".
 *  - The dropdown value and voiceId are always persisted to localStorage.
 *
 * @param {string}           attrValue  - Raw value of the "Customer_Preferred_Language" attribute
 * @param {HTMLSelectElement} selectEl  - The customerTranslateFromLanguageSelect DOM element
 * @param {Function}         persistFn  - addUpdateLocalStorageKey(key, value) from commonUtility
 * @returns {string} The language code that was ultimately applied (e.g. "hi", "en")
 */
export function autoSetCustomerLanguageFromAttribute(attrValue, selectEl, persistFn) {
  const rawValue = (attrValue || "").trim();

  let languageCode = null;

  if (rawValue) {
    // 1. Direct code match — e.g. attribute value is "hi" or "zh-TW"
    if (isLanguageSupported(rawValue)) {
      languageCode = rawValue;
    } else {
      // 2. Case-insensitive code or name match — e.g. "Hindi", "HI", "spanish"
      const lower = rawValue.toLowerCase();
      const match = NOVA_INTERPRETER_LANGUAGES.find(
        (l) => l.code.toLowerCase() === lower || l.name.toLowerCase() === lower,
      );
      if (match) languageCode = match.code;
    }
  }

  if (!languageCode && rawValue) {
    // 3. BCP-47 region-suffix fallback — e.g. "en-US" → "en", "es-419" → "es",
    //    "zh-CN" → "zh", "pt-BR" → "pt".
    //
    //    The attribute "Customer_Preferred_Language" sometimes carries a full
    //    BCP-47 tag (base + region). Our dropdown only stores base codes, so a
    //    direct lookup fails even though the base language IS supported.
    //    Strip everything after the first "-" and retry.
    const baseLang  = rawValue.split("-")[0].toLowerCase();
    const baseMatch = NOVA_INTERPRETER_LANGUAGES.find(
      (l) => l.code.toLowerCase() === baseLang,
    );
    if (baseMatch) {
      languageCode = baseMatch.code;
      console.info(
        `${LOGGER_PREFIX} - autoSetCustomerLanguageFromAttribute` +
        ` - resolved base language "${languageCode}" from "${rawValue}" (region suffix stripped)`,
      );
    }
  }

  if (!languageCode) {
    // Attribute missing, empty, or not in supported list — fall back to English
    console.info(
      `${LOGGER_PREFIX} - autoSetCustomerLanguageFromAttribute` +
      ` - attribute value "${rawValue}" not found or unsupported, defaulting to "en"`,
    );
    languageCode = "en";
  } else {
    console.info(
      `${LOGGER_PREFIX} - autoSetCustomerLanguageFromAttribute` +
      ` - resolved language "${languageCode}" from attribute value "${rawValue}"`,
    );
  }

  // Safety: ensure the resolved option actually exists in the rendered <select>
  const optionExists = Array.from(selectEl.options).some((opt) => opt.value === languageCode);
  if (!optionExists) {
    console.warn(
      `${LOGGER_PREFIX} - autoSetCustomerLanguageFromAttribute` +
      ` - option "${languageCode}" not found in dropdown, defaulting to "en"`,
    );
    languageCode = "en";
  }

  selectEl.value = languageCode;

  if (typeof persistFn === "function") {
    persistFn("customerTranslateFromLanguage", languageCode);
  }

  return languageCode;
}
