import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
const { AttentionSession, compileRecipe, original, shortened } = createRequire(import.meta.url)('./state.js');

test('unpointed request cannot manufacture context', () => {
  const s = new AttentionSession(); assert.equal(s.preview(), false); assert.equal(s.apply(), false); assert.equal(s.body, original);
});
test('point -> preview -> apply -> exact undo', () => {
  const s = new AttentionSession(); s.point(); assert.equal(s.preview(), true); assert.equal(s.body, original);
  assert.equal(s.apply(), true); assert.equal(s.body, shortened); assert.equal(s.undo(), true); assert.equal(s.body, original);
});
test('a stale window target has no authority', () => {
  const s = new AttentionSession(); s.point(); s.preview(); s.changeTarget(); assert.equal(s.currentPoint, false); assert.equal(s.apply(), false); assert.equal(s.preview(), false); assert.equal(s.body, original);
});
test('human edit invalidates proposal', () => {
  const s = new AttentionSession(); s.point(); s.preview(); s.userEdit(); const body = s.body; assert.equal(s.apply(), false); assert.equal(s.body, body);
});
test('human edit invalidates undo rather than removing human text', () => {
  const s = new AttentionSession(); s.point(); s.preview(); s.apply(); s.userEdit(); const body = s.body; assert.equal(s.canUndo, false); assert.equal(s.undo(), false); assert.equal(s.body, body);
});
test('target switch invalidates undo', () => {
  const s = new AttentionSession(); s.point(); s.preview(); s.apply(); s.changeTarget(); assert.equal(s.undo(), false);
});
test('compiler produces a bounded fixture URL, not an entry-point integration', () => {
  assert.deepEqual(compileRecipe('ticket', 'pi-218'), { recipe: 'ticket', kind: 'url-preview', value: 'https://linear.app/example/issue/PI-218', external: true });
});
test('URL recipe cannot accept arbitrary URLs, paths, scripts or exfiltration strings', () => {
  for (const value of ['https://attacker.example', 'PI-218?secret=x', '../../hello', '$(say hello)', 'PI-0', 'PI-1/../../', 'PI-2\nTOKEN=3']) assert.throws(() => compileRecipe('ticket', value));
});
test('unknown recipe and non-string inputs are rejected', () => {
  for (const id of ['shell', '__proto__', 'constructor']) assert.throws(() => compileRecipe(id, 'PI-218'));
  assert.throws(() => compileRecipe('ticket', null)); assert.throws(() => compileRecipe('followup', 'x'.repeat(1001)));
});
test('dynamic placeholder uses an explicit reproducible fixture date', () => {
  assert.equal(compileRecipe('followup', 'the prototype').value, 'Thanks for sharing “the prototype”. I’ll get back to you by 2026-10-16.');
  assert.throws(() => compileRecipe('followup', 'hello', '2026-02-30')); assert.throws(() => compileRecipe('followup', 'hello', 'bad'));
});
test('page declares a network/media-denying CSP and no remote resources', () => {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  assert.match(html, /connect-src 'none'/); assert.match(html, /media-src 'none'/);
  assert.doesNotMatch(html, /(?:src|href)=["']https?:/);
});
