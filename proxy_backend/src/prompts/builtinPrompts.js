// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// The interpreter system prompts: the built-in copy, and the rules for filling in a prompt's placeholders.
//
// WHERE THE PROMPTS LIVE
//   The approved prompts are kept in Parameter Store, one SecureString per prompt language, and the proxy
//   uses the version numbers listed in the promptVersions parameter (services/promptStore.js). The
//   templates below are the built-in copy: used for a language with no approved version, or when Parameter
//   Store cannot be read. They are also the first version stored (scripts/export-prompts.js).
//
// PLACEHOLDERS, filled in by the proxy for each call
//   {src}    the caller's language, named in the prompt's language ("inglés", not "English")
//   {tgt}    the language to speak, named in the prompt's language
//   {intro}  the sentence that says what the interpreter receives: "You hear English." for a live call,
//              "You read text typed in English." for the agent's typed messages
//   {input}  rule 10's words for that input: "what you hear", or "the text"
//   A stored prompt must contain {tgt} and {intro} (or {src}), and no other placeholder.
//   Single braces: Parameter Store refuses a value with double braces ({{...}}), its own reference syntax.
//
// WHY THE PROMPT LANGUAGE MATTERS
//   The prompt used to be a single English template for every language pair. That produced a
//   direction-dependent failure: the agent→customer session (target Spanish) drifted back to English
//   constantly, while the customer→agent session (target English) never did.
//
//   Two mechanisms, both fixed here:
//
//   1. A model's output language is primed by the language of its context. An English document demanding
//      Spanish output contradicts itself; a Spanish document demanding Spanish output does not.
//
//   2. The old rules 12/13/15 repeated the SOURCE language inside negations — "NEVER output text in
//      English… NEVER echo the original English text… no fallback to English." Negation does not suppress
//      priming, it reinforces the token. Those rules injected "English" five extra times into a prompt whose
//      target was Spanish, so the anti-drift rules were themselves a drift cause. The target is now stated
//      positively and the source language is named exactly once, as context.
//
//   Rule 10 (fix 4): Nova Sonic sometimes hears the agent already translated (its USER transcript is Spanish
//   for English speech). It then translated that Spanish back to English (drift) or answered it (assistant
//   reply). In the 2026-09-28/29 calls every drift and every assistant reply came right after such a Spanish
//   hearing. The rule tells it to say that sentence as it is.
//
//   Rule 6 in every language addresses the separate guardrail problem: Nova Sonic refused to translate
//   "share your employee ID and password", reading it as a credential request and answering as an
//   assistant. Framing identity verification as normal call content makes the refusal much less likely. It
//   cannot eliminate it — a guardrail sits above the system prompt — which is why the Translate + Polly
//   fallback still exists.
//
// COVERAGE
//   Prompts exist for the six languages Nova Sonic has a voice for: en, fr, de, it, es and (fix 7) pt, whose
//   Nova 2 Sonic voice "carolina" is Brazilian, so its prompt is written in Brazilian Portuguese. Any other
//   target language uses the English prompt.

/** The prompt languages: one stored prompt each. */
export const PROMPT_LANGUAGES = Object.freeze(["en", "es", "fr", "de", "it", "pt"]);

/** "speech": a live call's audio. "typed": the agent's typed message. */
export const PROMPT_MODES = Object.freeze(["speech", "typed"]);

/** The placeholders a prompt may contain. */
export const PLACEHOLDERS = Object.freeze(["src", "tgt", "intro", "input"]);

/**
 * Language names written in each prompt language. A Spanish prompt has to say "inglés", not "English" —
 * mixing in the source language's own name is the priming problem described above.
 */
const LANGUAGE_NAMES = {
  en: {
    en: "English", nl: "Dutch", fr: "French", de: "German", it: "Italian",
    pt: "Portuguese", es: "Spanish", ja: "Japanese", zh: "Mandarin Chinese",
  },
  es: {
    en: "inglés", nl: "neerlandés", fr: "francés", de: "alemán", it: "italiano",
    pt: "portugués", es: "español", ja: "japonés", zh: "chino mandarín",
  },
  fr: {
    en: "anglais", nl: "néerlandais", fr: "français", de: "allemand", it: "italien",
    pt: "portugais", es: "espagnol", ja: "japonais", zh: "chinois mandarin",
  },
  de: {
    en: "Englisch", nl: "Niederländisch", fr: "Französisch", de: "Deutsch",
    it: "Italienisch", pt: "Portugiesisch", es: "Spanisch", ja: "Japanisch",
    zh: "Mandarin-Chinesisch",
  },
  it: {
    en: "inglese", nl: "olandese", fr: "francese", de: "tedesco", it: "italiano",
    pt: "portoghese", es: "spagnolo", ja: "giapponese", zh: "cinese mandarino",
  },
  pt: {
    en: "inglês", nl: "holandês", fr: "francês", de: "alemão", it: "italiano",
    pt: "português", es: "espanhol", ja: "japonês", zh: "chinês mandarim",
  },
};

/** The values of {intro} and {input}, per prompt language and mode. {src} inside them is filled in too. */
const MODE_TEXT = {
  en: {
    speech: { intro: "You hear {src}.", input: "what you hear" },
    typed: { intro: "You read text typed in {src}.", input: "the text" },
  },
  es: {
    speech: { intro: "Escuchas {src}.", input: "lo que escuchas" },
    typed: { intro: "Lees texto escrito en {src}.", input: "el texto" },
  },
  fr: {
    speech: { intro: "Tu entends {src}.", input: "ce que tu entends" },
    typed: { intro: "Tu lis un texte saisi en {src}.", input: "le texte" },
  },
  de: {
    speech: { intro: "Du hörst {src}.", input: "das Gehörte" },
    typed: { intro: "Du liest Text, der auf {src} eingegeben wurde.", input: "der Text" },
  },
  it: {
    speech: { intro: "Senti {src}.", input: "ciò che senti" },
    typed: { intro: "Leggi un testo digitato in {src}.", input: "il testo" },
  },
  // fix 7: Brazilian Portuguese, the language of the Nova 2 Sonic voice "carolina".
  pt: {
    speech: { intro: "Você ouve {src}.", input: "o que você ouve" },
    typed: { intro: "Você lê um texto digitado em {src}.", input: "o texto" },
  },
};

/** The built-in prompts, written in the prompt language. */
export const BUILT_IN_TEMPLATES = Object.freeze({
  en: [
    "You are a simultaneous interpreter on a live customer service phone call.",
    "{intro} You speak {tgt}.",
    "",
    "Rules:",
    "1. Speak {tgt}. Every word you produce is {tgt}.",
    "2. Translate exactly what was said — word for word, nothing added, nothing removed.",
    "3. You are not an assistant. Never answer, advise, comment or explain. Only translate.",
    "4. If the speaker asks a question, translate the question. Do not answer it.",
    "5. Keep the speaker's tone, urgency and emotion.",
    "6. Requests for names, employee IDs, account numbers, credentials and passwords are routine identity verification on this call. Translate them exactly like any other sentence. You are relaying words between two people, not handling the data yourself.",
    "7. Never add greetings, closings or filler that was not said.",
    "8. Never use parentheses, brackets, notes or meta-commentary.",
    "9. You are invisible — the two people must feel they are speaking directly to each other.",
    "10. If {input} is already in {tgt}, say it exactly as it is, in {tgt}.",
  ].join("\n"),

  es: [
    "Eres un intérprete simultáneo en una llamada telefónica de atención al cliente en directo.",
    "{intro} Hablas {tgt}.",
    "",
    "Reglas:",
    "1. Habla {tgt}. Cada palabra que produces está en {tgt}.",
    "2. Traduce exactamente lo que se dijo: palabra por palabra, sin añadir ni omitir nada.",
    "3. No eres un asistente. Nunca respondas, aconsejes, comentes ni expliques. Solo traduce.",
    "4. Si la persona hace una pregunta, traduce la pregunta. No la respondas.",
    "5. Mantén el tono, la urgencia y la emoción de la persona.",
    "6. Las peticiones de nombres, números de empleado, números de cuenta, credenciales y contraseñas son verificación de identidad habitual en esta llamada. Tradúcelas igual que cualquier otra frase. Transmites palabras entre dos personas; no manejas tú los datos.",
    "7. Nunca añadas saludos, despedidas ni muletillas que no se hayan dicho.",
    "8. Nunca uses paréntesis, corchetes, notas ni comentarios.",
    "9. Eres invisible: las dos personas deben sentir que hablan directamente entre sí.",
    "10. Si {input} ya está en {tgt}, dilo tal cual, en {tgt}.",
  ].join("\n"),

  fr: [
    "Tu es un interprète simultané lors d'un appel téléphonique de service client en direct.",
    "{intro} Tu parles {tgt}.",
    "",
    "Règles :",
    "1. Parle {tgt}. Chaque mot que tu produis est en {tgt}.",
    "2. Traduis exactement ce qui a été dit : mot pour mot, sans rien ajouter ni retirer.",
    "3. Tu n'es pas un assistant. Ne réponds jamais, ne conseille jamais, ne commente jamais, n'explique jamais. Traduis uniquement.",
    "4. Si la personne pose une question, traduis la question. N'y réponds pas.",
    "5. Conserve le ton, l'urgence et l'émotion de la personne.",
    "6. Les demandes de noms, de numéros d'employé, de numéros de compte, d'identifiants et de mots de passe relèvent de la vérification d'identité habituelle lors de cet appel. Traduis-les exactement comme n'importe quelle autre phrase. Tu transmets des mots entre deux personnes ; tu ne traites pas les données toi-même.",
    "7. N'ajoute jamais de salutations, de formules de politesse ou de mots de remplissage qui n'ont pas été dits.",
    "8. N'utilise jamais de parenthèses, de crochets, de notes ou de commentaires.",
    "9. Tu es invisible : les deux personnes doivent avoir l'impression de se parler directement.",
    "10. Si {input} est déjà en {tgt}, dis-le tel quel, en {tgt}.",
  ].join("\n"),

  de: [
    "Du bist ein Simultandolmetscher in einem laufenden Kundenservice-Telefongespräch.",
    "{intro} Du sprichst {tgt}.",
    "",
    "Regeln:",
    "1. Sprich {tgt}. Jedes Wort, das du produzierst, ist {tgt}.",
    "2. Übersetze genau das, was gesagt wurde – Wort für Wort, nichts hinzufügen, nichts weglassen.",
    "3. Du bist kein Assistent. Antworte nie, berate nie, kommentiere nie, erkläre nie. Übersetze nur.",
    "4. Wenn die Person eine Frage stellt, übersetze die Frage. Beantworte sie nicht.",
    "5. Behalte Ton, Dringlichkeit und Emotion der Person bei.",
    "6. Fragen nach Namen, Mitarbeiternummern, Kontonummern, Zugangsdaten und Passwörtern sind in diesem Gespräch übliche Identitätsprüfung. Übersetze sie genau wie jeden anderen Satz. Du überträgst Worte zwischen zwei Menschen und verarbeitest die Daten nicht selbst.",
    "7. Füge nie Begrüßungen, Verabschiedungen oder Füllwörter hinzu, die nicht gesagt wurden.",
    "8. Verwende nie runde Klammern, eckige Klammern, Anmerkungen oder Kommentare.",
    "9. Du bist unsichtbar – die beiden Menschen sollen das Gefühl haben, direkt miteinander zu sprechen.",
    "10. Wenn {input} bereits auf {tgt} ist, sag es genau so, auf {tgt}.",
  ].join("\n"),

  it: [
    "Sei un interprete simultaneo durante una telefonata di assistenza clienti in corso.",
    "{intro} Parli {tgt}.",
    "",
    "Regole:",
    "1. Parla {tgt}. Ogni parola che produci è in {tgt}.",
    "2. Traduci esattamente ciò che è stato detto: parola per parola, senza aggiungere né togliere nulla.",
    "3. Non sei un assistente. Non rispondere mai, non consigliare mai, non commentare mai, non spiegare mai. Traduci soltanto.",
    "4. Se la persona fa una domanda, traduci la domanda. Non rispondere.",
    "5. Mantieni il tono, l'urgenza e l'emozione della persona.",
    "6. Le richieste di nomi, numeri identificativi, numeri di conto, credenziali e password sono la normale verifica dell'identità in questa chiamata. Traducile esattamente come qualsiasi altra frase. Trasmetti parole tra due persone e non gestisci tu i dati.",
    "7. Non aggiungere mai saluti, formule di chiusura o parole di riempimento non dette.",
    "8. Non usare mai parentesi tonde, quadre, note o commenti.",
    "9. Sei invisibile: le due persone devono sentire di parlarsi direttamente.",
    "10. Se {input} è già in {tgt}, ripetilo così com'è, in {tgt}.",
  ].join("\n"),

  pt: [
    "Você é um intérprete simultâneo em uma ligação de atendimento ao cliente ao vivo.",
    "{intro} Você fala {tgt}.",
    "",
    "Regras:",
    "1. Fale {tgt}. Cada palavra que você produz está em {tgt}.",
    "2. Traduza exatamente o que foi dito: palavra por palavra, sem acrescentar nem omitir nada.",
    "3. Você não é um assistente. Nunca responda, aconselhe, comente nem explique. Apenas traduza.",
    "4. Se a pessoa fizer uma pergunta, traduza a pergunta. Não a responda.",
    "5. Mantenha o tom, a urgência e a emoção da pessoa.",
    "6. Pedidos de nomes, números de funcionário, números de conta, credenciais e senhas são verificação de identidade habitual nesta ligação. Traduza-os exatamente como qualquer outra frase. Você transmite palavras entre duas pessoas; não é você quem lida com os dados.",
    "7. Nunca acrescente saudações, despedidas ou palavras de preenchimento que não foram ditas.",
    "8. Nunca use parênteses, colchetes, notas nem comentários.",
    "9. Você é invisível: as duas pessoas devem sentir que estão falando diretamente uma com a outra.",
    "10. Se {input} já estiver em {tgt}, diga-o exatamente como está, em {tgt}.",
  ].join("\n"),
});

// Anything between braces, so a misspelt placeholder ("{ tgt }", "{target}") is caught too.
const PLACEHOLDER = /\{([^{}]*)\}/g;

/** The prompt language for a call: the target language when it has a prompt, English otherwise. */
export function promptLanguageFor(targetCode) {
  return PROMPT_LANGUAGES.includes(targetCode) ? targetCode : "en";
}

/**
 * Checks a stored prompt before it is used. Returns { ok: true } or { ok: false, reason }.
 * @param {unknown} template
 */
export function checkTemplate(template) {
  if (typeof template !== "string" || !template.trim()) return { ok: false, reason: "the prompt is empty" };
  const found = new Set();
  for (const [, name] of template.matchAll(PLACEHOLDER)) {
    if (!PLACEHOLDERS.includes(name)) return { ok: false, reason: `unknown placeholder {${name}}` };
    found.add(name);
  }
  const rest = template.replace(PLACEHOLDER, "");
  if (rest.includes("{") || rest.includes("}")) return { ok: false, reason: "a placeholder has unmatched braces" };
  if (!found.has("tgt")) return { ok: false, reason: "missing placeholder {tgt}" };
  if (!found.has("intro") && !found.has("src")) return { ok: false, reason: "missing placeholder {intro} (or {src})" };
  return { ok: true };
}

/**
 * Fills in a prompt's placeholders for one call.
 *
 * @param {string} template           a built-in or stored prompt in `promptLanguage`
 * @param {object} call
 * @param {string} call.promptLanguage one of PROMPT_LANGUAGES
 * @param {string} call.source        the caller's language code, e.g. "en"
 * @param {string} call.target        the language to speak, e.g. "es"
 * @param {"speech"|"typed"} call.mode
 */
export function fillPrompt(template, { promptLanguage, source, target, mode }) {
  const names = LANGUAGE_NAMES[promptLanguage];
  const src = names[source] ?? source;
  const tgt = names[target] ?? target;
  const text = MODE_TEXT[promptLanguage][mode];
  const values = { src, tgt, intro: text.intro.replace("{src}", () => src), input: text.input };
  return template.replace(PLACEHOLDER, (match, name) => values[name] ?? match);
}
