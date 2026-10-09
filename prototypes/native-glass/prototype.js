/* All interactions are local simulations. No fetch, host route, model or storage. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const body = document.body;
  const params = new URLSearchParams(location.search);
  const directions = {
    clear: { number: '01', name: 'Clear capsule', description: 'One continuous piece of glass. Just enough interface.' },
    shelf: { number: '02', name: 'Native shelf', description: 'A little more structure. The answer grows out of the bar.' },
    whisper: { number: '03', name: 'Whisper', description: 'The smallest footprint. Everything else stays tucked away.' },
  };
  const themes = ['clear', 'frost', 'graphite', 'warm', 'contrast'];
  const states = ['ready', 'working', 'answer', 'error', 'closed', 'background'];
  const backdrops = ['dune', 'night', 'window'];
  let direction = directions[params.get('direction')] ? params.get('direction') : 'clear';
  let theme = themes.includes(params.get('theme')) ? params.get('theme') : 'clear';
  let state = states.includes(params.get('state')) ? params.get('state') : 'ready';
  let backdrop = backdrops.includes(params.get('backdrop')) ? params.get('backdrop') : 'dune';
  let large = params.get('large') === '1';
  let solid = params.get('solid') === '1';
  let dock = params.get('dock') === '1';
  let edge = ['20', '32', '48'].includes(params.get('edge')) ? params.get('edge') : '32';
  let focusView = params.get('focus') === '1';
  let demoTimer;
  let finishedInBackground = false;
  let lastPopoverTrigger;
  let copyTimer;

  // Whisper folds appearance into its only target/menu affordance.
  const contextAppearance = document.createElement('button');
  contextAppearance.className = 'context-appearance';
  contextAppearance.id = 'context-appearance';
  contextAppearance.type = 'button';
  contextAppearance.setAttribute('aria-label', 'Appearance options');
  contextAppearance.innerHTML = 'Appearance options <svg aria-hidden="true"><use href="#i-chevron"/></svg>';
  $('context-popover').append(contextAppearance);

  function announce(text) { $('announcement').textContent = text; }
  function updateURL() {
    const next = new URL(location.href);
    next.search = '';
    const values = { direction, theme, state, backdrop, edge };
    if (large) values.large = '1';
    if (solid) values.solid = '1';
    if (dock) values.dock = '1';
    if (focusView) values.focus = '1';
    Object.entries(values).forEach(([key, value]) => next.searchParams.set(key, value));
    // Preferences are shareable URL values only. Prompts are NEVER put in the URL.
    try { history.replaceState(null, '', next); } catch { /* file:// restrictions */ }
  }
  function closePopovers(restoreFocus = false) {
    $('appearance').hidden = true;
    $('context-popover').hidden = true;
    $('appearance-button').setAttribute('aria-expanded', 'false');
    $('context-button').setAttribute('aria-expanded', 'false');
    if (restoreFocus) lastPopoverTrigger?.focus();
  }
  function fitPrompt() {
    const prompt = $('prompt');
    if ($('composer').hidden) return;
    const lineHeight = large ? 27 : 22;
    const baseline = lineHeight + 16;
    prompt.style.height = baseline + 'px';
    const height = Math.min(104, Math.max(baseline, prompt.scrollHeight));
    prompt.style.height = height + 'px';
    $('composer').classList.toggle('multiline', height > baseline + 2);
    $('composer').classList.toggle('has-text', Boolean(prompt.value.trim()));
    $('send').disabled = !prompt.value.trim();
    body.style.setProperty('--actual-bar-height', document.querySelector('.command-shell').offsetHeight + 'px');
  }

  function render() {
    body.dataset.direction = direction;
    body.dataset.theme = theme;
    body.dataset.state = state;
    body.dataset.backdrop = backdrop;
    body.classList.toggle('large-type', large);
    body.classList.toggle('solid-material', solid || theme === 'contrast');
    body.classList.toggle('dock-visible', dock);
    body.classList.toggle('focus-view', focusView);
    body.style.setProperty('--edge-gap', edge + 'px');
    document.title = `pi-os — ${directions[direction].name} / ${theme}`;
    $('lab-theme').value = theme;
    $('lab-backdrop').value = backdrop;
    $('large-type').checked = large;
    $('solid-material').checked = solid || theme === 'contrast';
    $('solid-material').disabled = theme === 'contrast';
    $('show-dock').checked = dock;
    $('edge-gap').value = edge;
    $('exit-focus').hidden = !focusView || params.get('embed') === '1';
    $('context-appearance').hidden = direction !== 'whisper';
    document.querySelectorAll('input[name="theme"]').forEach(input => { input.checked = input.value === theme; });
    document.querySelectorAll('button[data-direction]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.direction === direction)));
    document.querySelectorAll('button[data-preview]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.preview === state)));
    $('direction-number').textContent = directions[direction].number;
    $('direction-name').textContent = directions[direction].name;
    $('direction-description').textContent = directions[direction].description;
    $('response').hidden = state !== 'answer';
    $('error-panel').hidden = state !== 'error';
    $('composer').hidden = !['ready', 'answer'].includes(state);
    $('working-row').hidden = state !== 'working';
    $('closed-row').hidden = !['closed', 'background', 'error'].includes(state);
    $('prompt').placeholder = state === 'answer' ? 'Ask a follow-up…' : 'Ask about this window…';
    $('prompt').setAttribute('aria-label', state === 'answer' ? 'Follow-up on the pinned window' : 'Ask about the pinned window');
    $('closed-message').textContent = state === 'error' ? 'Pinned window unavailable' : state === 'background' ? (finishedInBackground ? 'Your answer is ready' : 'Continuing in the background…') : 'Conversation closed';
    $('restore').textContent = state === 'background' ? (finishedInBackground ? 'Open answer ↗' : 'Show task ↗') : 'Start again ↵';
    $('activity').textContent = direction === 'whisper' ? 'Reading the window…' : 'Reading the pinned window…';
    fitPrompt();
    updateURL();
  }
  function setState(next, userInitiated = false) {
    clearTimeout(demoTimer);
    closePopovers();
    state = next;
    render();
    announce({ ready: 'Ready. Ask about the pinned window.', working: 'Demo task is working.', answer: 'Demo answer ready. Follow-ups stay on Notes.', error: 'Demo error. The pinned window is unavailable.', closed: 'Conversation closed.', background: 'Task continues in the background.' }[state]);
    if (userInitiated) {
      if (next === 'answer' || next === 'ready') $('prompt').focus();
      else if (next === 'working') $('cancel-task').focus();
      else if (next === 'error') $('new-conversation').focus();
      else $('restore').focus();
    }
  }
  function setTheme(next) {
    if (!themes.includes(next)) return;
    document.documentElement.classList.add('theme-swap');
    theme = next;
    render();
    void body.offsetHeight;
    requestAnimationFrame(() => requestAnimationFrame(() => document.documentElement.classList.remove('theme-swap')));
    announce(`${theme} appearance selected. Pinned target unchanged.`);
  }
  function togglePopover(name, trigger) {
    const wasOpen = !$(name).hidden;
    closePopovers();
    if (wasOpen) return;
    $(name).hidden = false;
    lastPopoverTrigger = trigger;
    trigger.setAttribute('aria-expanded', 'true');
    if (name === 'appearance') $('close-appearance').focus();
    else if (direction === 'whisper') $('context-appearance').focus();
  }

  document.querySelectorAll('[data-direction]').forEach(button => {
    if (button.tagName !== 'BUTTON') return;
    button.addEventListener('click', () => { direction = button.dataset.direction; closePopovers(); render(); });
  });
  document.querySelectorAll('[data-preview]').forEach(button => button.addEventListener('click', () => {
    $('prompt').value = '';
    $('question').textContent = 'Make this a simple two-day itinerary.';
    setState(button.dataset.preview);
  }));
  $('lab-theme').addEventListener('change', event => setTheme(event.target.value));
  document.querySelectorAll('input[name="theme"]').forEach(input => input.addEventListener('change', () => setTheme(input.value)));
  $('lab-backdrop').addEventListener('change', event => { backdrop = event.target.value; render(); });
  $('large-type').addEventListener('change', event => { large = event.target.checked; render(); });
  $('solid-material').addEventListener('change', event => { solid = event.target.checked; render(); });
  $('show-dock').addEventListener('change', event => { dock = event.target.checked; render(); });
  $('edge-gap').addEventListener('change', event => { edge = event.target.value; render(); });
  $('focus-view').addEventListener('click', () => { focusView = true; render(); });
  $('exit-focus').addEventListener('click', () => { focusView = false; render(); $('focus-view').focus(); });
  $('appearance-button').addEventListener('click', event => togglePopover('appearance', event.currentTarget));
  $('context-button').addEventListener('click', event => togglePopover('context-popover', event.currentTarget));
  $('context-appearance').addEventListener('click', () => { closePopovers(); togglePopover('appearance', $('context-button')); });
  $('close-appearance').addEventListener('click', () => closePopovers(true));
  $('prompt').maxLength = 2000;
  $('prompt').addEventListener('input', fitPrompt);
  $('prompt').addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && event.keyCode !== 229) {
      event.preventDefault();
      $('composer').requestSubmit();
    }
  });
  $('composer').addEventListener('submit', event => {
    event.preventDefault();
    const text = $('prompt').value.trim();
    if (!text || !['ready', 'answer'].includes(state)) return;
    $('question').textContent = text;
    $('prompt').value = '';
    finishedInBackground = false;
    setState('working', true);
    demoTimer = setTimeout(() => {
      if (state === 'background') { finishedInBackground = true; render(); announce('Demo answer ready in background.'); }
      else if (state === 'working') setState('answer', true);
    }, 1800);
  });
  $('cancel-task').addEventListener('click', () => { setState('closed', true); $('closed-message').textContent = 'Task cancelled'; });
  $('hide-task').addEventListener('click', () => { closePopovers(); state = 'background'; render(); $('restore').focus(); });
  $('restore').addEventListener('click', () => {
    if (state === 'background' && !finishedInBackground) { state = 'working'; render(); $('cancel-task').focus(); }
    else setState(state === 'background' ? 'answer' : 'ready', true);
  });
  $('close-conversation').addEventListener('click', () => setState('closed', true));
  $('close-error').addEventListener('click', () => setState('closed', true));
  $('new-conversation').addEventListener('click', () => setState('ready', true));
  // Prototype only: demonstrate copy feedback without touching the real clipboard.
  $('copy-answer').addEventListener('click', () => {
    clearTimeout(copyTimer);
    $('copy-answer').setAttribute('aria-label', 'Copy feedback preview. Clipboard unchanged.');
    $('copy-answer').innerHTML = '<svg aria-hidden="true"><use href="#i-check"/></svg>';
    $('answer-status').textContent = 'Copy feedback preview · clipboard unchanged';
    announce('Copy feedback preview. Your clipboard was not changed.');
    copyTimer = setTimeout(() => {
      $('copy-answer').setAttribute('aria-label', 'Copy demo answer');
      $('copy-answer').innerHTML = '<svg aria-hidden="true"><use href="#i-copy"/></svg>';
      $('answer-status').innerHTML = '<svg aria-hidden="true"><use href="#i-check"/></svg>Ready for a follow-up';
    }, 1800);
  });
  document.addEventListener('pointerdown', event => {
    if (!event.target.closest('#appearance, #context-popover, #appearance-button, #context-button')) closePopovers();
    // Outside clicks NEVER dismiss the answer/conversation.
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      event.preventDefault();
      if (!$('appearance').hidden || !$('context-popover').hidden) closePopovers(true);
      else setState('closed', true);
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      if (['ready', 'answer'].includes(state)) $('prompt').focus();
    }
  });
  window.addEventListener('resize', fitPrompt);
  // Fix bar metrics after all style-dependent measurements have settled.
  render();
  requestAnimationFrame(fitPrompt);
  window.prototypeReady = true;
})();
