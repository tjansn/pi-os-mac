// Hand-authored EN/DE/mixed transcripts and annotations. All scores are synthetic.
// No ASR output, learned classifier, real speaker identity or real document content.
import { focusBinding } from './gate.mjs';

export const FOCUS = Object.freeze({ app: 'mock-editor', window: 'window-1',
  element: 'note-1', revision: 0, role: 'text', observedAt: 0 });
export const SOURCE = Object.freeze({ kind: 'microphone-human', trusted: true, media: false, selfTts: false });
export const ADDRESS = Object.freeze({ label: 'computer', score: 0.99, activation: 'wake' });
export function observe(at = 0, overrides = {}) {
  return { type: 'focus', at, origin: 'fixture-observation', trusted: true,
    focus: { ...FOCUS, observedAt: at, ...overrides } };
}
export function speech(overrides = {}) {
  return { type: 'speech', at: 100, seq: 1, epoch: 1, session: 'session-1',
    speaker: 'dummy-speaker-1', conversation: 'conversation-1', requestId: 'request-1',
    source: { ...SOURCE }, final: true, complete: true, ambiguous: false,
    quoted: false, negated: false, language: 'en', utterance: 'Pi, increment the mock counter.',
    addressed: { ...ADDRESS }, intent: { kind: 'increment', score: 0.99 },
    targetBinding: focusBinding(FOCUS), ...overrides };
}
export function followup(overrides = {}) {
  return speech({ at: 300, seq: 2, requestId: 'request-2',
    addressed: { ...ADDRESS, activation: 'followup' }, ...overrides });
}
export function control(command, at = 300) {
  return { type: 'control', origin: 'fixture-ui', trusted: true, at, command };
}
const question = () => speech({ language: 'de', utterance: 'Pi, was bedeutet dieser Begriff?',
  intent: { kind: 'question', score: 0.99 } });
const replace = () => speech({ utterance: 'Pi, replace the mock note with a draft.',
  intent: { kind: 'replaceText', score: 0.99, value: 'Dummy draft.' } });
const yes = (overrides = {}) => followup({ language: 'de', utterance: 'Ja, anwenden.',
  intent: { kind: 'confirm', score: 0.99, forRequest: 'request-1' }, ...overrides });

export const scenarios = [
  { name: 'en-room-conversation-command-words', events: [observe(), speech({
    utterance: 'Can you increment the mock counter later?',
    addressed: { label: 'room', score: 0.99, activation: 'none' },
  })], decisions: ['observed', 'ignore'], reason: 'not_addressed', counter: 0 },
  { name: 'de-room-conversation-no-activation', events: [observe(), speech({
    language: 'de', utterance: 'Wir könnten den Zähler erhöhen.',
    addressed: { ...ADDRESS, activation: 'none' },
  })], decisions: ['observed', 'ignore'], reason: 'no_activation_or_scope', counter: 0 },
  { name: 'en-media-even-with-wake', events: [observe(), speech({
    source: { ...SOURCE, media: true },
  })], decisions: ['observed', 'ignore'], reason: 'untrusted_origin', counter: 0 },
  { name: 'de-self-tts-even-with-wake', events: [observe(), speech({ language: 'de',
    utterance: 'Pi, erhöhe den Beispielzähler.', source: { ...SOURCE, selfTts: true },
  })], decisions: ['observed', 'ignore'], reason: 'untrusted_origin', counter: 0 },
  { name: 'en-unknown-origin', events: [observe(), speech({
    source: { ...SOURCE, kind: 'unknown' },
  })], decisions: ['observed', 'ignore'], reason: 'untrusted_origin', counter: 0 },
  { name: 'en-partial-and-incomplete', events: [observe(), speech({ final: false }),
    speech({ seq: 2, at: 200, complete: false, utterance: 'Pi, increment the counter and…' })],
    decisions: ['observed', 'ignore', 'ignore'], reason: 'partial_or_incomplete', counter: 0 },
  { name: 'de-negation-veto', events: [observe(), speech({ language: 'de',
    utterance: 'Pi, erhöhe den Zähler nicht.',
  })], decisions: ['observed', 'clarify'], reason: 'negation', counter: 0 },
  { name: 'en-ambiguous-command', events: [observe(), speech({ ambiguous: true,
    utterance: 'Pi, change that one.',
  })], decisions: ['observed', 'clarify'], reason: 'ambiguous_or_negated', counter: 0 },
  { name: 'high-intent-not-addressed', events: [observe(), speech({
    addressed: { ...ADDRESS, score: 0.2 },
  })], decisions: ['observed', 'ignore'], reason: 'not_addressed', counter: 0 },
  { name: 'addressed-but-uncertain-intent', events: [observe(), speech({
    intent: { kind: 'increment', score: 0.2 },
  })], decisions: ['observed', 'clarify'], reason: 'uncertain_intent', counter: 0 },
  { name: 'de-question-en-scoped-detail-no-typing', events: [observe(), question(), followup({
    utterance: 'In English, please.', intent: { kind: 'questionDetail', score: 0.99 },
  })], decisions: ['observed', 'mock_answer', 'mock_answer'], reason: 'question_not_dictation',
    counter: 0, text: 'Fixture note.' },
  { name: 'question-does-not-arm-dictation', events: [observe(), question(), followup({
    utterance: 'Meeting note.', intent: { kind: 'dictationChunk', score: 0.99, value: 'Meeting note.' },
  })], decisions: ['observed', 'mock_answer', 'ignore'], reason: 'no_activation_or_scope', text: 'Fixture note.' },
  { name: 'de-reversible-counter-en-undo', events: [observe(), speech({ language: 'de',
    utterance: 'Pi, erhöhe den Beispielzähler.',
  }), followup({ utterance: 'Undo.', intent: { kind: 'undo', score: 0.99 } })],
    decisions: ['observed', 'mock_action', 'mock_action'], reason: 'owned_undo', counter: 0 },
  { name: 'en-replace-de-short-confirmation', events: [observe(), replace(), yes()],
    decisions: ['observed', 'confirm', 'mock_action'], reason: 'reversible', text: 'Dummy draft.' },
  { name: 'en-confirmation-expiry-exact-boundary', events: [observe(), replace(), observe(2100),
    yes({ at: 2100 })], decisions: ['observed', 'confirm', 'observed', 'refuse'],
    reason: 'no_matching_confirmation', text: 'Fixture note.' },
  { name: 'cancel-revokes-late-confirmation', events: [observe(), replace(), control('cancel'),
    yes({ at: 400 })], decisions: ['observed', 'confirm', 'cancelled', 'ignore'],
    reason: 'revoked_epoch', text: 'Fixture note.' },
  { name: 'mute-sticky-resume-ui-only', events: [observe(), control('mute', 50), speech(),
    control('resume', 200), speech({ at: 300, seq: 2, epoch: 3 })],
    decisions: ['observed', 'muted', 'ignore', 'resumed', 'mock_action'], reason: 'reversible', counter: 1 },
  { name: 'stale-focus-even-with-high-scores', events: [observe(), speech({ at: 1001 })],
    decisions: ['observed', 'refuse'], reason: 'stale_focus', counter: 0 },
  { name: 'credential-field-dummy-only', events: [observe(0, { role: 'password' }), speech({
    utterance: 'Pi, type DUMMY_ONLY.', targetBinding: focusBinding({ ...FOCUS, role: 'password' }),
    intent: { kind: 'replaceText', score: 1, value: 'DUMMY_ONLY' },
  })], decisions: ['observed', 'refuse'], reason: 'credential_target', text: 'Fixture note.' },
  { name: 'de-delete-prohibited-independent-of-confidence', events: [observe(), speech({ language: 'de',
    utterance: 'Pi, lösche die Beispieldatei.', intent: { kind: 'delete', score: 1 },
  })], decisions: ['observed', 'refuse'], reason: 'prohibited_action', text: 'Fixture note.' },
  { name: 'en-mislabeled-deletion-veto', events: [observe(), speech({
    utterance: 'Pi, empty the trash.', intent: { kind: 'increment', score: 1 },
  })], decisions: ['observed', 'refuse'], reason: 'prohibited_deletion_words', counter: 0 },
  { name: 'en-de-explicit-dictation-session', events: [observe(), speech({
    utterance: 'Pi, dictate into the mock note.', intent: { kind: 'startDictation', score: 0.99 },
  }), yes(), followup({ at: 400, seq: 3, requestId: 'request-3', language: 'mixed',
    utterance: 'Termin morgen at nine.',
    intent: { kind: 'dictationChunk', score: 0.99, value: 'Termin morgen at nine.' },
  }), followup({ at: 500, seq: 4, requestId: 'request-4', language: 'de', utterance: 'Diktat beenden.',
    intent: { kind: 'stopDictation', score: 0.99 },
  })], decisions: ['observed', 'confirm', 'dictation_armed', 'mock_action', 'dictation_stopped'],
    reason: 'explicit_stop', text: 'Fixture note. Termin morgen at nine.' },
];
