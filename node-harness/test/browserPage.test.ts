import assert from "node:assert/strict";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { PAGE_SCRIPT } from "../src/browser/pageScript.js";

function page() {
  let doc: any;
  class Element {
    nodeType = 1; tagName: string; attributes: Record<string, string>; childNodes: any[] = [];
    parentElement: Element | null = null; isConnected = true; isContentEditable = false; readOnly = false; isDisabled = false;
    value = ""; textContent = ""; innerText = ""; labels: any[] = []; id = ""; clicked = 0; terminal = false;
    rect = { left: 10, top: 10, right: 210, bottom: 50, width: 200, height: 40 };
    constructor(tag: string, attributes: Record<string, string> = {}) { this.tagName = tag; this.attributes = attributes; }
    get type() { return this.attributes.type ?? "text"; }
    get href() { return this.attributes.href; }
    get target() { return this.attributes.target; }
    getAttribute(k: string) { return this.attributes[k] ?? null; }
    hasAttribute(k: string) { return k in this.attributes; }
    matches(selector: string) {
      if (selector === ':disabled') return this.isDisabled;
      if (selector.includes('input[type=password]')) return this.tagName === 'INPUT' && (this.type === 'password' || ['one-time-code', 'cc-number', 'cc-csc'].includes(this.attributes.autocomplete ?? ''));
      return false;
    }
    closest(selector: string): Element | null {
      if (selector === '.xterm,[data-terminal]') return this.terminal ? this : null;
      if (selector === 'a[href]') return this.tagName === 'A' && this.hasAttribute('href') ? this : this.parentElement?.closest(selector) ?? null;
      if (selector.startsWith('article') || selector.startsWith('article,')) return this.tagName === 'ARTICLE' ? this : this.parentElement?.closest(selector) ?? null;
      return null;
    }
    getBoundingClientRect() { return this.rect; }
    getRootNode() { return doc; }
    contains(other: Element) { return this === other || this.childNodes.some(e => e === other); }
    click() { this.clicked++; }
    focus() { doc.activeElement = this; }
    select() {}
    scrollBy() {}
  }
  class Input extends Element { constructor(attributes: Record<string, string>) { super('INPUT', attributes); } }
  class TextArea extends Element {}
  const body = new Element('BODY');
  const button = new Element('BUTTON', { 'aria-label': 'Like fixture' }); button.innerText = 'Like fixture';
  const input = new Input({ 'aria-label': 'Test note' });
  const password = new Input({ type: 'password', 'aria-label': 'Password' }); password.value = 'do-not-expose-this';
  const article = new Element('ARTICLE'); article.innerText = 'Pinned post by Author A';
  button.parentElement = article; article.childNodes = [button]; article.parentElement = body;
  input.parentElement = body; password.parentElement = body; body.childNodes = [article, input, password];
  let covered = false;
  doc = { body, scrollingElement: body, visibilityState: 'visible', activeElement: null, getElementById: () => null, elementFromPoint: () => covered ? body : button };
  const context: any = { document: doc, Element, HTMLElement: Element, HTMLInputElement: Input, HTMLTextAreaElement: TextArea,
    getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }), innerWidth: 800, innerHeight: 600,
    location: { href: 'https://fixture.test/' }, URL, setTimeout, requestAnimationFrame: (callback: () => void) => setTimeout(callback, 1) };
  runInNewContext(PAGE_SCRIPT, context);
  /** Append a control (or an article holding one) to the body; rect.top >= 600 is below the viewport. */
  const add = (tag: string, attributes: Record<string, string>, options: { top?: number; inArticle?: string } = {}) => {
    const element = new Element(tag, attributes); element.innerText = attributes['aria-label'] ?? '';
    const top = options.top ?? 100; element.rect = { left: 10, top, right: 210, bottom: top + 40, width: 200, height: 40 };
    let parent: Element = body;
    if (options.inArticle !== undefined) {
      parent = new Element('ARTICLE'); parent.innerText = options.inArticle; parent.parentElement = body; body.childNodes.push(parent);
    }
    element.parentElement = parent; parent.childNodes.push(element);
    return element;
  };
  const addText = (value: string, top = 100) => {
    const holder = add('P', {}, { top });
    holder.childNodes.push({ nodeType: 3, textContent: value, parentElement: holder });
    return holder;
  };
  return { helper: context.__piBrowser, button, input, password, article, body, doc, add, addText, covered: (value: boolean) => { covered = value; } };
}
const refLines = (text: string) => text.split('\n').filter(line => /^\[[^\]]+\]/.test(line));
function buttonRef(snapshot: any) { return /^\[([^\]]+)\] button/m.exec(snapshot.text)![1]!; }

test("isolated helper omits password values, creates semantic refs and permits an ordinary Like", () => {
  const p = page(), snapshot = p.helper.snapshot('', 'test-');
  assert(!snapshot.text.includes('do-not-expose-this'));
  assert.match(snapshot.text, /credential field; value omitted; input blocked/);
  assert.match(snapshot.text, /Test note/);
  const ref = buttonRef(snapshot);
  assert.equal(p.helper.act(ref, 'click').ok, true); assert.equal(p.button.clicked, 1);
});

test("helper deletion checks run immediately before activation, including localized labels and identifiers", () => {
  for (const label of ['Delete', 'Delete file', 'Move to Trash', 'Empty Trash', 'Datei löschen', 'In den Papierkorb legen']) {
    const p = page(); p.button.attributes['aria-label'] = label;
    const ref = buttonRef(p.helper.snapshot('', 'x-'));
    assert.equal(p.helper.act(ref, 'click').error, 'file_deletion_blocked', label);
    assert.equal(p.helper.act(ref, 'press', 'Enter').error, 'file_deletion_blocked', label);
    assert.equal(p.button.clicked, 0);
  }
  const p = page(); p.button.id = 'delete-file-control';
  assert.equal(p.helper.act(buttonRef(p.helper.snapshot('', 'x-')), 'click').error, 'file_deletion_blocked');
});

test("recycled post contexts, stale refs, changed labels, disabled, covered and detached nodes do not click", () => {
  for (const change of [
    (p: ReturnType<typeof page>) => { p.article.innerText = 'Different post by Author B'; },
    (p: ReturnType<typeof page>) => { p.button.attributes['aria-label'] = 'Delete file'; },
    (p: ReturnType<typeof page>) => { p.button.isDisabled = true; },
    (p: ReturnType<typeof page>) => { p.button.isConnected = false; },
  ]) {
    const p = page(), ref = buttonRef(p.helper.snapshot('', 'old-')); change(p);
    assert.equal(p.helper.act(ref, 'click').error, 'browser_stale'); assert.equal(p.button.clicked, 0);
  }
  const p = page(), ref = buttonRef(p.helper.snapshot('', 'old-')); p.covered(true);
  assert.equal(p.helper.act(ref, 'click').error, 'browser_occluded'); assert.equal(p.button.clicked, 0);
  p.covered(false); p.helper.snapshot('', 'new-');
  assert.equal(p.helper.act(ref, 'click').error, 'browser_stale');
});

test("hidden tabs and security autocomplete fields fail before mutation", () => {
  const p = page(), ref = buttonRef(p.helper.snapshot('', 'x-'));
  p.doc.visibilityState = 'hidden';
  assert.equal(p.helper.act(ref, 'click').error, 'browser_target_changed'); assert.equal(p.button.clicked, 0);
  p.doc.visibilityState = 'visible'; p.input.attributes.autocomplete = 'section-account current-password';
  p.input.value = 'SECOND-PRIVATE-CANARY';
  const snapshot = p.helper.snapshot('', 'new-');
  assert(!snapshot.text.includes('SECOND-PRIVATE-CANARY')); assert.match(snapshot.text, /credential field; value omitted; input blocked/);
});

test("explicit username/password fields are default-blocked and can be enabled without exposing their values", () => {
  for (const attrs of [
    { 'aria-label': 'Username' }, { 'aria-label': 'Benutzername' }, { 'aria-label': 'Username or email' },
    { 'aria-label': 'Current password' }, { 'aria-label': 'Passwort' }, { autocomplete: 'username' },
    { autocomplete: 'section-account new-password' }, { name: 'login-username' }, { type: 'password' },
  ]) {
    const p = page(); Object.assign(p.input.attributes, attrs); p.input.value = 'PRIVATE-INPUT-CANARY';
    p.doc.elementFromPoint = () => p.input;
    const snapshot = p.helper.snapshot('', 'x-'); const ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
    assert.match(snapshot.text, /input blocked/); assert(!snapshot.text.includes('PRIVATE-INPUT-CANARY'));
    assert.equal(p.helper.act(ref, 'fill').error, 'credential_input_blocked');
    assert.equal(p.helper.act(ref, 'fill', undefined, undefined, true).ok, true);
    assert.equal(p.helper.verifyFill(ref, 'PRIVATE-INPUT-CANARY', true), true);
    const enabled = p.helper.snapshot('', 'enabled-', true); assert.match(enabled.text, /input allowed/);
    assert(!enabled.text.includes('PRIVATE-INPUT-CANARY'));
    const newRef = /^\[([^\]]+)\] textbox/m.exec(enabled.text)![1]!;
    assert.equal(p.helper.act(newRef, 'fill', undefined, undefined, false).error, 'credential_input_blocked');
  }
});

test("ordinary fields, OTP/payment fields and Like remain available with a password field focused", () => {
  for (const attrs of [ {}, { 'aria-label': 'Email' }, { 'aria-label': 'Search password documentation' }, { autocomplete: 'one-time-code' }, { autocomplete: 'cc-number' } ]) {
    const p = page(); Object.assign(p.input.attributes, attrs); p.doc.activeElement = p.password;
    const snapshot = p.helper.snapshot('', 'x-'); const ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
    assert.equal(p.helper.act(buttonRef(snapshot), 'click').ok, true);
    p.doc.elementFromPoint = () => p.input;
    assert.equal(p.helper.act(ref, 'fill').ok, true);
  }
  const p = page(); p.button.attributes['aria-label'] = 'Delete file';
  const ref = buttonRef(p.helper.snapshot('', 'x-', true));
  assert.equal(p.helper.act(ref, 'click', undefined, undefined, true).error, 'file_deletion_blocked');
});

test("browser links cannot escape through click OR keyboard activation", () => {
  for (const attrs of [{ href: 'javascript:alert(1)' }, { href: 'file:///tmp/x' }, { href: 'https://fixture.test/next', target: '_blank' }, { href: 'https://fixture.test/x', download: '' }]) {
    const p = page(); p.button.tagName = 'A'; Object.assign(p.button.attributes, attrs);
    const snapshot = p.helper.snapshot('', 'x-'); const ref = /^\[([^\]]+)\] link/m.exec(snapshot.text)![1]!;
    assert.equal(p.helper.act(ref, 'click').error, 'browser_unsupported_link');
    assert.equal(p.helper.act(ref, 'press', 'Enter').error, 'browser_unsupported_link');
    assert.equal(p.button.clicked, 0);
  }
});

test("terminal surfaces permit ordinary typing, not clearly destructive commands", () => {
  const p = page(); p.input.terminal = true; p.doc.elementFromPoint = () => p.input;
  const snapshot = p.helper.snapshot('', 'x-'), ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
  assert.equal(p.helper.act(ref, 'fill', undefined, undefined, false, 'git status').ok, true);
  for (const command of ['rm example.txt', 'sudo rm -rf tmp', 'find . -delete', 'os.remove("example.txt")']) {
    assert.equal(p.helper.act(ref, 'fill', undefined, undefined, true, command).error, 'file_deletion_blocked');
  }
});

test("multiline fill rejects single-line fields before focus and permits multiline receivers", () => {
  const p = page(); p.doc.elementFromPoint = () => p.input;
  const snapshot = p.helper.snapshot('', 'x-'), ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
  assert.equal(p.helper.act(ref, 'fill', undefined, undefined, false, 'first\nsecond').error, 'browser_unsupported_action');
  assert.equal(p.doc.activeElement, null);
  p.input.isContentEditable = true;
  const fresh = p.helper.snapshot('', 'new-'), newRef = /^\[([^\]]+)\] textbox/m.exec(fresh.text)![1]!;
  assert.equal(p.helper.inspect(newRef, 'fill', undefined, false, 'first\nsecond').ok, true);
});

test("ordinary text editing stays allowed but Delete outside an editable field is refused", () => {
  const p = page(), snapshot = p.helper.snapshot('', 'x-');
  const input = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
  p.doc.elementFromPoint = () => p.input;
  assert.equal(p.helper.act(input, 'fill').ok, true); assert.equal(p.doc.activeElement, p.input);
  assert.equal(p.helper.inspect(input, 'press', 'Backspace').ok, true);
  assert.equal(p.helper.inspect(buttonRef(snapshot), 'press', 'Delete').error, 'file_deletion_blocked');
});

test("compact snapshot: viewport first, ≤100 controls, 60-char names, same rules as the full snapshot", () => {
  const p = page();
  const below = p.add('A', { href: 'https://fixture.test/below', 'aria-label': 'Below the fold' }, { top: 900 });
  p.add('BUTTON', { 'aria-label': 'Send '.repeat(30) });
  p.addText('Saved just now');
  const compact = p.helper.snapshotCompact('c-');
  const lines = refLines(compact.text);
  assert.match(lines[0]!, /^\[c-page\] page/);
  // In-view controls precede the below-the-fold link even though it comes first in the DOM.
  assert.ok(lines.findIndex(l => /Like fixture/.test(l)) < lines.findIndex(l => /Below the fold/.test(l)));
  assert.match(compact.text, /link "Below the fold" \(below view\)/);
  const long = lines.find(l => /Send/.test(l))!;
  assert.equal(JSON.parse(/"(?:[^"\\]|\\.)*"/.exec(long)![0]).length, 60);
  assert.match(compact.text, /Visible text: .*Saved just now/);
  // Credential values stay out, exactly as in the full snapshot.
  assert(!compact.text.includes('do-not-expose-this'));
  assert.match(compact.text, /textbox "Password" \[credential field; value omitted; input blocked in pi-os Settings\]/);
  // Refs are real and pass the same act-time checks.
  const like = /^\[([^\]]+)\] button "Like fixture"/m.exec(compact.text)![1]!;
  assert.equal(p.helper.act(like, 'click').ok, true); assert.equal(p.button.clicked, 1);
  assert.equal(below.clicked, 0);
  const many = page();
  for (let i = 0; i < 150; i++) many.add('BUTTON', { 'aria-label': `Item ${i}` });
  const capped = many.helper.snapshotCompact('m-');
  assert.equal(capped.truncated, true);
  assert.ok(refLines(capped.text).length <= 101, String(refLines(capped.text).length)); // + the page ref
});

test("compact snapshot collapses identical-looking controls into one line without a ref", () => {
  const p = page();
  for (const author of ['Author B', 'Author C']) p.add('BUTTON', { 'aria-label': 'Like fixture' }, { inArticle: `Post by ${author}` });
  const compact = p.helper.snapshotCompact('d-');
  assert.match(compact.text, /^- button "Like fixture" ×3 .*no ref: use browser_snapshot with a filter/m);
  // Only the page and the two unique fields get refs; none of them can reach a Like button.
  assert.deepEqual(refLines(compact.text).map(l => /^\[([^\]]+)\] (\w+)/.exec(l)!.slice(1).join(' ')), ['d-page page', 'd-1 textbox', 'd-2 textbox']);
  // The full snapshot still lists each one with its surrounding post for a precise choice.
  assert.equal((p.helper.snapshot('author c', 'f-').text.match(/button "Like fixture"/g) ?? []).length, 1);
});

test("compact snapshot also collapses same-named controls whose states differ, so no lone one gets a ref", () => {
  const p = page();
  // One unliked post among liked ones: a ref on the odd one out would carry no post context.
  for (const [author, pressed] of [["Alice", "false"], ["Bob", "true"], ["Carol", "true"]]) {
    p.add('BUTTON', { 'aria-label': 'Like', 'aria-pressed': pressed! }, { inArticle: `Post by ${author}` });
  }
  const compact = p.helper.snapshotCompact('s-');
  assert.match(compact.text, /^- button "Like" ×3 \(pressed=false ×1, pressed=true ×2\) \(same role and name; no ref: use browser_snapshot with a filter/m);
  assert(!refLines(compact.text).some(line => /"Like"/.test(line)));
  // The filtered full snapshot still singles out the intended post.
  const full = p.helper.snapshot('alice', 'f-');
  assert.match(full.text, /button "Like" pressed=false/);
  assert.doesNotMatch(full.text, /pressed=true/);
});

test("compact snapshot reaches in-view controls behind hundreds of controls above the view", () => {
  const p = page();
  p.button.rect = { left: 10, top: -5000, right: 210, bottom: -4960, width: 200, height: 40 };
  for (let i = 0; i < 450; i++) p.add('BUTTON', { 'aria-label': `Earlier ${i}` }, { top: -3000 - i });
  const target = p.add('BUTTON', { 'aria-label': 'Reply in view' }, { top: 100 });
  p.doc.elementFromPoint = () => target;
  const compact = p.helper.snapshotCompact('v-');
  const lines = refLines(compact.text);
  assert.equal(compact.truncated, true);
  const reply = lines.findIndex(line => /"Reply in view"/.test(line));
  assert.ok(reply > 0 && reply < lines.findIndex(line => /above view/.test(line)), String(reply));
  assert.equal(p.helper.act(/^\[([^\]]+)\] button "Reply in view"/m.exec(compact.text)![1]!, 'click').ok, true);
  assert.equal(target.clicked, 1);
});

test("compact snapshot keeps deletion and link guards on its refs", () => {
  const p = page(); p.button.attributes['aria-label'] = 'Move to Trash';
  const ref = /^\[([^\]]+)\] button/m.exec(p.helper.snapshotCompact('t-').text)![1]!;
  assert.equal(p.helper.act(ref, 'click').error, 'file_deletion_blocked'); assert.equal(p.button.clicked, 0);
  const q = page(); q.button.tagName = 'A'; Object.assign(q.button.attributes, { href: 'https://fixture.test/x', target: '_blank' });
  const link = /^\[([^\]]+)\] link/m.exec(q.helper.snapshotCompact('l-').text)![1]!;
  assert.equal(q.helper.act(link, 'click').error, 'browser_unsupported_link');
});

test("settle resolves after frames and the floor, and never later than its 200 ms cap", async () => {
  const p = page();
  let started = Date.now();
  assert.equal(await p.helper.settle(20, 150), true);
  assert.ok(Date.now() - started >= 15);
  started = Date.now();
  assert.equal(await p.helper.settle(10_000, 10_000), true);
  assert.ok(Date.now() - started < 1_000);
});
