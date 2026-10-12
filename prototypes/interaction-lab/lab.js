/* UI simulation only. Keep this independent of the production app. */
'use strict';
const { AttentionSession, compileRecipe, recipes } = globalThis.InteractionLab;
const session = new AttentionSession();
const $ = (id) => document.getElementById(id);
let study = 'attention';
let muted = false;
let recipeReceipt = 'Choose an entry point. This recipe can only produce a preview.';
let ambientReceipt = 'Start with room conversation. Not every command-shaped sentence addresses the computer.';
const events = Object.freeze({
  room: { label: 'Ignored · not addressed', reason: 'A command-shaped sentence is not permission. Stay silent; discard the fixture event.' },
  addressed: { label: 'Would request a mock preview', reason: 'Explicit address + complete utterance + known mock target. A report preview would appear; no real file is opened.' },
  media: { label: 'Ignored · playback fixture', reason: 'This event is labeled media in the fixture. Real playback rejection needs acoustic testing; the word “Pi” alone does not establish human intent.' },
  unclear: { label: 'Clarify · no action', reason: '“It” has no bound target. Ask which draft. This study does not send messages or offer a fake Send button.' },
  partial: { label: 'Ignored · incomplete / cancelled', reason: 'Partials may preview, never act. The final correction cancels the candidate.' }
});
function facts(items) {
  $('facts').replaceChildren();
  for (const [term, detail] of items) {
    const dt = document.createElement('dt'); dt.textContent = term;
    const dd = document.createElement('dd'); dd.textContent = detail;
    $('facts').append(dt, dd);
  }
}
function render() {
  for (const name of ['attention', 'recipes', 'ambient']) $(name + '-stage').hidden = study !== name;
  for (const button of document.querySelectorAll('[data-study]')) {
    const active = button.dataset.study === study;
    button.classList.toggle('active', active); button.setAttribute('aria-pressed', String(active));
  }
  $('failure-tools').hidden = study !== 'attention';
  document.querySelector('.receipt').setAttribute('aria-live', study === 'attention' ? 'polite' : 'off');
  if (study === 'attention') {
    $('target-name').textContent = `${session.targetId === 'mock-notes' ? 'Notes' : 'Mail'} · mock window`;
    $('paragraph-text').textContent = session.body;
    const currentPoint = session.currentPoint;
    $('paragraph-region').classList.toggle('pointed', currentPoint);
    $('point').setAttribute('aria-pressed', String(Boolean(currentPoint)));
    document.querySelector('.point-label').textContent = currentPoint ? 'Included · one paragraph' : session.pointed ? 'Target changed · point again' : 'Point to include this paragraph';
    $('draft').hidden = !session.proposal;
    $('draft-text').textContent = session.proposal?.after || '';
    $('undo').disabled = !session.canUndo;
    $('undo').textContent = session.receipt && !session.canUndo ? 'Undo unavailable · target changed' : 'Undo mock edit';
    $('inspector-title').textContent = 'A visible attention contract.';
    facts([
      ['Included context', currentPoint ? 'One pointed paragraph' : session.pointed ? 'Historical paragraph · stale, not authorized' : 'None · point to include'],
      ['Action target', currentPoint ? `${session.pointed.targetId} · revision ${session.pointed.revision}` : 'Not bound'],
      ['Intelligence', 'Canned rewrite · no model'],
      ['Authority', 'Preview first · recheck on Apply']
    ]);
    $('receipt').textContent = session.message;
  } else if (study === 'recipes') {
    const recipe = recipes[$('recipe').value];
    $('inspector-title').textContent = 'A small, inspectable capability.';
    facts([['Recipe input', recipe.input], ['Effect', recipe.effect], ['Entry point', 'Keyboard / voice fixture / selection'], ['Boundary', 'No shell, arbitrary URL or live action']]);
    $('receipt').textContent = recipeReceipt;
  } else {
    $('inspector-title').textContent = 'Attention before intention.';
    facts([['Recognition', 'None · transcript fixtures only'], ['Decision model', 'None · scripted UX cases'], ['Action boundary', 'Mock previews only'], ['Privacy boundary', 'No microphone / no network']]);
    $('receipt').textContent = ambientReceipt;
    $('listen-title').textContent = muted ? 'Muted · simulated' : 'Listening · simulated';
    $('mic-status').classList.toggle('muted', muted);
    $('mute').textContent = muted ? 'Resume simulation' : 'Mute simulation';
    $('mute').setAttribute('aria-pressed', String(muted));
  }
}
for (const button of document.querySelectorAll('[data-study]')) button.addEventListener('click', () => { study = button.dataset.study; render(); });
$('point').addEventListener('click', () => { session.point(); render(); });
$('preview').addEventListener('click', () => { session.preview(); render(); if (session.proposal) $('draft-text').focus(); });
$('apply').addEventListener('click', () => { session.apply(); render(); $('preview').focus(); });
$('discard').addEventListener('click', () => { session.proposal = null; session.message = 'Discarded preview. The mock note is unchanged.'; render(); $('preview').focus(); });
$('switch-target').addEventListener('click', () => { session.changeTarget(); render(); });
$('user-edit').addEventListener('click', () => { session.userEdit(); render(); });
$('undo').addEventListener('click', () => { session.undo(); render(); $('preview').focus(); });
$('reset').addEventListener('click', () => { session.reset(); render(); });
function invalidateRecipe() {
  $('recipe-value').textContent = 'Input changed. Choose an entry point to create a fresh preview.';
  $('argument').setAttribute('aria-invalid', 'false');
  recipeReceipt = 'No current preview. Nothing has been executed.'; render();
}
$('argument').addEventListener('input', invalidateRecipe);
$('recipe').addEventListener('change', () => {
  $('argument').setAttribute('aria-invalid', 'false');
  $('argument').value = $('recipe').value === 'ticket' ? 'PI-218' : 'the prototype';
  $('recipe-value').textContent = 'Choose an entry point to compile the recipe.';
  recipeReceipt = 'This recipe can only produce a preview.'; render();
});
for (const button of document.querySelectorAll('[data-trigger]')) button.addEventListener('click', () => {
  try {
    const result = compileRecipe($('recipe').value, $('argument').value);
    $('argument').setAttribute('aria-invalid', 'false');
    $('recipe-value').textContent = result.value;
    recipeReceipt = `${button.dataset.trigger} → same validated recipe → ${result.kind}. No external effect. Fixture date: 2026-10-09.`;
  } catch (error) { $('recipe-value').textContent = error.message; $('argument').setAttribute('aria-invalid', 'true'); recipeReceipt = 'Invalid argument. No preview or action produced.'; }
  render();
});
$('mute').addEventListener('click', () => {
  muted = !muted; ambientReceipt = muted ? 'Muted immediately. In production this must stop capture and clear volatile audio.' : 'Simulation resumed; real always-on listening remains off.';
  $('ambient-label').textContent = muted ? 'Muted · no action' : 'No action'; $('ambient-reason').textContent = ambientReceipt; render();
});
for (const button of document.querySelectorAll('[data-event]')) button.addEventListener('click', () => {
  const event = muted ? { label: 'Muted · ignored', reason: 'Muted means no event reaches the action path.' } : events[button.dataset.event];
  $('ambient-label').textContent = event.label; $('ambient-reason').textContent = event.reason;
  ambientReceipt = event.reason; render();
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    if (study === 'attention') {
      const hadPreview = Boolean(session.proposal); session.proposal = null;
      session.message = hadPreview ? 'Preview discarded. Earlier edits stay unchanged.' : 'No pending preview. Earlier edits stay unchanged.';
      render(); $('preview').focus();
    }
    else if (study === 'ambient') { muted = true; ambientReceipt = 'Muted immediately by Escape. No real microphone was open.'; $('ambient-label').textContent = 'Muted · no action'; $('ambient-reason').textContent = ambientReceipt; }
    render();
  }
});
render();
