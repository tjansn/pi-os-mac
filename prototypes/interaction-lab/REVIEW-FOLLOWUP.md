# Independent review follow-up

The read-only fifth worker reviewed the initial storyboard in
[`docs/research/immersive-hci/prototype-review.md`](../../docs/research/immersive-hci/prototype-review.md).
Its findings remain recorded there; the coordinator made these isolated prototype changes afterward.

| Finding | Prototype correction | Verification |
|---|---|---|
| HIGH: document text hidden behind a button's overridden accessible name | Readable paragraph + separate Include control with text/state descriptions | Browser accessibility snapshot shows original paragraph independently; **VoiceOver unverified** |
| Stale point still appeared authorized in inspector/preview | Shared current-point predicate; stale context labeled historical, target unbound; no new stale preview | Focus-change replay observed |
| Unsafe-looking Undo availability / stale preview after Undo | Validity-aware disabled Undo; successful Undo clears point and proposal | Human-edit disabled state and Apply → new preview → Undo observed |
| Escape falsely said nothing had been applied | Conditional receipt states earlier edits remain | Apply → Escape observed |
| Keyboard preview/apply discovery and focus loss | Focus draft summary; forward Tab reaches Apply; Apply/Discard/Undo return focus to Preview | Browser key events observed; physical keyboard unverified |
| Recipe preview survives changed arguments | Invalidate on input changes; field-associated validation error and aria-invalid | PI-218 → PI-219 and invalid input observed |
| Buttons imply actual shortcut/selection/voice integration | All routes labeled invocation fixtures; compiler test claim narrowed | Source/snapshot inspected; no real adapters claimed |
| Ambient receipt claims an artifact opened | “Would request a mock preview” | Addressed fixture observed |
| Missing/doubled announcements | Recipe result status + field description; ambient side receipt not live | Source/ARIA attribute inspected; screen-reader timing unverified |
| Broad privacy/CSP implications | App-owned persistence qualifier; lack-of-capture code distinguished from CSP and browser guarantees | Static review only |
| Evidence not source/version-bound | v2 source SHA-256, timestamp, replay steps and versioned screenshots recorded | `review-checks.json` |
| Small boundary/caveat text | Enlarged microphone details, caveat and footer | Desktop/narrow screenshots visually inspected |

**Remaining:** the mobile storyboard is intentionally long and not a native on-screen assistant; a shorter action-first layout is still an experiment. Real assistive-technology parity, VoiceOver announcement order, zoom/forced colors and native input authority are not approved. Browser events are not physical keyboard tests. No microphone, ASR or trained model was introduced, and the Node test guard was not bypassed.

**Scope verdict:** useful for disclosed offline design comparison after the structural HIGH fix; not an accessibility, privacy-sandbox, native-safety or immersive-effectiveness sign-off. See the review's three proposed studies for measuring directness, habit transfer and interruption/trust calibration.
