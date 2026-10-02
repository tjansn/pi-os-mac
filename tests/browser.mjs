// Opt-in CPU/browser checks. An isolated headless session, never --auto-connect.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import assert from "node:assert/strict";
const base = process.env.SITE_URL || "http://127.0.0.1:18743/";
const session = "pi-os-website-tests";
const qa = new URL("../qa/", import.meta.url);
mkdirSync(qa, { recursive: true });
const checks = [];
function ab(...args) {
  return execFileSync("agent-browser", ["--session", session, ...args], {
    encoding: "utf8",
    timeout: 15000,
    maxBuffer: 1024 * 1024,
  }).trim();
}
function value(expression) {
  return JSON.parse(ab("eval", expression));
}
function check(label, expression) {
  assert.ok(value(expression), label);
  checks.push(label);
}
function click(selector) {
  ab("scrollintoview", selector);
  ab("click", selector);
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitState(state) {
  const deadline = Date.now() + 7000;
  while (Date.now() < deadline) {
    if (value("document.querySelector('#desktop').dataset.state") === state)
      return;
    await sleep(100);
  }
  throw new Error(`Demo did not reach ${state}`);
}
async function ask(prompt) {
  ab("fill", "#prompt", prompt);
  ab("press", "Enter");
  await waitState("answer");
}
function screenshot(name) {
  ab("screenshot", new URL(name, qa).pathname, "--full");
}

try {
  ab("open", base);
  ab("set", "viewport", "1440", "1100");
  ab("set", "media", "light");
  ab("snapshot", "-i");
  check(
    "booted into ready with explicit mock status",
    "window.demoReady && document.querySelector('#desktop').dataset.state === 'ready' && document.body.textContent.includes('No LLM')",
  );
  check("empty prompt is disabled", "document.querySelector('#send').disabled");
  screenshot("desktop-ready.png");
  click("#suggestion-buttons button:first-child");
  await waitState("answer");
  check(
    "one-click suggestion completes the scripted summary",
    "document.querySelector('#answer-title').textContent === 'The essentials, at a glance.'",
  );
  check(
    "keyboard focus returns to follow-up receiver",
    "document.activeElement.id === 'prompt'",
  );
  ab("snapshot", "-i");
  ab("fill", "#prompt", "Make it shorter");
  ab("press", "Shift+Enter");
  ab("type", "#prompt", "please");
  check(
    "Shift Return inserts an actual newline",
    "document.querySelector('#prompt').value === 'Make it shorter\\nplease'",
  );
  ab("press", "Enter");
  await waitState("answer");
  check(
    "multiline follow-up delivered intact; retained same mock context",
    "document.querySelector('#question').textContent === 'Make it shorter\\nplease' && document.querySelector('#turn-count').textContent === 'Turn 2' && document.querySelector('#response-source').textContent === 'Notes · Weekend plans'",
  );
  click("#apply-change");
  check(
    "explicit apply changes only the demo document",
    "document.querySelector('#document-text').value.split('\\n').length === 3 && document.querySelector('#answer-status').textContent.includes('Nothing sent')",
  );
  ab("eval", "document.querySelector('#how-it-works').click()");
  check(
    "outside click preserves reader",
    "document.querySelector('#desktop').dataset.state === 'answer'",
  );
  for (const theme of [
    "clear",
    "frost",
    "graphite",
    "warm",
    "contrast",
    "system",
  ]) {
    ab("select", "#theme", theme);
    check(
      `${theme} preserves thread and target`,
      `document.querySelector('#turn-count').textContent === 'Turn 2' && document.querySelector('#response-source').textContent === 'Notes · Weekend plans' && document.querySelector('#theme').value === '${theme}'`,
    );
  }
  ab("select", "#theme", "graphite");
  screenshot("graphite-answer.png");
  click("#context-button");
  ab("snapshot", "-i");
  check(
    "native-inspired context/appearance controls are accessible",
    "!document.querySelector('#appearance').hidden && document.querySelector('#context-button').getAttribute('aria-expanded') === 'true'",
  );
  ab("check", "#large-text");
  ab("check", "#solid-material");
  ab("select", "#edge-gap", "48");
  check(
    "larger/opaque/spacing options are visual only",
    "document.querySelector('#desktop').classList.contains('large') && document.querySelector('#desktop').classList.contains('solid') && getComputedStyle(document.querySelector('#desktop')).getPropertyValue('--edge').trim() === '48px' && document.querySelector('#turn-count').textContent === 'Turn 2'",
  );
  screenshot("appearance.png");
  ab("press", "Escape");
  check(
    "Escape closes popover, not conversation; restores its trigger",
    "document.querySelector('#appearance').hidden && document.querySelector('#desktop').dataset.state === 'answer' && document.activeElement.id === 'context-button'",
  );
  // Stub clipboard within this disposable browser only. Do not touch the OS clipboard.
  ab(
    "eval",
    "Object.defineProperty(navigator, 'clipboard', {configurable:true,value:{writeText:async text=>{window.copyFixture=text;}}}); true",
  );
  click("#copy-answer");
  check(
    "explicit copy gets the answer, not document/prompt capabilities",
    "window.copyFixture.startsWith('Less text.') && document.querySelector('#answer-status').textContent === 'Mock answer copied'",
  );
  ab(
    "eval",
    "navigator.clipboard.writeText=async()=>{throw new Error('fixture refusal')}; true",
  );
  click("#copy-answer");
  check(
    "clipboard refusal leaves readable answer and manual-copy hint",
    "document.querySelector('#answer-status').textContent.includes('copy manually') && !document.querySelector('#response').hidden",
  );
  click("#close-conversation");
  check(
    "close clears thread and transient answer",
    "document.querySelector('#desktop').dataset.state === 'closed' && document.querySelector('#answer-body').textContent === ''",
  );
  click("#restore");
  ab("fill", "#prompt", "Make a checklist");
  ab("press", "Enter");
  click("#cancel-task");
  await sleep(1350);
  check(
    "cancel prevents late completion or automatic replay",
    "document.querySelector('#desktop').dataset.state === 'closed' && document.querySelector('#closed-message').textContent.includes('cancelled')",
  );
  click("#restore");
  ab("fill", "#prompt", "Summarize this");
  ab("press", "Enter");
  click("#hide-task");
  await sleep(1350);
  check(
    "background work completes without forcing open",
    "document.querySelector('#desktop').dataset.state === 'background' && document.querySelector('#closed-message').textContent.includes('ready')",
  );
  click("#restore");
  check(
    "explicit reopen keeps same target",
    "document.querySelector('#desktop').dataset.state === 'answer' && document.querySelector('#response-source').textContent.startsWith('Notes')",
  );
  click('[data-example="mail"]');
  check(
    "changing example explicitly resets thread and target",
    "document.querySelector('#desktop').dataset.state === 'ready' && document.querySelector('#turn-count').textContent === 'Turn 0' && document.querySelector('#pinned-app').textContent === 'Mail'",
  );
  await ask("Make this friendlier");
  click("#apply-change");
  check(
    "mail template prepares draft but sends nothing",
    "document.querySelector('#document-text').value.includes('lovely speaking') && document.querySelector('#answer-status').textContent.includes('Nothing sent')",
  );
  await ask("send this email");
  check(
    "no pretend account action",
    "document.querySelector('#answer-body').textContent.includes('nothing is sent')",
  );
  click('[data-example="code"]');
  await ask("Add TypeScript types");
  check(
    "code sample is text-only",
    "document.querySelector('#answer-body pre').textContent.includes('name: string') && document.querySelector('#answer-body').textContent.includes('never executed')",
  );
  await ask("something this demo cannot understand");
  check(
    "unknown prompts get an honest fallback",
    "document.querySelector('#answer-title').textContent.includes('scripted demo')",
  );
  await ask("delete all files");
  check(
    "deletion fixture remains a refusal, no destructive mutation",
    "document.querySelector('#answer-title').textContent === 'This stays a safe mock.' && document.querySelector('#apply-change').hidden",
  );
  click('[data-example="notes"]');
  ab(
    "fill",
    "#document-text",
    '<img src=x onerror="window.injected=1">\nSecond edited line.',
  );
  await ask("Summarize this");
  check(
    "editable source is summarized as text; markup never executes",
    "!window.injected && !document.querySelector('#answer-body img') && document.querySelector('#answer-body').textContent.includes('<img src=x')",
  );
  check(
    "no text in URL or storage",
    "!location.search.includes('img') && !location.search.includes('prompt') && localStorage.length === 0 && sessionStorage.length === 0",
  );
  click("#reset-demo");
  await ask("Summarize this");
  ab("set", "media", "light", "reduced-motion");
  check(
    "reduced motion stops spinner animation",
    "getComputedStyle(document.querySelector('.spinner')).animationName === 'none'",
  );
  ab("set", "media", "dark");
  ab("select", "#theme", "system");
  check(
    "System follows dark appearance",
    "document.querySelector('#desktop').dataset.theme === 'graphite'",
  );
  ab("set", "media", "light");
  check(
    "System follows light appearance",
    "document.querySelector('#desktop').dataset.theme === 'clear'",
  );
  for (const width of [1440, 768, 390, 320]) {
    ab("set", "viewport", String(width), "1000");
    check(
      `no horizontal overflow at ${width}px`,
      "document.documentElement.scrollWidth <= innerWidth",
    );
    check(
      `composer/answer remain inside desktop at ${width}px`,
      "(()=>{const d=document.querySelector('#desktop').getBoundingClientRect(), a=document.querySelector('#assistant-anchor').getBoundingClientRect();return a.left >= d.left && a.right <= d.right && a.top >= d.top && a.bottom <= d.bottom;})()",
    );
    check(
      `answer can scroll at ${width}px`,
      "getComputedStyle(document.querySelector('#response-content')).overflowY === 'auto'",
    );
    if (width === 390) screenshot("mobile-answer.png");
  }
  const requests = ab("network", "requests");
  const urls = [...requests.matchAll(/GET (https?:\/\/\S+)/g)].map(
    (match) => match[1],
  );
  assert.ok(urls.length >= 5);
  assert.ok(
    urls.every((url) => new URL(url).origin === new URL(base).origin),
    requests,
  );
  assert.doesNotMatch(requests, /POST |WebSocket|Fetch|XHR/);
  checks.push(
    "observed requests are same-origin static assets only; no model/API traffic",
  );
  assert.equal(ab("errors"), "");
  checks.push("no uncaught browser errors");
  console.log(`${checks.length} browser checks passed`);
  writeFileSync(
    new URL("browser-checks.json", qa),
    JSON.stringify(
      {
        url: base,
        checks,
        passed: checks.length,
        limits:
          "Chromium mocks only; not native app, Safari, VoiceOver or physical-keyboard acceptance.",
      },
      null,
      2,
    ) + "\n",
  );
} finally {
  ab("close");
}
