/* Disposable, deterministic mock. No model, microphone, network or OS actions. */
(function (root) {
  'use strict';
  const original = 'We would like to take this opportunity to let you know that the prototype is ready for your review. Please do not hesitate to share your thoughts with us.';
  const shortened = 'The prototype is ready for review. What do you think?';
  const recipes = Object.freeze({
    ticket: Object.freeze({ name: 'Find a ticket', input: 'Selected issue ID', effect: 'Preview an HTTPS link', risk: 'navigation', host: 'linear.app' }),
    followup: Object.freeze({ name: 'A reply that knows the date', input: 'Selected text + fixture date', effect: 'Preview a local text snippet', risk: 'draft' })
  });
  function compileRecipe(id, input, fixtureDate = '2026-10-09') {
    if (!Object.hasOwn(recipes, id)) throw new Error('Unknown recipe');
    if (typeof input !== 'string' || input.length > 1000) throw new Error('Invalid input');
    if (id === 'ticket') {
      const key = input.trim().toUpperCase();
      if (!/^[A-Z]{2,8}-[1-9][0-9]{0,6}$/.test(key)) throw new Error('Select an issue ID such as PI-218');
      return Object.freeze({ recipe: id, kind: 'url-preview', value: `https://linear.app/example/issue/${encodeURIComponent(key)}`, external: true });
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fixtureDate)) throw new Error('Invalid fixture date');
    const date = new Date(`${fixtureDate}T00:00:00Z`);
    if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== fixtureDate) throw new Error('Invalid fixture date');
    date.setUTCDate(date.getUTCDate() + 7);
    return Object.freeze({ recipe: id, kind: 'draft-preview', value: `Thanks for sharing “${input.trim() || 'the prototype'}”. I’ll get back to you by ${date.toISOString().slice(0, 10)}.`, external: false });
  }
  class AttentionSession {
    constructor() { this.reset(); }
    reset() {
      this.body = original; this.targetId = 'mock-notes'; this.revision = 1; this.pointed = null;
      this.proposal = null; this.receipt = null; this.message = 'Point at the paragraph to give “this” a meaning.';
    }
    point() {
      this.pointed = Object.freeze({ targetId: this.targetId, revision: this.revision, text: this.body });
      this.proposal = null; this.message = 'Only the pointed paragraph is included. No surrounding window is read.';
    }
    get currentPoint() { return Boolean(this.pointed && this.pointed.targetId === this.targetId && this.pointed.revision === this.revision && this.pointed.text === this.body); }
    get canUndo() { const r = this.receipt; return Boolean(r && r.targetId === this.targetId && r.revision === this.revision && r.after === this.body); }
    preview() {
      if (!this.currentPoint) { this.proposal = null; this.message = this.pointed ? 'The target changed. Point again before previewing.' : 'What should I shorten? Point first.'; return false; }
      this.proposal = Object.freeze({ before: this.pointed.text, after: shortened, targetId: this.pointed.targetId, revision: this.pointed.revision });
      this.message = 'Canned draft preview. Nothing in the document has changed.'; return true;
    }
    apply() {
      const p = this.proposal;
      if (!p || p.targetId !== this.targetId || p.revision !== this.revision || p.before !== this.body) {
        this.proposal = null; this.message = 'The target changed. Nothing applied; point again.'; return false;
      }
      this.body = p.after; this.revision += 1;
      this.receipt = Object.freeze({ before: p.before, after: p.after, targetId: this.targetId, revision: this.revision });
      this.pointed = null; this.proposal = null; this.message = 'Applied to the mock paragraph only. Undo is bound to this edit.'; return true;
    }
    changeTarget() {
      this.targetId = this.targetId === 'mock-notes' ? 'mock-mail' : 'mock-notes'; this.revision += 1;
      this.message = 'Focus changed. The old proposal has no authority over the new window.';
    }
    userEdit() { this.body += ' Another thought.'; this.revision += 1; this.message = 'A simulated human edit changed the paragraph.'; }
    undo() {
      const r = this.receipt;
      if (!r || r.targetId !== this.targetId || r.revision !== this.revision || r.after !== this.body) {
        this.message = 'Cannot prove this is still our edit. Nothing undone.'; return false;
      }
      this.body = r.before; this.revision += 1; this.receipt = null; this.pointed = null; this.proposal = null; this.message = 'Undid only the mock edit.'; return true;
    }
  }
  const api = Object.freeze({ AttentionSession, compileRecipe, recipes, original, shortened });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.InteractionLab = api;
})(globalThis);
