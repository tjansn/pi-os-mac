// MOCK ONLY: deterministic fixture policy. No audio, models, network, timers or OS APIs.
// Scores and source/speaker assertions are supplied synthetic inputs, not authentication.
export const LIMITS = Object.freeze({
  addressScore: 0.85, intentScore: 0.8, focusAgeMs: 1000,
  followupMs: 5000, confirmationMs: 2000, maxText: 400,
});

const risk = Object.freeze({
  increment: 'reversible', replaceText: 'confirm', undo: 'reversible',
  question: 'answer', questionDetail: 'answer', startDictation: 'confirm',
  dictationChunk: 'dictation', stopDictation: 'control', cancel: 'control',
  mute: 'control', confirm: 'confirmation', delete: 'prohibited', external: 'prohibited',
});
const credentialRoles = new Set(['username', 'password', 'credential']);
const validRole = new Set(['text', 'button', ...credentialRoles]);
const unit = (x) => Number.isFinite(x) && x >= 0 && x <= 1;
const id = (x) => typeof x === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(x);
const plain = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);
const text = (x) => typeof x === 'string' && x.trim().length > 0
  && x.length <= LIMITS.maxText && !/[\u0000-\u001f\u007f-\u009f]/u.test(x);
const same = (a, b) => a !== null && b !== null && a === b;
const copy = (x) => structuredClone(x);
const binding = (f) => f ? JSON.stringify([f.app, f.window, f.element, f.revision, f.role]) : null;
const deletionWords = /\b(delete|erase|trash|unlink|remove|recycle|lösch(?:e|en|t)?|loesch(?:e|en|t)?|entfern(?:e|en|t)?|papierkorb)\b/iu;
const negationWords = /\b(don't|don’t|do not|never|not|nicht|kein|keine|keinen|nein)\b/iu;

export class AmbientGate {
  #at = -1;
  #seq = -1;
  #epoch = 0;
  #muted = false;
  #focus = null;
  #pending = null;
  #aperture = null;
  #dictation = null;
  #undo = null;
  #world = { counter: 0, text: 'Fixture note.', version: 0 };

  // Content-free authority/status plus explicitly dummy mock document; never keep utterances.
  snapshot() {
    return copy({ at: this.#at, epoch: this.#epoch, muted: this.#muted,
      pending: this.#pending ? { requestId: this.#pending.requestId, expires: this.#pending.expires } : null,
      followupUntil: this.#aperture?.expires ?? null, dictating: this.#dictation !== null,
      world: this.#world });
  }

  #result(decision, reason, extra = {}) {
    return { decision, reason, epoch: this.#epoch, ...extra };
  }
  #revoke() { this.#pending = null; this.#aperture = null; this.#dictation = null; }
  #invalidate() { this.#revoke(); this.#undo = null; this.#epoch += 1; }
  #deny(reason, decision = 'refuse') { this.#revoke(); return this.#result(decision, reason); }
  #expire() {
    if (this.#pending && this.#at >= this.#pending.expires) this.#pending = null;
    if (this.#aperture && this.#at >= this.#aperture.expires) this.#aperture = null;
    if (this.#dictation && this.#at >= this.#dictation.expires) this.#dictation = null;
  }
  #freshFocus() {
    return this.#focus && this.#at - this.#focus.observedAt <= LIMITS.focusAgeMs;
  }
  #scope(e) {
    return { session: e.session, speaker: e.speaker, conversation: e.conversation,
      binding: binding(this.#focus), epoch: this.#epoch };
  }
  #matches(scope, e) {
    return scope && scope.session === e.session && scope.speaker === e.speaker
      && scope.conversation === e.conversation && scope.epoch === this.#epoch
      && same(scope.binding, binding(this.#focus));
  }
  #open(e, allowed) {
    this.#aperture = { ...this.#scope(e), allowed, expires: this.#at + LIMITS.followupMs };
  }
  #apply(e, kind, value) {
    const before = copy(this.#world);
    if (kind === 'increment') this.#world.counter += 1;
    else if (kind === 'replaceText') this.#world.text = value;
    else if (kind === 'dictationChunk') this.#world.text += ` ${value}`;
    else return this.#deny('unknown_action');
    this.#world.version += 1;
    this.#undo = { ...this.#scope(e), before, afterVersion: this.#world.version };
    this.#open(e, kind === 'dictationChunk' ? ['dictationChunk', 'stopDictation', 'undo', 'cancel', 'mute']
      : ['undo', 'cancel', 'mute']);
    return this.#result('mock_action', 'reversible', { action: kind });
  }

  step(e) {
    if (!plain(e) || !Number.isSafeInteger(e.at) || e.at < 0 || e.at < this.#at) {
      this.#invalidate();
      return this.#result('refuse', 'invalid_clock');
    }
    this.#at = e.at;
    this.#expire();
    if (e.type === 'tick') {
      return e.trusted === true && e.origin === 'fixture-runtime'
        ? this.#result('idle', 'clock_advanced') : this.#deny('untrusted_event');
    }
    if (e.type === 'focus') {
      const f = e.focus;
      if (e.trusted !== true || e.origin !== 'fixture-observation' || !plain(f)
        || ![f.app, f.window, f.element].every(id) || !validRole.has(f.role)
        || !Number.isSafeInteger(f.revision) || f.revision < 0
        || !Number.isSafeInteger(f.observedAt) || f.observedAt < 0 || f.observedAt > e.at) {
        this.#focus = null;
        this.#invalidate();
        return this.#result('refuse', 'invalid_focus');
      }
      if (binding(f) !== binding(this.#focus)) this.#invalidate();
      this.#focus = copy(f);
      return this.#result('observed', 'mock_focus');
    }
    if (e.type === 'control') {
      if (e.origin !== 'fixture-ui' || e.trusted !== true
        || !['mute', 'resume', 'cancel'].includes(e.command)) return this.#deny('untrusted_control');
      this.#invalidate();
      if (e.command === 'mute') this.#muted = true;
      if (e.command === 'resume') this.#muted = false;
      return this.#result(e.command === 'cancel' ? 'cancelled' : e.command === 'mute' ? 'muted' : 'resumed', 'fixture_ui');
    }
    if (e.type === 'fixtureEdit') {
      if (e.origin !== 'fixture-ui' || e.trusted !== true || !text(e.value)) return this.#deny('untrusted_edit');
      this.#world.text = e.value;
      this.#world.version += 1;
      this.#invalidate();
      return this.#result('observed', 'mock_external_edit');
    }
    if (e.type !== 'speech') return this.#deny('unknown_event');
    if (this.#muted) return this.#deny('muted', 'ignore');
    // Hard origin rules precede ALL confidence/intent checks.
    if (!plain(e.source) || e.source.kind !== 'microphone-human' || e.source.trusted !== true
      || e.source.media !== false || e.source.selfTts !== false) return this.#deny('untrusted_origin', 'ignore');
    if (!Number.isSafeInteger(e.epoch) || e.epoch !== this.#epoch) return this.#deny('revoked_epoch', 'ignore');
    if (!Number.isSafeInteger(e.seq) || e.seq < 0 || e.seq <= this.#seq) return this.#deny('stale_sequence', 'ignore');
    this.#seq = e.seq;
    if (![e.session, e.speaker, e.conversation, e.requestId].every(id)) return this.#deny('missing_scope');
    if (e.final !== true || e.complete !== true) return this.#deny('partial_or_incomplete', 'ignore');
    if (e.ambiguous !== false || e.quoted !== false || e.negated !== false) return this.#deny('ambiguous_or_negated', 'clarify');
    if (!text(e.utterance) || !['en', 'de', 'mixed'].includes(e.language)) return this.#deny('invalid_utterance');
    if (!plain(e.addressed) || !unit(e.addressed.score) || e.addressed.label !== 'computer'
      || e.addressed.score < LIMITS.addressScore) return this.#deny('not_addressed', 'ignore');
    const k = e.intent?.kind;
    const explicit = ['wake', 'ptt'].includes(e.addressed.activation);
    const followup = e.addressed.activation === 'followup' && this.#matches(this.#aperture, e)
      && this.#aperture.allowed.includes(k);
    if (!explicit && !followup) return this.#deny('no_activation_or_scope', 'ignore');
    // Safety controls revoke authority; they are not field input and need no fresh target.
    if (k === 'cancel' || k === 'mute') {
      this.#invalidate();
      if (k === 'mute') this.#muted = true;
      return this.#result(k === 'mute' ? 'muted' : 'cancelled', 'addressed_control');
    }
    // A matched wake token is evidence only, never command/action authorization.
    if (!this.#freshFocus() || e.targetBinding !== binding(this.#focus)) return this.#deny('stale_focus');
    if (credentialRoles.has(this.#focus.role)) return this.#deny('credential_target');
    if (!Object.hasOwn(risk, k)) return this.#deny('unknown_intent', 'clarify');
    if (risk[k] === 'prohibited') return this.#deny('prohibited_action');
    // Conservative vocabulary veto also catches a mislabeled candidate/ASR alternative.
    const alternatives = e.alternatives ?? [];
    if (!Array.isArray(alternatives) || alternatives.length > 4 || !alternatives.every(text)) return this.#deny('invalid_alternatives');
    const words = [e.utterance, ...alternatives];
    if (words.some((s) => deletionWords.test(s))) return this.#deny('prohibited_deletion_words');
    if (words.some((s) => negationWords.test(s))) return this.#deny('negation', 'clarify');
    if (!unit(e.intent.score) || e.intent.score < LIMITS.intentScore) return this.#deny('uncertain_intent', 'clarify');
    if (k !== 'confirm') this.#pending = null; // Latest addressed request replaces queued work.
    if (k === 'confirm') {
      const p = this.#pending;
      if (!p || e.intent.forRequest !== p.requestId || !this.#matches(p, e)
        || this.#world.version !== p.worldVersion) return this.#deny('no_matching_confirmation');
      this.#pending = null; // Single-use, consumed before applying anything.
      if (p.kind === 'startDictation') {
        this.#dictation = { ...this.#scope(e), expires: this.#at + LIMITS.followupMs };
        this.#open(e, ['dictationChunk', 'stopDictation', 'cancel', 'mute']);
        return this.#result('dictation_armed', 'explicit_confirmed_destination');
      }
      return this.#apply(e, p.kind, p.value);
    }
    if (risk[k] === 'confirm') {
      if (this.#focus.role !== 'text') return this.#deny('not_text_target');
      if (k === 'replaceText' && !text(e.intent.value)) return this.#deny('invalid_payload');
      this.#dictation = null;
      this.#pending = { ...this.#scope(e), kind: k, value: e.intent.value,
        requestId: e.requestId, worldVersion: this.#world.version,
        expires: this.#at + LIMITS.confirmationMs };
      this.#open(e, ['confirm', 'cancel', 'mute']);
      return this.#result('confirm', 'destination_change', { requestId: e.requestId, expires: this.#pending.expires });
    }
    if (k === 'question' || k === 'questionDetail') {
      if (k === 'questionDetail' && !followup) return this.#deny('no_question_scope');
      this.#dictation = null;
      this.#open(e, ['questionDetail', 'cancel', 'mute']);
      return this.#result('mock_answer', 'question_not_dictation', { answerId: 'canned-local-answer' });
    }
    if (k === 'dictationChunk') {
      if (this.#focus.role !== 'text' || !this.#matches(this.#dictation, e)
        || !text(e.intent.value) || e.intent.value !== e.utterance) return this.#deny('dictation_not_armed');
      // Absolute dictation TTL is NOT extended by chunks; a new explicit request is needed.
      return this.#apply(e, k, e.intent.value);
    }
    if (k === 'stopDictation') {
      this.#revoke();
      return this.#result('dictation_stopped', 'explicit_stop');
    }
    this.#dictation = null;
    if (k === 'undo') {
      const u = this.#undo;
      if (!this.#matches(u, e) || this.#world.version !== u.afterVersion) return this.#deny('undo_not_owned');
      const version = this.#world.version + 1;
      this.#world = { ...u.before, version };
      this.#undo = null;
      this.#revoke();
      return this.#result('mock_action', 'owned_undo', { action: 'undo' });
    }
    return this.#apply(e, k, e.intent.value);
  }
}

export function focusBinding(focus) { return binding(focus); }
export function replay(events) {
  const gate = new AmbientGate();
  return { decisions: events.map((event) => gate.step(event)), state: gate.snapshot() };
}
