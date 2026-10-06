// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { TranslateTextCommand } from "@aws-sdk/client-translate";
import { SynthesizeSpeechCommand } from "@aws-sdk/client-polly";
import { errorFields } from "../logger.js";

/**
 * The Translate + Polly fallback, run server-side. Mirrors the webapp's previous behaviour:
 *  - Translate fails or returns nothing -> 502, the webapp then leaves Nova Sonic's output alone.
 *  - Polly fails -> 200 with audio: null, so the translated text still reaches the transcript.
 *  - Source and target the same -> the text is already in the target language (Nova Sonic's own
 *    hearing of the agent, fix 4) and is only spoken; Translate is not called.
 */
export async function runFallback({ text, sourceLanguageCode, targetLanguageCode, voice }, { translate, polly, logger, logContext }) {
  let translatedText;
  if (sourceLanguageCode.toLowerCase() === targetLanguageCode.toLowerCase()) {
    translatedText = text;
  } else {
    try {
      const result = await translate.send(
        new TranslateTextCommand({ Text: text, SourceLanguageCode: sourceLanguageCode, TargetLanguageCode: targetLanguageCode }),
      );
      translatedText = (result?.TranslatedText || "").trim();
    } catch (err) {
      logger.warn("translate failed", { ...logContext, ...errorFields(err) });
      return { status: 502, body: { error: "translateFailed" } };
    }
  }
  if (!translatedText) return { status: 502, body: { error: "translateEmpty" } };

  let audio = null;
  let audioError = false;
  if (voice) {
    try {
      const speech = await polly.send(
        new SynthesizeSpeechCommand({ Text: translatedText, OutputFormat: "mp3", VoiceId: voice.voiceId, Engine: voice.engine }),
      );
      audio = Buffer.from(await speech.AudioStream.transformToByteArray()).toString("base64");
    } catch (err) {
      audioError = true;
      logger.warn("polly failed", { ...logContext, voiceId: voice.voiceId, engine: voice.engine, ...errorFields(err) });
    }
  }
  return { status: 200, body: { translatedText, audio, audioError } };
}
