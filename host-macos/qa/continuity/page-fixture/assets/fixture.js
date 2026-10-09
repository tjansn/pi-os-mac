// pi-os continuity page fixture (DESIGN5 §12). Counts only: field values never leave this page. No cookies, no
// storage, no console output; the only request is a same-origin POST of counts to /echo (see server.mjs).
"use strict";
(() => {
  const DUMMY_CREDENTIAL = "dummy-credential-QA-only";
  const MAX_DELAY_MS = 10000;
  const body = document.body;
  const page = body.dataset.page;
  const params = new URLSearchParams(location.search);
  /** A decimal `ms` query value bounded to [0, 10000]; anything else is `fallback`. */
  const delay = (fallback) => {
    const raw = params.get("ms");
    return raw !== null && /^\d{1,6}$/.test(raw) ? Math.min(Number(raw), MAX_DELAY_MS) : fallback;
  };

  const fields = Array.from(document.querySelectorAll("[data-field]"), (el) => ({
    el,
    name: el.dataset.field,
    credential: el.dataset.kind === "credential",
    inputs: 0,
    returnKeys: 0,
  }));
  const counts = { submits: 0, accepted: 0, rejected: 0 };
  const consent = document.querySelector("dialog[data-consent]");

  const matches = (text, pattern) => (text.match(pattern) || []).length;
  const textOf = (field) => {
    if (!field.el.isContentEditable) return field.el.value;
    // An empty contenteditable can report a lone trailing newline.
    return field.el.innerText.replace(/\n$/, "");
  };
  function measure(field) {
    const focused = document.activeElement === field.el;
    if (field.credential) {
      const value = field.el.value;
      return { filled: value.length > 0, dummyMatches: value === DUMMY_CREDENTIAL, focused, returnKeys: field.returnKeys };
    }
    const value = textOf(field);
    return {
      length: value.length,
      scalars: Array.from(value).length,
      lineBreaks: matches(value, /\r\n|[\n\r\u2028\u2029]/g),
      replacements: matches(value, /\uFFFD/g),
      inputs: field.inputs,
      returnKeys: field.returnKeys,
      focused,
    };
  }
  function snapshot() {
    const out = { page, submits: counts.submits, fields: {} };
    for (const field of fields) out.fields[field.name] = measure(field);
    if (consent) out.consent = { accepted: counts.accepted, rejected: counts.rejected, open: consent.open };
    return out;
  }

  let posting = false;
  function post() {
    if (posting) return;
    posting = true;
    setTimeout(() => {
      posting = false;
      fetch("/echo", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(snapshot()),
        credentials: "omit",
        keepalive: true,
      }).catch(() => {});
    }, 50);
  }
  function render() {
    const snap = snapshot();
    for (const field of fields) {
      const out = document.querySelector(`[data-echo="${field.name}"]`);
      if (!out) continue;
      const m = snap.fields[field.name];
      out.textContent = field.credential
        ? `${m.filled ? "filled" : "empty"}${m.dummyMatches ? " (dummy)" : ""} · Return ${m.returnKeys}${m.focused ? " · focused" : ""}`
        : `${m.length} received · Return ${m.returnKeys}${m.focused ? " · focused" : ""}`;
    }
    const pageOut = document.querySelector("[data-echo-page]");
    if (pageOut) {
      pageOut.textContent = `Submitted ${counts.submits}×` +
        (consent ? ` · consent accepted ${counts.accepted}× · rejected ${counts.rejected}×` : "");
    }
    post();
  }

  for (const field of fields) {
    field.el.addEventListener("input", () => {
      field.inputs += 1;
      render();
    });
    field.el.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.isComposing || !event.isTrusted) return;
      field.returnKeys += 1;
      // Like a search engine's one-line textarea: Return submits the form instead of adding a line.
      if (field.el.dataset.enterSubmits === "true" && !event.shiftKey) {
        event.preventDefault();
        field.el.form?.requestSubmit();
      }
      render();
    });
  }
  for (const form of document.forms) {
    form.addEventListener("submit", (event) => {
      // Never navigates or sends anything (the CSP also sets form-action 'none').
      event.preventDefault();
      counts.submits += 1;
      render();
    });
  }
  document.addEventListener("focusin", render);
  document.addEventListener("focusout", () => setTimeout(render, 0));

  if (consent) {
    // Like a consent wall: Escape does not dismiss it. The buttons only count and close; no cookie is set.
    consent.addEventListener("cancel", (event) => event.preventDefault());
    for (const button of consent.querySelectorAll("button[data-choice]")) {
      button.addEventListener("click", () => {
        if (button.dataset.choice === "accept") counts.accepted += 1;
        else counts.rejected += 1;
        consent.close();
        fields[0]?.el.focus();
        render();
      });
    }
    consent.showModal();
  }
  if (body.hasAttribute("data-focus-on-load") && document.activeElement === body) fields[0]?.el.focus();
  if (body.hasAttribute("data-delayed-focus")) setTimeout(() => fields[0]?.el.focus(), delay(800));
  if (body.hasAttribute("data-moving-focus")) setTimeout(() => fields[1]?.el.focus(), delay(1500));
  if (body.hasAttribute("data-slow-load")) {
    // Inserted before the load event, so the document stays loading (AXLoaded false) until it arrives.
    const script = document.createElement("script");
    script.src = `/slow.js?ms=${delay(1500)}`;
    script.async = true;
    document.head.append(script);
  }
  render();
})();
