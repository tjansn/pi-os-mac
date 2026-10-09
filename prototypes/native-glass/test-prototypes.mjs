// CPU/browser-only smoke tests for this disposable prototype, not pi-os acceptance.
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve } from 'node:path';
import { writeFileSync } from 'node:fs';

const root = dirname(fileURLToPath(import.meta.url));
const session = 'pi-os-native-prototypes'; // an isolated headless browser, never auto-connect
const checks = [];
let passed = false;
const browser = (...args) => {
  const result = JSON.parse(execFileSync('agent-browser', ['--session', session, '--json', ...args], { encoding: 'utf8', timeout: 20000 }));
  if (!result.success) throw new Error(result.error || JSON.stringify(result));
  return result.data;
};
const evaluate = expression => browser('eval', expression).result;
const snapshot = () => browser('snapshot', '-i');
const click = selector => { snapshot(); browser('click', selector); };
const record = (name, data = {}) => { checks.push({ name, ...data }); console.log('PASS:', name); };
function open(params = {}) {
  const url = pathToFileURL(resolve(root, 'index.html'));
  url.search = new URLSearchParams(params).toString();
  browser('open', url.href);
  browser('wait', '--fn', 'window.prototypeReady === true');
}

try {
  browser('set', 'viewport', '1440', '960');
  for (const direction of ['clear', 'shelf', 'whisper']) {
    for (const theme of ['clear', 'frost', 'graphite', 'warm', 'contrast']) {
      for (const state of ['ready', 'working', 'answer', 'error']) {
        open({ direction, theme, state });
        const data = evaluate(`(() => {
          const bar = document.querySelector('.command-shell').getBoundingClientRect();
          const anchor = document.querySelector('.assistant-anchor').getBoundingClientRect();
          return { bottom: innerHeight - bar.bottom, center: bar.x + bar.width / 2, viewport: innerWidth,
            top: anchor.top, height: bar.height, overflow: document.documentElement.scrollWidth > innerWidth,
            state: document.body.dataset.state, theme: document.body.dataset.theme,
            pinned: document.getElementById('context-button').getAttribute('aria-label'),
            answer: !document.getElementById('response').hidden,
            error: !document.getElementById('error-panel').hidden,
            form: !document.getElementById('composer').hidden,
            disabled: document.getElementById('send').disabled,
            opaque: getComputedStyle(document.querySelector('.command-shell')).backdropFilter === 'none'
          };
        })()`);
        assert.equal(data.state, state); assert.equal(data.theme, theme);
        assert(Math.abs(data.bottom - 32) < .5);
        assert(Math.abs(data.center - data.viewport / 2) < .5);
        assert(data.top > 130 && data.height <= 60 && !data.overflow);
        assert.equal(data.pinned, 'Pinned window: Notes, Weekend plans');
        assert.equal(data.answer, state === 'answer'); assert.equal(data.error, state === 'error');
        assert.equal(data.form, ['ready', 'answer'].includes(state));
        assert.equal(data.disabled, true);
        if (theme === 'contrast') assert.equal(data.opaque, true);
        record(`${direction}/${theme}/${state}: bottom-center, one-line bar and correct state`);
      }
    }
  }

  for (const direction of ['clear', 'shelf', 'whisper']) {
    browser('set', 'viewport', '390', '844');
    open({ direction, theme: 'contrast', state: 'answer', dock: '1', large: '1' });
    const data = evaluate(`(() => {
      const b = document.querySelector('.command-shell').getBoundingClientRect();
      const a = document.querySelector('.assistant-anchor').getBoundingClientRect();
      return { bottom: innerHeight - b.bottom, left: b.left, right: b.right, top: a.top,
        overflow: document.documentElement.scrollWidth > innerWidth, width: innerWidth };
    })()`);
    assert(Math.abs(data.bottom - 114) < .5 && data.left >= 13 && data.right <= data.width - 13);
    assert(data.top >= 180 && !data.overflow);
    record(`${direction}: narrow viewport, larger type, Dock clearance, opaque material`);
  }
  browser('set', 'viewport', '1440', '960');
  open({ direction: 'clear' });
  snapshot(); browser('fill', '#prompt', 'Make this shorter.');
  snapshot(); browser('press', 'Shift+Enter');
  snapshot(); browser('type', '#prompt', 'Keep the two-day structure.');
  const typed = evaluate('document.getElementById("prompt").value');
  assert.equal(typed, 'Make this shorter.\nKeep the two-day structure.');
  assert(evaluate('document.getElementById("prompt").offsetHeight') > 38);
  record('Shift-Return inserts a newline; composer grows only when needed');
  snapshot(); browser('press', 'Enter');
  assert.equal(evaluate('document.body.dataset.state'), 'working');
  browser('wait', '--fn', 'document.body.dataset.state === "answer"');
  assert.equal(evaluate('document.getElementById("question").textContent'), typed);
  record('Return simulates work and answer without losing Unicode/newline text');
  click('.select-label > span');
  assert.equal(evaluate('document.body.dataset.state'), 'answer');
  record('Outside click preserves answer/conversation');
  click('#appearance-button');
  snapshot(); browser('check', 'input[name="theme"][value="warm"]');
  assert.equal(evaluate('document.body.dataset.theme'), 'warm');
  assert.equal(evaluate('document.getElementById("question").textContent'), typed);
  assert.equal(evaluate('document.getElementById("context-button").getAttribute("aria-label")'), 'Pinned window: Notes, Weekend plans');
  record('Preset changes appearance, not answer or pinned context');
  snapshot(); browser('check', '#solid-material');
  assert.equal(evaluate('getComputedStyle(document.querySelector(".command-shell")).backdropFilter'), 'none');
  record('Reduce transparency is a true opaque fallback');
  snapshot(); browser('press', 'Escape');
  assert.equal(evaluate('document.body.dataset.state'), 'answer');
  snapshot(); browser('press', 'Escape');
  assert.equal(evaluate('document.body.dataset.state'), 'closed');
  record('Escape first closes appearance, then explicitly closes conversation');
  click('#restore');
  snapshot(); browser('fill', '#prompt', 'Dummy follow-up');
  snapshot(); browser('press', 'Enter');
  click('#cancel-task');
  assert.equal(evaluate('document.body.dataset.state'), 'closed');
  record('Cancel ends simulated work instead of replaying it');

  open({ direction: 'whisper' });
  click('#context-button'); click('#context-appearance');
  assert.equal(evaluate('document.getElementById("appearance").hidden'), false);
  record('Whisper retains discoverable appearance controls behind pi');
  click('#close-appearance');
  snapshot(); browser('fill', '#prompt', 'Background example');
  // Background action belongs to the fuller Clear direction.
  click('button[data-direction="clear"]');
  snapshot(); browser('press', 'Enter');
  // Direction clicks move focus; submit through the explicit Send action instead.
  if (evaluate('document.body.dataset.state') === 'ready') click('#send');
  click('#hide-task');
  click('#restore');
  browser('wait', '--fn', 'document.body.dataset.state === "answer"');
  record('Hide/show work preserves the pending simulated completion');

  passed = true;
  console.log(`\n${checks.length} prototype checks passed. No production or provider calls.`);
} finally {
  writeFileSync(resolve(root, 'review-checks.json'), JSON.stringify({
    date: new Date().toISOString(), scope: 'Disposable HTML prototype smoke tests only',
    browserSession: session, passed, checks,
    notVerified: ['Native Apple glass rendering', 'VoiceOver', 'Safari', 'Physical keyboard', '10%-speed motion replay', 'Contrast over every possible wallpaper', 'Every OS accessibility preference']
  }, null, 2) + '\n');
}
