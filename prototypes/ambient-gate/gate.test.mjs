import test from 'node:test';
import assert from 'node:assert/strict';
import { AmbientGate, focusBinding, LIMITS, replay } from './gate.mjs';
import { ADDRESS, FOCUS, SOURCE, control, followup, observe, scenarios, speech } from './fixtures.mjs';

for (const scenario of scenarios) {
  test(`fixture: ${scenario.name}`, () => {
    const { decisions, state } = replay(scenario.events);
    assert.deepEqual(decisions.map((d) => d.decision), scenario.decisions);
    assert.equal(decisions.at(-1).reason, scenario.reason);
    if ('counter' in scenario) assert.equal(state.world.counter, scenario.counter);
    if ('text' in scenario) assert.equal(state.world.text, scenario.text);
    assert.equal(state.dictating, false);
  });
}

function ready() {
  const gate = new AmbientGate();
  gate.step(observe());
  return gate;
}
function replacement() {
  return speech({ intent: { kind: 'replaceText', score: 0.99, value: 'Dummy draft.' } });
}
function confirmation(overrides = {}) {
  return followup({ utterance: 'Yes, apply.',
    intent: { kind: 'confirm', score: 0.99, forRequest: 'request-1' }, ...overrides });
}
function question() {
  return speech({ utterance: 'Pi, explain the fixture.', intent: { kind: 'question', score: 0.99 } });
}
function detail(overrides = {}) {
  return followup({ utterance: 'Auf Deutsch, bitte.', language: 'de',
    intent: { kind: 'questionDetail', score: 0.99 }, ...overrides });
}
function armedDictation() {
  const gate = ready();
  gate.step(speech({ intent: { kind: 'startDictation', score: 0.99 } }));
  gate.step(confirmation());
  return gate;
}
function chunk(overrides = {}) {
  return followup({ at: 400, seq: 3, requestId: 'request-3', utterance: 'Dummy sentence.',
    intent: { kind: 'dictationChunk', score: 0.99, value: 'Dummy sentence.' }, ...overrides });
}

test('all replay scenarios are deterministic and do not mutate fixtures', () => {
  const before = structuredClone(scenarios);
  for (const scenario of scenarios) assert.deepEqual(replay(scenario.events), replay(scenario.events));
  assert.deepEqual(scenarios, before);
});

test('origin denial wins even when BOTH synthetic scores are maximal', () => {
  const origins = [null, {}, { ...SOURCE, trusted: false }, { ...SOURCE, trusted: undefined },
    { ...SOURCE, kind: 'media' }, { ...SOURCE, kind: 'self-tts' },
    { ...SOURCE, media: undefined }, { ...SOURCE, selfTts: undefined }];
  for (const source of origins) {
    const gate = ready();
    assert.equal(gate.step(speech({ source, addressed: { ...ADDRESS, score: 1 },
      intent: { kind: 'increment', score: 1 } })).reason, 'untrusted_origin');
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('missing finality, completeness or uncertainty flags fail closed', () => {
  for (const property of ['final', 'complete', 'ambiguous', 'quoted', 'negated']) {
    const event = speech();
    delete event[property];
    const gate = ready();
    assert.notEqual(gate.step(event).decision, 'mock_action');
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('unknown intent is not an action or dictation fallback', () => {
  for (const kind of ['none', 'unknown', '__proto__', 'constructor']) {
    const gate = ready();
    assert.equal(gate.step(speech({ intent: { kind, score: 1 } })).reason, 'unknown_intent');
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('unknown events, focus roles and untrusted UI cannot grant authority', () => {
  const gate = ready();
  assert.equal(gate.step({ type: 'control', at: 20, command: 'resume', trusted: true,
    origin: 'microphone-human' }).reason, 'untrusted_control');
  assert.equal(gate.step({ type: 'runShell', at: 30 }).reason, 'unknown_event');
  assert.equal(gate.step(observe(40, { role: 'unknown' })).reason, 'invalid_focus');
  assert.equal(gate.step(speech()).reason, 'revoked_epoch');
});

test('prohibited risks are independent of intent score, including invalid scores', () => {
  for (const kind of ['delete', 'external']) for (const score of [0, 0.5, 1, NaN]) {
    const gate = ready();
    assert.equal(gate.step(speech({ intent: { kind, score } })).reason, 'prohibited_action');
    assert.equal(gate.snapshot().pending, null);
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('username/password/credential fields are always denied in this mock', () => {
  for (const role of ['username', 'password', 'credential']) {
    const gate = new AmbientGate();
    gate.step(observe(0, { role }));
    assert.equal(gate.step(speech({ targetBinding: focusBinding({ ...FOCUS, role }) })).reason, 'credential_target');
  }
});

test('ordinary text typing is not vetoed by unrelated global secure-keyboard metadata', () => {
  const gate = ready();
  gate.step(replacement());
  assert.equal(gate.step(confirmation({ osSecureKeyboardEntry: true })).decision, 'mock_action');
});

test('quoted, negated and uncertain commands cannot act', () => {
  for (const patch of [{ quoted: true }, { negated: true }, { ambiguous: true },
    { intent: { kind: 'increment', score: NaN } }, { addressed: { ...ADDRESS, score: Infinity } }]) {
    const gate = ready();
    assert.notEqual(gate.step(speech(patch)).decision, 'mock_action');
  }
});

test('a dangerous alternative cannot be replaced by a safe-sounding candidate', () => {
  for (const alternative of ['Pi, delete that file.', 'Pi, lösche die Datei.', 'Pi, do not increment.']) {
    const gate = ready();
    assert.notEqual(gate.step(speech({ alternatives: [alternative] })).decision, 'mock_action');
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('freshness boundary is inclusive but one millisecond older is refused', () => {
  assert.equal(ready().step(speech({ at: LIMITS.focusAgeMs })).decision, 'mock_action');
  assert.equal(ready().step(speech({ at: LIMITS.focusAgeMs + 1 })).reason, 'stale_focus');
});

test('target fingerprint is checked even without a focus-change event', () => {
  assert.equal(ready().step(speech({ targetBinding: focusBinding({ ...FOCUS, element: 'other' }) })).reason, 'stale_focus');
});

test('focus switch revokes a pending confirmation, including late results', () => {
  for (const change of [{ app: 'other-app' }, { window: 'other-window' },
    { element: 'other-element' }, { revision: 1 }, { role: 'password' }]) {
    const gate = ready();
    gate.step(replacement());
    gate.step(observe(200, change));
    assert.equal(gate.step(confirmation()).reason, 'revoked_epoch');
    assert.equal(gate.snapshot().world.text, 'Fixture note.');
  }
});

test('confirmation scope binds request, speaker, session and conversation', () => {
  for (const change of [{ speaker: 'dummy-other' }, { session: 'other-session' },
    { conversation: 'other-conversation' },
    { intent: { kind: 'confirm', score: 1, forRequest: 'wrong-request' } }]) {
    const gate = ready();
    gate.step(replacement());
    assert.notEqual(gate.step(confirmation(change)).decision, 'mock_action');
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('confirmation just before TTL works; exact TTL is expired even with fresh focus', () => {
  for (const [at, expected] of [[2099, 'mock_action'], [2100, 'refuse']]) {
    const gate = ready();
    gate.step(replacement());
    gate.step(observe(at));
    assert.equal(gate.step(confirmation({ at })).decision, expected);
  }
});

test('confirmation is single-use; replayed sequences never duplicate effects', () => {
  const gate = ready();
  gate.step(replacement());
  assert.equal(gate.step(confirmation()).decision, 'mock_action');
  assert.equal(gate.step(confirmation()).reason, 'stale_sequence');
  assert.equal(gate.step(confirmation({ at: 400, seq: 3 })).decision, 'ignore');
  assert.equal(gate.snapshot().world.version, 1);
});

test('a newer addressed request replaces old pending work', () => {
  const gate = ready();
  gate.step(replacement());
  gate.step(speech({ at: 200, seq: 2, requestId: 'new-request' }));
  assert.equal(gate.snapshot().pending, null);
  assert.equal(gate.step(confirmation({ at: 300, seq: 3 })).decision, 'ignore');
  assert.equal(gate.snapshot().world.text, 'Fixture note.');
});

test('speech cancel/mute revoke generation; no queued work survives', () => {
  for (const kind of ['cancel', 'mute']) {
    const gate = ready();
    gate.step(replacement());
    const result = gate.step(followup({ intent: { kind, score: 0 }, utterance: kind }));
    assert.equal(result.decision, kind === 'cancel' ? 'cancelled' : 'muted');
    assert.equal(gate.snapshot().pending, null);
    assert.equal(gate.step(confirmation({ at: 400, seq: 3 })).decision, 'ignore');
    assert.equal(gate.snapshot().world.version, 0);
  }
});

test('addressed safety controls work despite stale or credential focus; media cannot mute', () => {
  for (const kind of ['cancel', 'mute']) {
    const stale = ready();
    stale.step(replacement());
    assert.equal(stale.step(speech({ at: 1100, seq: 2,
      targetBinding: 'stale-target', intent: { kind, score: 0 } })).decision,
    kind === 'mute' ? 'muted' : 'cancelled');
    assert.equal(stale.snapshot().pending, null);
    const credential = new AmbientGate();
    credential.step(observe(0, { role: 'password' }));
    assert.equal(credential.step(speech({ intent: { kind, score: 0 } })).decision,
      kind === 'mute' ? 'muted' : 'cancelled');
    const media = ready();
    assert.equal(media.step(speech({ source: { ...SOURCE, media: true },
      intent: { kind, score: 1 } })).reason, 'untrusted_origin');
    assert.equal(media.snapshot().muted, false);
  }
});

test('follow-up window is bound to topic, session, speaker, target and time', () => {
  for (const change of [{ speaker: 'dummy-other' }, { session: 'other-session' },
    { conversation: 'other-conversation' }, { intent: { kind: 'increment', score: 1 } }]) {
    const gate = ready();
    gate.step(question());
    assert.equal(gate.step(detail(change)).decision, 'ignore');
  }
  const gate = ready();
  gate.step(question());
  gate.step(observe(5100));
  assert.equal(gate.step(detail({ at: 5100 })).decision, 'ignore');
});

test('dictation needs explicit destination confirmation, not a caret or a high score', () => {
  assert.equal(ready().step(chunk({ seq: 1, at: 100, addressed: { ...ADDRESS } })).reason, 'dictation_not_armed');
  const gate = armedDictation();
  assert.equal(gate.step(chunk()).decision, 'mock_action');
  assert.equal(gate.snapshot().world.text, 'Fixture note. Dummy sentence.');
});

test('dictation TTL is absolute, and unknown sources revoke an armed session', () => {
  const gate = armedDictation();
  gate.step(chunk());
  gate.step(observe(5300));
  assert.equal(gate.step(chunk({ at: 5300, seq: 4 })).reason, 'dictation_not_armed');
  assert.equal(gate.snapshot().world.text, 'Fixture note. Dummy sentence.');
  const second = armedDictation();
  second.step(chunk({ source: { ...SOURCE, media: true } }));
  assert.equal(second.step(chunk({ at: 500, seq: 4, addressed: { ...ADDRESS } })).reason, 'dictation_not_armed');
});

test('undo will not overwrite mock user edits or changed targets', () => {
  const gate = ready();
  gate.step(speech());
  gate.step({ type: 'fixtureEdit', origin: 'fixture-ui', trusted: true, at: 200, value: 'Dummy user edit.' });
  assert.equal(gate.step(speech({ at: 300, seq: 2, epoch: 2,
    intent: { kind: 'undo', score: 1 } })).reason, 'undo_not_owned');
  assert.equal(gate.snapshot().world.text, 'Dummy user edit.');
  assert.equal(gate.snapshot().world.counter, 1);
});

test('clock rollback invalidates capabilities and cannot create an action', () => {
  const gate = ready();
  gate.step(replacement());
  assert.equal(gate.step(confirmation({ at: 99 })).reason, 'invalid_clock');
  assert.equal(gate.snapshot().pending, null);
  assert.equal(gate.snapshot().world.version, 0);
});

test('rejected background content is not retained in results or snapshot', () => {
  const gate = ready();
  const marker = 'DUMMY_PRIVATE_BACKGROUND_MARKER';
  const result = gate.step(speech({ utterance: marker, addressed: { label: 'room', score: 1, activation: 'none' } }));
  assert.equal(JSON.stringify([result, gate.snapshot()]).includes(marker), false);
});
