export const DEPRECATED_CONNECT_DOMAIN = "awsapps.com";

export const SESSION_STORAGE_KEYS = {};

export const LOGGER_PREFIX = "CCP-V2V";

export const CUSTOMER_TRANSLATION_TO_CUSTOMER_VOLUME = 0.1;
export const AGENT_TRANSLATION_TO_AGENT_VOLUME = 0.1;

export const AUDIO_FEEDBACK_FILE_PATH = "./assets/background_noise.wav";

/**
 * Maps E.164 phone number prefixes → NOVA_INTERPRETER_LANGUAGES codes.
 * Ordered longest-prefix first so shorter prefixes (e.g. +1) don't
 * shadow longer ones (e.g. +1868 Trinidad) during linear scan.
 */
export const PHONE_COUNTRY_CODE_LANGUAGE_MAP = [
  // ── 3-digit prefixes ────────────────────────────────────────────
  { prefix: "+212", language: "ar" },   // Morocco
  { prefix: "+213", language: "ar" },   // Algeria
  { prefix: "+216", language: "ar" },   // Tunisia
  { prefix: "+218", language: "ar" },   // Libya
  { prefix: "+351", language: "pt-PT" },// Portugal
  { prefix: "+353", language: "en" },   // Ireland
  { prefix: "+358", language: "fi" },   // Finland
  { prefix: "+380", language: "uk" },   // Ukraine
  { prefix: "+420", language: "cs" },   // Czech Republic
  { prefix: "+852", language: "zh" },   // Hong Kong
  { prefix: "+853", language: "zh" },   // Macau
  { prefix: "+886", language: "zh-TW" },// Taiwan
  { prefix: "+961", language: "ar" },   // Lebanon
  { prefix: "+962", language: "ar" },   // Jordan
  { prefix: "+963", language: "ar" },   // Syria
  { prefix: "+964", language: "ar" },   // Iraq
  { prefix: "+965", language: "ar" },   // Kuwait
  { prefix: "+966", language: "ar" },   // Saudi Arabia
  { prefix: "+967", language: "ar" },   // Yemen
  { prefix: "+968", language: "ar" },   // Oman
  { prefix: "+970", language: "ar" },   // Palestine
  { prefix: "+971", language: "ar" },   // UAE
  { prefix: "+973", language: "ar" },   // Bahrain
  { prefix: "+974", language: "ar" },   // Qatar
  // ── 2-digit prefixes ────────────────────────────────────────────
  { prefix: "+20", language: "ar" },    // Egypt
  { prefix: "+31", language: "nl" },    // Netherlands
  { prefix: "+32", language: "nl" },    // Belgium
  { prefix: "+33", language: "fr" },    // France
  { prefix: "+34", language: "es" },    // Spain
  { prefix: "+39", language: "it" },    // Italy
  { prefix: "+41", language: "de" },    // Switzerland
  { prefix: "+43", language: "de" },    // Austria
  { prefix: "+44", language: "en" },    // United Kingdom
  { prefix: "+46", language: "sv" },    // Sweden
  { prefix: "+48", language: "pl" },    // Poland
  { prefix: "+49", language: "de" },    // Germany
  { prefix: "+52", language: "es" },    // Mexico
  { prefix: "+54", language: "es" },    // Argentina
  { prefix: "+55", language: "pt" },    // Brazil
  { prefix: "+56", language: "es" },    // Chile
  { prefix: "+57", language: "es" },    // Colombia
  { prefix: "+58", language: "es" },    // Venezuela
  { prefix: "+61", language: "en" },    // Australia
  { prefix: "+62", language: "id" },    // Indonesia
  { prefix: "+63", language: "en" },    // Philippines
  { prefix: "+64", language: "en" },    // New Zealand
  { prefix: "+65", language: "zh" },    // Singapore
  { prefix: "+81", language: "ja" },    // Japan
  { prefix: "+82", language: "ko" },    // South Korea
  { prefix: "+86", language: "zh" },    // China
  { prefix: "+90", language: "tr" },    // Turkey
  { prefix: "+91", language: "hi" },    // India
  // ── 1-digit prefixes ────────────────────────────────────────────
  { prefix: "+1", language: "en" },     // USA / Canada
  { prefix: "+7", language: "ru" },     // Russia / Kazakhstan
];

/**
 * The nine languages this deployment supports, in dropdown order.
 *
 * Trimmed from 22 deliberately. Every entry here is backed end to end:
 * an Amazon Transcribe locale (TRANSCRIBE_LANGUAGE_MAP) and an Amazon Polly
 * voice (POLLY_FALLBACK_VOICE_MAP). Six of them — en, fr, de, it, es, pt — also
 * have a native Nova 2 Sonic voice and a target-language interpreter prompt
 * (pt since fix 7); the other three (nl, ja, zh) are not Nova 2 Sonic languages
 * and have no Nova Sonic voice.
 */
export const NOVA_INTERPRETER_LANGUAGES = [
  { code: "en", name: "English" },
  { code: "nl", name: "Dutch" },
  { code: "fr", name: "French" },
  { code: "de", name: "German" },
  { code: "it", name: "Italian" },
  { code: "pt", name: "Portuguese" },
  { code: "es", name: "Spanish" },
  { code: "ja", name: "Japanese" },
  { code: "zh", name: "Mandarin" },
];

// ─── Voice ID mapping ────────────────────────────────────────────────────────
// Maps NOVA_INTERPRETER_LANGUAGES codes → Nova Sonic voice IDs.
//
// IMPORTANT: every value here MUST exist in NOVA_SONIC_VOICE_IDS
// (webapp/adapters/novaSonicAdapter.js). Requesting a voice Nova Sonic does not
// know causes it to fall back to an English voice, which reads as an
// untranslated passthrough to the customer. Languages with no native Nova Sonic
// voice are deliberately left unmapped so getVoiceId() can warn loudly rather
// than silently substituting "matthew".
//
// fix 7: the voices of Nova 2 Sonic (AWS "Language support and multilingual
// capabilities", checked 2026-09-30). German is "tina" ("greta" was Nova Sonic
// v1's German voice and is not in the Nova 2 list), and Portuguese has a voice
// again: "carolina" (Brazil) is a Nova 2 Sonic voice. It was removed when the
// app used the v1 list, which had no Portuguese. Dutch, Japanese and Mandarin
// are not Nova 2 Sonic languages.
export const LANGUAGE_VOICE_ID_MAP = {
  en:    "tiffany",   // English – US / India / Australia / UK
  fr:    "ambre",     // French
  de:    "tina",      // German
  it:    "beatrice",  // Italian
  es:    "lupe",      // Spanish
  pt:    "carolina",  // Portuguese (Brazil)
};

// ─── Amazon Polly fallback voices ────────────────────────────────────────────
// Used by translateFallbackAdapter when Nova Sonic drifts or refuses to
// translate. Deterministic TTS with no model guardrails, so it always produces
// output. `engine` matters: several of these voices are standard-only and a
// neural request would fail outright.
// fix 4: Spanish uses Lupe's generative voice, which sounds far closer to Nova Sonic than the neural
// one. If the region does not offer it, the adapter retries with neural (and stays on neural).
// fix 7: the same for the other languages Polly has a generative voice for (AWS Polly "Generative
// voices" and "Available voices" pages, checked 2026-09-30). English, French and Italian use Polly's
// Tiffany, Ambre and Beatrice, the names of the app's Nova Sonic voices for those languages, so a
// sentence from Polly should sound like the Nova Sonic voice around it (not verified by ear). Those three
// exist only as generative voices, so `neuralVoiceId` names the neural voice the retry uses (the voice
// used before fix 7). Japanese and Mandarin have no generative voice in Polly and stay neural.
export const POLLY_FALLBACK_VOICE_MAP = {
  ar:      { voiceId: "Zeina",   engine: "standard" },
  cs:      { voiceId: "Jitka",   engine: "neural"   },
  de:      { voiceId: "Vicki",   engine: "generative" },
  en:      { voiceId: "Tiffany", engine: "generative", neuralVoiceId: "Joanna" },
  es:      { voiceId: "Lupe",    engine: "generative" },
  fi:      { voiceId: "Suvi",    engine: "neural"   },
  fr:      { voiceId: "Ambre",   engine: "generative", neuralVoiceId: "Lea" },
  hi:      { voiceId: "Kajal",   engine: "neural"   },
  it:      { voiceId: "Beatrice", engine: "generative", neuralVoiceId: "Bianca" },
  ja:      { voiceId: "Takumi",  engine: "neural"   },
  ko:      { voiceId: "Seoyeon", engine: "neural"   },
  nl:      { voiceId: "Laura",   engine: "generative" },
  pl:      { voiceId: "Ola",     engine: "neural"   },
  pt:      { voiceId: "Camila",  engine: "generative" },
  "pt-PT": { voiceId: "Ines",    engine: "neural"   },
  ru:      { voiceId: "Tatyana", engine: "standard" },
  sv:      { voiceId: "Elin",    engine: "neural"   },
  tr:      { voiceId: "Filiz",   engine: "standard" },
  zh:      { voiceId: "Zhiyu",   engine: "neural"   },
  // GAP 5 FIX: zh-TW (Traditional Chinese / Taiwan) uses the same spoken
  // Mandarin language as zh-CN. Zhiyu is Amazon Polly's Mandarin voice and
  // produces correct speech for zh-TW callers even though the written script
  // differs. Amazon Translate already outputs Traditional Chinese characters
  // when targetLangCode is "zh-TW", so the transcript is fully correct;
  // only the TTS voice is shared with zh-CN.
  "zh-TW": { voiceId: "Zhiyu",   engine: "neural"   },
};

// ─── Polly nearest-neighbour fallbacks ───────────────────────────────────────
// Languages that have no native Amazon Polly voice. Maps them to the closest
// available Polly voice so the fallback path always produces SOME audio rather
// than returning null and leaving the customer in silence.
//
// The translated TEXT is always correct (Amazon Translate covers these
// languages). Only the TTS voice is approximate. A console warning is emitted
// each time a nearest-neighbour is used so the team can swap in a native voice
// the moment Polly adds support.
//
//  id (Indonesian) — No Polly voice. Closest available regional voice is
//  Malay/English. Using English (Joanna/neural) ensures the translated text is
//  read intelligibly rather than using a completely unrelated language voice.
//
//  uk (Ukrainian) — No Polly voice. Russian (Tatyana/standard) is the closest
//  Slavic language available in Polly and is widely understood by Ukrainian
//  speakers, making it a better choice than English for this context.
export const POLLY_NEAREST_NEIGHBOUR_MAP = {
  id: { voiceId: "Joanna",  engine: "neural",   reason: "Indonesian has no native Polly voice — using English (Joanna) as best-effort" },
  uk: { voiceId: "Tatyana", engine: "standard", reason: "Ukrainian has no native Polly voice — using Russian (Tatyana) as closest Slavic fallback" },
};