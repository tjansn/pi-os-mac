import { examples, mockReply } from "./mock.js";

// A tab-local state machine. No fetch, provider, native bridge, storage or telemetry.
const $ = (id) => document.getElementById(id);
const desktop = $("desktop");
const themes = ["system", "clear", "frost", "graphite", "warm", "contrast"];
const params = new URLSearchParams(location.search);
let example = Object.hasOwn(examples, params.get("example"))
  ? params.get("example")
  : "notes";
let theme = themes.includes(params.get("theme"))
  ? params.get("theme")
  : "system";
let state = "ready",
  turns = 0,
  result,
  timer,
  generation = 0,
  finishedInBackground = false;
let large = false,
  solid = false,
  edge = "32";
let pin = { example, ...examples[example] };
const dark = matchMedia("(prefers-color-scheme: dark)");

function announce(message) {
  $("announcement").textContent = message;
}
function closeAppearance(restoreFocus = false) {
  $("appearance").hidden = true;
  $("context-button").setAttribute("aria-expanded", "false");
  if (restoreFocus) $("context-button").focus({ preventScroll: true });
}
function fitPrompt() {
  if ($("composer").hidden) return;
  const prompt = $("prompt");
  const baseline = large ? 43 : 38;
  prompt.style.height = baseline + "px";
  const height = Math.min(112, Math.max(baseline, prompt.scrollHeight));
  prompt.style.height = height + "px";
  $("composer").classList.toggle("multiline", height > baseline + 2);
  $("send").disabled = !prompt.value.trim();
  desktop.style.setProperty(
    "--actual-bar-height",
    document.querySelector(".command-shell").offsetHeight + "px",
  );
}
function shareVisualSettings() {
  const url = new URL(location.href);
  url.search = new URLSearchParams({ example, theme }).toString();
  // Only enum values. Never prompts, document text or transcript data.
  history.replaceState(null, "", url);
}
function render() {
  desktop.dataset.state = state;
  desktop.dataset.example = example;
  desktop.dataset.theme =
    theme === "system" ? (dark.matches ? "graphite" : "clear") : theme;
  desktop.classList.toggle("large", large);
  desktop.classList.toggle("solid", solid || theme === "contrast");
  desktop.style.setProperty("--edge", edge + "px");
  $("theme").value = $("popover-theme").value = theme;
  $("large-text").checked = large;
  $("solid-material").checked = solid || theme === "contrast";
  $("solid-material").disabled = theme === "contrast";
  $("edge-gap").value = edge;
  $("response").hidden = state !== "answer";
  $("composer").hidden = !["ready", "answer"].includes(state);
  $("working-row").hidden = state !== "working";
  $("closed-row").hidden = !["closed", "background"].includes(state);
  $("prompt").placeholder =
    state === "answer" ? "Ask a follow-up…" : "Ask about this window…";
  $("prompt").setAttribute(
    "aria-label",
    state === "answer"
      ? "Follow-up on the pinned demo window"
      : "Ask about the demo window",
  );
  $("closed-message").textContent =
    state === "background"
      ? finishedInBackground
        ? "Your mock answer is ready"
        : "Mock continues in background…"
      : "Conversation closed";
  $("restore").textContent =
    state === "background"
      ? finishedInBackground
        ? "Open answer ↗"
        : "Show task ↗"
      : "Start again ↵";
  $("activity").textContent = "Preparing a scripted answer…";
  document
    .querySelectorAll("[data-example]")
    .forEach((button) =>
      button.setAttribute(
        "aria-pressed",
        String(button.dataset.example === example),
      ),
    );
  document.querySelectorAll("#suggestion-buttons button").forEach((button) => {
    button.disabled = ["working", "background"].includes(state);
  });
  $("response-source").textContent = pin.app + " · " + pin.title;
  $("source-icon")
    .querySelector("use")
    .setAttribute("href", "#i-" + pin.icon);
  $("pinned-app").textContent = pin.app;
  $("pinned-title").textContent = pin.title;
  $("context-button").title = "Pinned mock: " + pin.app + " · " + pin.title;
  $("turn-count").textContent = "Turn " + turns;
  fitPrompt();
  shareVisualSettings();
}
function setTheme(value) {
  if (!themes.includes(value)) return;
  document.documentElement.classList.add("theme-swap");
  theme = value;
  render();
  void desktop.offsetHeight;
  requestAnimationFrame(() =>
    requestAnimationFrame(() =>
      document.documentElement.classList.remove("theme-swap"),
    ),
  );
  announce(value + " appearance. The pinned demo window is unchanged.");
}
function stopPending() {
  clearTimeout(timer);
  generation++;
  finishedInBackground = false;
}
function startConversation(focus = false) {
  stopPending();
  closeAppearance();
  state = "ready";
  turns = 0;
  result = undefined;
  pin = { example, ...examples[example] };
  $("prompt").value = "";
  render();
  if (focus) $("prompt").focus({ preventScroll: true });
}
function selectExample(value, focus = true) {
  if (!Object.hasOwn(examples, value)) return;
  example = value;
  const sample = examples[example];
  $("window-app").textContent = $("menu-app").textContent = sample.app;
  $("document-title").textContent = sample.heading;
  $("document-kicker").textContent = sample.kicker;
  $("document-text").value = sample.text;
  $("suggestion-buttons").replaceChildren();
  for (const prompt of sample.prompts) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = prompt;
    button.addEventListener("click", () => {
      if (state === "closed") startConversation();
      $("prompt").value = prompt;
      ask();
    });
    $("suggestion-buttons").append(button);
  }
  countDocument();
  startConversation(focus);
  announce(
    "New mock conversation pinned to " +
      sample.app +
      ". Switching examples explicitly starts over.",
  );
}
function countDocument() {
  $("document-count").textContent =
    $("document-text").value.length + " characters";
}
function showResult(next, question) {
  result = next;
  $("question").textContent = question;
  $("answer-title").textContent = result.title;
  $("answer-body").replaceChildren();
  for (const block of result.blocks) {
    const node = document.createElement(
      block.items ? "ul" : block.code ? "pre" : "p",
    );
    if (block.items)
      for (const item of block.items) {
        const li = document.createElement("li");
        li.textContent = item;
        node.append(li);
      }
    else node.textContent = block.code ?? block.text;
    $("answer-body").append(node);
  }
  $("apply-change").hidden = result.patch === null;
  $("apply-change").disabled = false;
  $("apply-change").firstChild.textContent = "Apply to demo window ";
  $("copy-answer").setAttribute("aria-label", "Copy mock answer");
  $("answer-status").textContent = "Scripted answer · Ready for a follow-up";
  $("response-content").scrollTop = 0;
}
function ask() {
  if (!["ready", "answer"].includes(state)) return;
  const question = $("prompt").value.trim();
  if (!question) return;
  closeAppearance();
  const next = mockReply({
    example: pin.example,
    prompt: question,
    text: $("document-text").value,
    turn: turns + 1,
  });
  const task = ++generation;
  $("prompt").value = "";
  finishedInBackground = false;
  state = "working";
  render();
  $("cancel-task").focus({ preventScroll: true });
  announce("Simulating work. No model is running.");
  timer = setTimeout(() => {
    if (task !== generation || !["working", "background"].includes(state))
      return;
    turns++;
    showResult(next, question);
    if (state === "background") {
      finishedInBackground = true;
      render();
      announce("Your scripted answer is ready in the background.");
    } else {
      const ownedFocus = document.activeElement.closest("#working-row");
      state = "answer";
      render();
      announce("Scripted answer ready. Same pinned example.");
      // Preserve keyboard continuity, but don't steal focus from the example/page.
      if (ownedFocus) $("prompt").focus({ preventScroll: true });
    }
  }, 1200);
}
function closeConversation(cancelled = false) {
  stopPending();
  closeAppearance();
  result = undefined;
  turns = 0;
  $("prompt").value = "";
  $("question").textContent = "";
  $("answer-body").replaceChildren();
  state = "closed";
  render();
  if (cancelled) $("closed-message").textContent = "Mock task cancelled";
  announce(
    cancelled
      ? "Mock task cancelled. Nothing was applied."
      : "Conversation closed. No demo history is saved.",
  );
  $("restore").focus({ preventScroll: true });
}

$("composer").addEventListener("submit", (event) => {
  event.preventDefault();
  ask();
});
$("prompt").addEventListener("input", fitPrompt);
$("prompt").addEventListener("keydown", (event) => {
  if (
    event.key === "Enter" &&
    !event.shiftKey &&
    !event.isComposing &&
    event.keyCode !== 229
  ) {
    event.preventDefault();
    $("composer").requestSubmit();
  }
});
$("document-text").addEventListener("input", countDocument);
document
  .querySelectorAll("button[data-example]")
  .forEach((button) =>
    button.addEventListener("click", () =>
      selectExample(button.dataset.example),
    ),
  );
$("reset-demo").addEventListener("click", () => {
  selectExample(example);
  announce("Example text and conversation reset. Appearance preserved.");
});
$("theme").addEventListener("change", (event) => setTheme(event.target.value));
$("popover-theme").addEventListener("change", (event) =>
  setTheme(event.target.value),
);
$("large-text").addEventListener("change", (event) => {
  large = event.target.checked;
  render();
});
$("solid-material").addEventListener("change", (event) => {
  solid = event.target.checked;
  render();
});
$("edge-gap").addEventListener("change", (event) => {
  edge = event.target.value;
  render();
});
dark.addEventListener("change", () => {
  if (theme === "system") setTheme("system");
});
$("context-button").addEventListener("click", () => {
  if (!$("appearance").hidden) return closeAppearance(true);
  $("appearance").hidden = false;
  $("context-button").setAttribute("aria-expanded", "true");
  $("close-appearance").focus({ preventScroll: true });
});
$("close-appearance").addEventListener("click", () => closeAppearance(true));
$("cancel-task").addEventListener("click", () => closeConversation(true));
$("close-conversation").addEventListener("click", () => closeConversation());
$("hide-task").addEventListener("click", () => {
  state = "background";
  closeAppearance();
  render();
  $("restore").focus({ preventScroll: true });
});
$("restore").addEventListener("click", () => {
  if (state !== "background") return startConversation(true);
  state = finishedInBackground ? "answer" : "working";
  render();
  (finishedInBackground ? $("prompt") : $("cancel-task")).focus({
    preventScroll: true,
  });
});
$("apply-change").addEventListener("click", () => {
  if (state !== "answer" || !result?.patch || $("apply-change").disabled)
    return;
  $("document-text").value = result.patch;
  countDocument();
  $("apply-change").disabled = true;
  $("apply-change").firstChild.textContent = "Applied to the mock window ";
  $("answer-status").textContent = "Mock window updated · Nothing sent";
  announce(
    "Only the editable demo window changed. No real app, file or account was accessed.",
  );
});
$("copy-answer").addEventListener("click", async () => {
  if (state !== "answer" || !result) return;
  const copied = result;
  const text =
    result.title +
    "\n\n" +
    result.blocks
      .map((block) =>
        block.items ? block.items.join("\n") : (block.code ?? block.text),
      )
      .join("\n\n");
  try {
    if (!navigator.clipboard?.writeText)
      throw new Error("Clipboard unavailable");
    await navigator.clipboard.writeText(text); // Explicit user click only. Never read clipboard.
    if (state === "answer" && result === copied)
      $("answer-status").textContent = "Mock answer copied";
    announce("Mock answer copied.");
  } catch {
    if (state === "answer" && result === copied)
      $("answer-status").textContent = "Select answer text to copy manually";
    announce(
      "Clipboard access unavailable. You can select and copy the answer text.",
    );
  }
});
document.addEventListener("pointerdown", (event) => {
  if (!event.target.closest("#appearance, #context-button")) closeAppearance();
  // Outside clicks preserve the answer and conversation.
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && event.target.closest("#demo")) {
    event.preventDefault();
    if (!$("appearance").hidden) closeAppearance(true);
    else
      closeConversation(
        state === "working" ||
          (state === "background" && !finishedInBackground),
      );
  }
  if (
    (event.metaKey || event.ctrlKey) &&
    event.key.toLowerCase() === "k" &&
    event.target.closest("#demo")
  ) {
    event.preventDefault();
    if (["ready", "answer"].includes(state))
      $("prompt").focus({ preventScroll: true });
  }
});
document.querySelectorAll('a[href="#demo"]').forEach((link) =>
  link.addEventListener("click", () => {
    if (state === "closed") startConversation();
    requestAnimationFrame(() => $("prompt").focus({ preventScroll: true }));
  }),
);
window.addEventListener("resize", fitPrompt);
selectExample(example, false);
requestAnimationFrame(fitPrompt);
window.demoReady = true;
