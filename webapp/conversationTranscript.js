// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * conversationTranscript.js
 * ─────────────────────────
 * Standalone module that drives the right-side "Transcription" chat panel.
 *
 * Renders a live chat-bubble view of the bilingual conversation:
 *   • Customer speech  →  left-aligned bubble  (grey / white)
 *   • Agent speech     →  right-aligned bubble (blue)
 *
 * Each bubble shows:
 *   ① Original spoken text   (bold)
 *   ── thin divider ──
 *   ② Translation label      (small caps)
 *   ③ Translated text        (italic)
 *
 * Where the text comes from
 * ─────────────────────────
 *   Bubbles are committed by the TurnAccumulator instances in main.js (see
 *   utils/turnAccumulator.js), one per channel. Each accumulator buffers the
 *   fragments Nova Sonic and Transcribe actually deliver, merges them into a
 *   whole utterance, and calls addConversationMessage() once per turn with the
 *   original and the translation that belong together.
 *
 *   This module previously scraped the four live text-output divs with a
 *   MutationObserver and paired whatever happened to be in them when they went
 *   quiet. That is why the panel showed mismatched cards: the boxes were
 *   written one fragment at a time with `textContent = chunk`, so the original
 *   box held only the LAST fragment of an utterance ("hoy") next to the full
 *   translation, and the two boxes were filled by independent async paths that
 *   could settle a turn apart. Accumulating at the source removes both faults,
 *   so the observer is gone.
 *
 * Public API
 * ──────────
 *   initConversationTranscript(containerId)
 *       Call once after the DOM is ready (already wired in main.js onLoad).
 *
 *   addConversationMessage(original, translated, type, agentLangSelect, customerLangSelect)
 *       Append one bubble. Called by the per-channel TurnAccumulator.
 *
 *   clearConversationTranscript()
 *       Remove all call bubbles (called by clearTranscriptCards on disconnect). Voicemail bubbles stay.
 *
 *   addVoicemailMessage(contactId, text) / removeVoicemailMessage(contactId)
 *       Show / remove a voicemail task's transcript. It belongs to the task, not to a phone call, so it is
 *       removed only when its task is closed.
 */

import './conversationTranscript.css';

// ── module-level state ─────────────────────────────────────────────────────
let _container = null;

// ── public API ─────────────────────────────────────────────────────────────

/**
 * Initialise the panel. Bubbles arrive via addConversationMessage().
 * @param {string} containerId  id of #divTranscriptContainer
 */
export function initConversationTranscript(containerId) {
  _container = document.getElementById(containerId);

  if (!_container) {
    console.warn(`[ConversationTranscript] Container #${containerId} not found.`);
    return;
  }

  // Guarantee spacer exists as the last child
  if (!_container.querySelector('.transcript-spacer')) {
    const sp = document.createElement('div');
    sp.className = 'transcript-spacer';
    _container.appendChild(sp);
  }

  console.info('[ConversationTranscript] Initialised on #' + containerId);
}

/**
 * Append one bubble. Called by the per-channel TurnAccumulator in main.js
 * once a turn is assembled, so `original` and `translated` are always the
 * complete, matching halves of the same utterance.
 *
 * No deduplication here: the accumulator commits exactly once per turn, and
 * dropping a repeat would silently swallow a speaker genuinely saying the same
 * sentence twice.
 *
 * @param {string}      original
 * @param {string}      translated
 * @param {string}      type               'toAgent' | 'fromAgent'
 * @param {HTMLElement} agentLangSelect
 * @param {HTMLElement} customerLangSelect
 */
export function addConversationMessage(
  original,
  translated,
  type,
  agentLangSelect,
  customerLangSelect,
) {
  if (!_container) return;

  const orig  = (original  || '').trim();
  const trans = (translated || '').trim();
  if (!orig && !trans) return;

  // Resolve translation label
  let translationLabel = 'Translation';
  if (type === 'toAgent' && agentLangSelect) {
    const t = agentLangSelect.options[agentLangSelect.selectedIndex]?.text;
    if (t) translationLabel = `Translation (to ${t})`;
  } else if (type === 'fromAgent' && customerLangSelect) {
    const t = customerLangSelect.options[customerLangSelect.selectedIndex]?.text;
    if (t) translationLabel = `Translation (to ${t})`;
  }

  _insertBubble(orig, trans, type, translationLabel);
}

/**
 * Show a voicemail task's transcript (vmx3_transcript) as a customer bubble labelled "Voicemail", with no
 * translation part. One bubble per task: a second call for the same task does nothing.
 *
 * @param {string} contactId  the task's contact ID
 * @param {string} text
 */
export function addVoicemailMessage(contactId, text) {
  if (!_container) return;
  const t = (text || '').trim();
  if (!t || _voicemailRow(contactId)) return;
  const row = _insertBubble(t, '', 'toAgent', 'Voicemail', { voicemail: true });
  row.dataset.voicemailContactId = contactId;
}

/** Remove the voicemail bubble of one task, if it is shown. */
export function removeVoicemailMessage(contactId) {
  _voicemailRow(contactId)?.remove();
}

/**
 * Take sentences out of the translation of the latest bubbles of one type (2026-10-15: a chatbot reply
 * shown before it was recognised, and already saved as a bubble). Looks at the last `maxBubbles` bubbles
 * of that type, newest first, and removes each sentence from the newest bubble that has it exactly, so
 * the same words said earlier in the call are left alone.
 *
 * @param {string}   type       'toAgent' | 'fromAgent'
 * @param {string[]} sentences  the texts to remove
 * @param {number}   [maxBubbles=3]
 * @returns {HTMLElement|null}  the translation element of the newest bubble changed, or null
 */
export function removeFromRecentTranslations(type, sentences, maxBubbles = 3) {
  if (!_container) return null;
  const rowClass = type === 'toAgent' ? 'ct-row--customer' : 'ct-row--agent';
  const rows = [..._container.querySelectorAll(`.ct-row.${rowClass}:not(.ct-row--voicemail)`)].slice(-maxBubbles).reverse();
  // Longest first, so a FINAL copy that contains a shorter SPECULATIVE copy is removed whole.
  let texts = [...new Set(sentences.map((s) => (s || '').trim()).filter(Boolean))].sort((a, b) => b.length - a.length);
  let newest = null;
  for (const row of rows) {
    if (!texts.length) break;
    const el = row.querySelector('.ct-translated');
    if (!el) continue;
    let text = el.textContent || '';
    const found = [];
    for (const sentence of texts) {
      if (!text.includes(sentence)) continue;
      text = text.split(sentence).join(' ');
      found.push(sentence);
    }
    // A sentence found here, or contained in one found here, is not looked for in older bubbles.
    texts = texts.filter((sentence) => !found.some((f) => f.includes(sentence)));
    text = text.replace(/\s+/g, ' ').trim();
    if (text !== (el.textContent || '').trim()) {
      el.textContent = text;
      newest ??= el;
    }
  }
  return newest;
}

/**
 * Add text to a bubble's translation, e.g. the backup translation in place of sentences removed with
 * removeFromRecentTranslations().
 */
export function appendToBubbleTranslation(el, text) {
  const t = (text || '').trim();
  if (!el || !t) return;
  const current = (el.textContent || '').trim();
  el.textContent = current ? `${current} ${t}` : t;
}

/**
 * Remove every call bubble from the panel. Voicemail bubbles belong to their task and stay until it is
 * closed (removeVoicemailMessage), so a phone call ending does not remove an open voicemail's transcript.
 */
export function clearConversationTranscript() {
  if (!_container) return;
  _container.querySelectorAll('.ct-row:not(.ct-row--voicemail)').forEach((el) => el.remove());
}

// ── private helpers ──────────────────────────────────────────────

function _voicemailRow(contactId) {
  return [..._container.querySelectorAll('.ct-row--voicemail')].find((row) => row.dataset.voicemailContactId === contactId) ?? null;
}

/**
 * Build and insert one chat bubble into #divTranscriptContainer.
 *
 * @param {string} original
 * @param {string} translated
 * @param {string} type              'toAgent' | 'fromAgent'
 * @param {string} translationLabel  e.g. 'Translation (to English)'; for a voicemail, the label above the text
 * @param {{ voicemail?: boolean }} [options]  voicemail: label on top, no translation part
 * @returns {HTMLElement|undefined} the bubble's row
 */
function _insertBubble(original, translated, type, translationLabel, { voicemail = false } = {}) {
  if (!_container) return;

  const isCustomer = type === 'toAgent';

  // Timestamp
  const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

  // Row
  const row = document.createElement('div');
  row.className = `ct-row ${isCustomer ? 'ct-row--customer' : 'ct-row--agent'}${voicemail ? ' ct-row--voicemail' : ''}`;

  // Avatar
  const avatar = document.createElement('div');
  avatar.className = `ct-avatar ${isCustomer ? 'ct-avatar--customer' : 'ct-avatar--agent'}`;
  avatar.innerHTML = voicemail
    ? '<i class="bi bi-voicemail"></i>'
    : isCustomer
      ? '<i class="bi bi-telephone-inbound"></i>'
      : '<i class="bi bi-headset"></i>';

  // Bubble
  const bubble = document.createElement('div');
  bubble.className = `ct-bubble ${isCustomer ? 'ct-bubble--customer' : 'ct-bubble--agent'}`;

  // Original text row
  const origRow = document.createElement('div');
  origRow.className = 'ct-original-row';
  const origText = document.createElement('span');
  origText.className = 'ct-original-text';
  origText.textContent = original;
  const timeEl = document.createElement('span');
  timeEl.className = 'ct-time';
  timeEl.textContent = now;
  origRow.appendChild(origText);
  origRow.appendChild(timeEl);

  // Divider
  const divider = document.createElement('div');
  divider.className = 'ct-divider';

  // Translation label
  const labelEl = document.createElement('div');
  labelEl.className = 'ct-trans-label';
  labelEl.textContent = translationLabel;

  // Translated text
  const transEl = document.createElement('div');
  transEl.className = 'ct-translated';
  transEl.textContent = translated;

  if (voicemail) {
    // "VOICEMAIL" above the caller's words; there is no translation.
    bubble.appendChild(labelEl);
    bubble.appendChild(origRow);
  } else {
    bubble.appendChild(origRow);
    bubble.appendChild(divider);
    bubble.appendChild(labelEl);
    bubble.appendChild(transEl);
  }

  // Assemble row
  if (isCustomer) {
    row.appendChild(avatar);
    row.appendChild(bubble);
  } else {
    row.appendChild(bubble);
    row.appendChild(avatar);
  }

  // Insert before spacer
  const spacer = _container.querySelector('.transcript-spacer');
  _container.insertBefore(row, spacer || null);

  // Slide-in animation
  requestAnimationFrame(() => row.classList.add('ct-row--visible'));

  // Auto-scroll
  _container.scrollTop = _container.scrollHeight;
  return row;
}
