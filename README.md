# pi-os for Mac website

Official website for Tom’s Mac fork, based on the selected **Whisper** HTML/native-glass design studies.

**Live:** https://tjansn.github.io/pi-os-mac/

This independent `gh-pages` branch contains the website only. It does not modify the Mac app, the upstream draft PR or the installed build.

## Develop

No dependencies, build step, inference server or API keys.

```sh
python3 -m http.server 18743 --bind 127.0.0.1 --directory public
# Visit http://127.0.0.1:18743/

npm run check
npm test
```

Optional browser checks require an already installed `agent-browser` CLI:

```sh
npm run test:browser
# Against a deployed site:
SITE_URL=https://tjansn.github.io/pi-os-mac/ npm run test:browser
```

The runner creates and closes its own isolated headless session. It never attaches to an existing browser or calls a model. Clipboard is stubbed in tests. Screenshots and reports go to ignored `qa/`.

## Usable, but entirely mocked

- Editable Notes, Mail and Code examples; changing example explicitly starts a new conversation.
- Extractive summaries, shortening and checklists operate on the current example text. Email rewrites and code explanations are explicitly fixed templates. Unknown requests get an honest fallback.
- Return submits, Shift-Return adds a line; sequential follow-ups retain the mock target. IME composition is not submitted prematurely.
- Simulated working, cancellation, background completion, reader reopening and conversation closure. Generation checks reject late completion after cancellation/reset.
- Apply updates only the in-page example. Nothing is executed, sent, deleted or connected to an app/account.
- Six visual presets, larger text, opacity and spacing. Appearance never resets the conversation or switches its target.
- Copy is the one deliberate browser-side capability: an explicit click writes answer text to the clipboard; it never reads it. Refusal leaves selectable answer text.
- No network API, telemetry, third-party fonts/assets, cookie/session storage or prompt text in URLs. Only enum-valued example/theme parameters are shareable. CSP additionally blocks network APIs, forms, workers and frames. GitHub still serves/logs ordinary static HTTP requests.

## Deployment

`.github/workflows/pages.yml` tests and uploads **only `public/`**, then deploys with GitHub Pages on a push to `gh-pages`. The repository’s Pages build type is `workflow`. Tests, `.git`, source-app files and local QA are not published.

No fake download button: the native port is a source-build preview. Build/acceptance links point to `feat/macos-native-host` and upstream draft PR #2. Update those links when the native contribution lands or branches change.

## Acceptance

Local: **28 pure/static tests + 48 isolated Chromium browser checks**. Checked multiline follow-ups, focus continuity, explicit target changes, all presets, cancellation/late completion, background work, application to the fake document, copy failure, text-only injection handling, same-origin asset-only traffic, reduced motion, System light/dark, and overflow/anchoring at 320/390/768/1440 px.

Screenshot review covers desktop and mobile HTML rendering. This is not native Apple material, Safari, VoiceOver, physical keyboard or full WCAG acceptance. Native-app acceptance remains separately documented in the Mac source branch.

MIT. pi-os upstream credit: [PriNova/pi-os](https://github.com/PriNova/pi-os).
