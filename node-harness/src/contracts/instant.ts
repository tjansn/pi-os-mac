import { isOneLineText, type HostAction } from "./actions.js";
import type { CardSpec } from "./cards.js";
import type { InstantScope } from "./context.js";

/**
 * Instant lane contracts (protocol.md "POST /instant") and the classifier /
 * routing vocabulary shared by the instant engine, the Auto router and the
 * optional local classifier.
 *
 * Voice additions (DESIGN4 §4.5, §5.3, §8): a voice `final` may carry every engine's hypotheses and
 * the decision kinds the host understands (`accept`); `act`, `list` and `fallthrough` may carry a
 * `voice` meta. All of it is optional and additive: a request without `hypotheses`/`accept` (the
 * Windows host never calls /instant; older Mac builds) gets today's behaviour, and a response's
 * `voice` is ignored by hosts that do not know it. Swift mirror: `PiOSCore/InstantContracts.swift`
 * (`VoiceHypothesis` in `VoiceTypes.swift`); fixtures: `shared/fixtures/instant/*.json` (responses) and
 * `shared/fixtures/instant/requests/*.json` (request bodies).
 * Hypothesis texts are user content: never logged (counts, roles and sources only).
 *
 * Continuity additions (DESIGN5 §8 with TOM-ANSWERS applied): a final may carry content-free `target` facts
 * (app class, pi-os's own open as an anchor, the bound focused field), the host may declare `accept: "fill"`,
 * and Node may answer `act` intent `fill` (`typeIntoPinned`, optionally `submit: true`), `voice.via: "field"`
 * and `voice.fill: "offer"` on the check card. All optional and additive: a request without `target` and
 * without `"fill"` gets exactly today's decisions. Fixtures: `shared/fixtures/instant/requests/request-target-*`,
 * `instant/act-fill*.json`, `instant/fallthrough-check-fill-offer.json`, `instant/invalid-action/`.
 */

export type InstantPhase = "typing" | "partial" | "final";

/** Enforced on both sides. Lengths are UTF-16 code units (JS `length`, Swift `utf16.count`). */
export const INSTANT_LIMITS = {
  /** `text` (= MAX_INSTANT_TEXT in instant/dispatcher.ts). */
  maxText: 500,
  /** Whole POST /instant body; the host drops trailing hypotheses until the body fits. */
  maxBodyBytes: 4_096,
  maxHypotheses: 6,
  maxHypothesisChars: 200,
  /** `accept` entries (unknown values are ignored, so newer hosts can declare more). */
  maxAccept: 8,
  /** `voice.heard`: the open target as heard. */
  maxHeardChars: 80,
  /** Recognizer ids (`VoiceHypothesis.source`, dictionary `recognizer`). */
  maxRecognizerChars: 32,
} as const;

/**
 * Recognizer ids: the hypothesis `source` values, also the dictionary's recognizer scope (DESIGN4 §6.1).
 * Open set matching RECOGNIZER_ID_PATTERN; `any` scopes typed and manual dictionary entries.
 */
export const RECOGNIZERS = {
  any: "any",
  parakeetV3: "parakeet-v3",
  whisperTurbo: "whisper-turbo",
} as const;
export const RECOGNIZER_ID_PATTERN = /^[a-z][a-z0-9.-]*(?:\/[A-Za-z0-9-]+)?$/;
/** Apple DictationTranscriber for one locale, e.g. `apple-dt/en-US`. */
export const appleDictationRecognizer = (locale: string): string => `apple-dt/${locale}`;
/** Apple SpeechTranscriber fallback (a locale without DictationTranscriber assets), e.g. `apple-st/de-DE`. */
export const appleSpeechRecognizer = (locale: string): string => `apple-st/${locale}`;

export function isRecognizerId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= INSTANT_LIMITS.maxRecognizerChars && RECOGNIZER_ID_PATTERN.test(value);
}

/**
 * The engine part of a recognizer id (`apple-dt` of `apple-dt/en-US`; Swift `RecognizerID.engine(of:)`).
 * This, never the whole id, is what a host sends as POST /invoke `input.engine` (`^[\w.-]{1,64}$`, no `/`);
 * the language travels as `input.locale`.
 */
export function recognizerEngine(id: string): string {
  const slash = id.indexOf("/");
  return slash < 0 ? id : id.slice(0, slash);
}

/** Dictionary entry ids (`voice.learnedEntryId`, contracts/dictionary.ts). */
export const DICTIONARY_ENTRY_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

/** BCP 47 tag as /instant and /invoke accept it (same rule as server.ts and the Swift host). */
export const LOCALE_PATTERN = /^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,3}$/;

export const VOICE_HYPOTHESIS_ROLES = ["primary", "peer", "secondary"] as const;
/**
 * `primary`: the primary engine's final (Phase B: Parakeet). `peer`: a first-tier final of equal standing
 * (Phase A: each Apple DictationTranscriber language). `secondary`: everything gated — another engine's
 * final next to a primary, and every n-best alternative (each alternative is its own entry with its
 * engine's `source`).
 */
export type VoiceHypothesisRole = (typeof VOICE_HYPOTHESIS_ROLES)[number];

/** One recognizer hypothesis of a voice take (Swift `VoiceHypothesis`). */
export interface VoiceHypothesis {
  /** 1..200 UTF-16 units, not blank, no control characters, well-formed. */
  text: string;
  /** Recognizer id, e.g. `parakeet-v3`, `apple-dt/de-DE` (≤ 32, RECOGNIZER_ID_PATTERN). */
  source: string;
  role: VoiceHypothesisRole;
  /** 0..1: mean word confidence (Apple) or the engine's utterance confidence (Parakeet). */
  confidence?: number;
  /** 0..1: the lowest word confidence (the check gate's "< 0.2" signal). */
  minConfidence?: number;
  /** BCP 47 language of this hypothesis (the Apple module's locale, or NLLanguageRecognizer's pick). */
  locale?: string;
}

/**
 * Decision kinds a host understands beyond today's (`InstantRequest.accept`). Node uses a gated kind only
 * when the request declared it; without `accept` the response vocabulary is exactly today's.
 * - `suggest`: the host presents `voice.didYouMean` lists as a "Did you mean …?" card (Heard subtitle,
 *   1–3 keys, spoken picks) and reports picks to POST /dictionary/learn. A did-you-mean is an ordinary
 *   `list`, so Node may send one to any host (older hosts show a focused list, DESIGN4 §8).
 * - `check`: the host shows "Did I hear that right?" for `fallthrough` `low_confidence` with
 *   `voice.check` instead of asking the agent. Node runs the check gate only for such hosts.
 * - `confirm`: the host holds `act` with `confirm: true` for one Return (it always has). Node uses it for
 *   voice uncertainty (a secondary engine, a low-confidence peer, a bare secondary name, an unknown
 *   spoken domain) only for such hosts.
 * - `fill`: the host types into the bound focused field of `target.field`: `act` intent `fill`
 *   (`typeIntoPinned`, `voice.via: "field"`) and `voice.fill: "offer"` on the check card. Node decides a fill
 *   only when the request also carries an eligible `target.field` (FILL_* below); without `"fill"` it never
 *   does, whatever `target` says. The host declares it only while Settings' fill switch is on.
 */
export const INSTANT_ACCEPTS = ["suggest", "check", "confirm", "fill"] as const;
export type InstantAccept = (typeof INSTANT_ACCEPTS)[number];

export interface InstantRequest {
  /** 0..500; for voice the host's pick (normally also a first-tier hypothesis). */
  text: string;
  phase: InstantPhase;
  /** Monotonic per take/composer; responses echo it so hosts drop stale ones. */
  seq: number;
  /**
   * The push-to-talk/composer take. Reused, with a newer `seq`, by every later final of the same take:
   * the Phase B two-step final (Parakeet first, then all hypotheses) and the check state's edited
   * resend (`inputMode: "text"`). Node's take memo keeps the first voice final's hypotheses and adds the
   * later decisions, so `/dictionary/learn` can diff and validate against them.
   */
  takeId?: string;
  contextId?: string;
  /** BCP 47 hint from the host (keyboard or speech locale). */
  locale?: string;
  inputMode?: "text" | "voice";
  /** Voice only: silence since the transcript last changed. */
  silenceMs?: number;
  /**
   * Voice `final` only (ignored otherwise): every engine final plus n-best alternatives, ≤ 6, best
   * first. Absent means today's single-transcript behaviour.
   */
  hypotheses?: VoiceHypothesis[];
  /** Decision kinds the host understands (INSTANT_ACCEPTS). Absent or empty means today's set. */
  accept?: InstantAccept[];
  /**
   * macOS host, `final` phase (typed and voice): content-free facts about the take's pinned target at the
   * final. Parsed on every phase, used on finals only. Absent (Windows never sends it; older Mac builds;
   * no pinned target) means today's behaviour.
   */
  target?: InstantTarget;
}

// ---------------------------------------------------------------------------------------------
// Continuity: the take's target (DESIGN5 §8.1, TOM-ANSWERS). Closed vocabularies; never a bundle id, app
// name, window title, URL, label, field value or length. Swift mirror: `InstantTarget`, `InstantAppClass`,
// `InstantFieldKind` in `PiOSCore/InstantContracts.swift`.

/** Host class of the pinned app: an allowlisted browser, Finder, a terminal, or anything else. */
export const INSTANT_APP_CLASSES = ["browser", "finder", "terminal", "other"] as const;
export type InstantAppClass = (typeof INSTANT_APP_CLASSES)[number];

/**
 * Kind of the bound focused control (host classifier, first match wins; DESIGN5 §5.2):
 * `search` (AXSearchField, a search-labelled text field, text area or combo box), `address` (a browser's
 * address bar), `text` (single-line editable), `multiline` (text areas, contenteditable: chats, documents,
 * notes), `terminal`, `sensitive` (one-time/2FA codes, card numbers, IBAN, CVV), `credential` (username and
 * password fields), `confirm` ("type DELETE to confirm"), `rename` (a Finder rename editor). A control the
 * host cannot type into is no `field` at all.
 */
export const INSTANT_FIELD_KINDS = ["search", "address", "text", "multiline", "terminal", "sensitive", "credential", "confirm", "rename"] as const;
export type InstantFieldKind = (typeof INSTANT_FIELD_KINDS)[number];

/**
 * Field eligibility (TOM-ANSWERS 1, D6). Implicit fill — "everything except commands" — only into these
 * kinds, and only while `ready`, empty or not, single- or multi-line.
 */
export const FILL_IMPLICIT_KINDS = ["search", "address", "text", "multiline"] as const;
/** Explicit "tippe …/type …" only, and only with the Settings credential opt-in. Never journaled, never sent to a remote classifier. */
export const FILL_OPT_IN_KINDS = ["sensitive", "credential"] as const;
/** Never typed into, not even explicitly. */
export const FILL_NEVER_KINDS = ["confirm", "rename"] as const;
// The remaining kind, `terminal`, is explicit only: "tippe …", or the check card's "↩ Type into Terminal" (`voice.fill: "offer"`).

/** Return after a fill without being asked (TOM-ANSWERS 2: auto-Return in search boxes and the address bar). */
export const SUBMIT_AUTO_KINDS = ["search", "address"] as const;
/**
 * Never Return, not even an explicit submit: documents and chats (TOM-ANSWERS 1: "Return never pressed there"),
 * terminals execute, codes, credentials, confirmations and renames commit.
 */
export const SUBMIT_NEVER_KINDS = ["multiline", "terminal", "sensitive", "credential", "confirm", "rename"] as const;

/**
 * May a fill into `kind` carry `submit: true`? Auto only into SUBMIT_AUTO_KINDS; an explicit submit request
 * also into a single-line `text` field; never into SUBMIT_NEVER_KINDS. Node decides with it, and the host
 * re-checks its own bound field before the separate gated Return.
 */
export function fillSubmitAllowed(kind: InstantFieldKind, explicit: boolean): boolean {
  if ((SUBMIT_AUTO_KINDS as readonly string[]).includes(kind)) return true;
  return explicit && !(SUBMIT_NEVER_KINDS as readonly string[]).includes(kind);
}

/** pi-os's own open put the pinned app in front and nothing else was activated since (host memory, ≤ 120 s). */
export interface InstantTargetAnchor {
  /** The instant take that opened it (TAKE_ID pattern). Absent for agent opens. Node looks its own take memo up. */
  takeId?: string;
  /** The app is still launching or not yet settled (the race). A literal `true`; `false` is sent as absent. */
  settling?: true;
}

/** The bound focused control at the final (DESIGN5 §5.1). */
export interface InstantTargetField {
  kind: InstantFieldKind;
  /** No characters and no selection. Never present for `credential` (a length would reveal a password's). */
  empty?: boolean;
  /** Visible and loaded: no web area, or a loaded top-level one; never a nested frame. */
  ready: boolean;
  /** The field still holds exactly pi-os's last fill (host memory). A literal `true`; `false` is sent as absent. */
  ownFill?: true;
}

export interface InstantTarget {
  app: InstantAppClass;
  anchor?: InstantTargetAnchor;
  field?: InstantTargetField;
}

/**
 * What a decision is about. `open_item`: an `act` or `list` that opens files or folders by name — a visible
 * item of the take's target context (`launcher.visibleItems`: desktop icons, the target Finder window) or a
 * found one (a Spotlight did-you-mean). Its rows bind host tokens (`openFile`, never a path) and may sit next
 * to app rows in one did-you-mean list. Not the agent tool of the same name.
 */
export type InstantIntent =
  | "calc"
  | "unit"
  | "currency"
  | "base"
  | "time"
  | "time_convert"
  | "date"
  | "file_search"
  | "open_app"
  | "open_item"
  | "url"
  | "web"
  | "system"
  | "refuse"
  /** Continuity: an `act` that types the take's words into the bound focused field (`typeIntoPinned`). */
  | "fill";

export type FallthroughReason =
  | "no_match"
  | "deictic"
  | "compound"
  | "low_confidence"
  | "timeout"
  | "unknown_place"
  | "disabled";

interface InstantBase {
  seq: number;
  elapsedMs: number;
  source: "grammar" | "classifier";
  /**
   * Advisory context scope of the text (contracts/context.ts), on any phase and decision. Hosts with a
   * context chip use it from `fallthrough` responses only; an absent or malformed value means no suggestion.
   */
  scope?: InstantScope;
}

/**
 * How a voice decision was reached (open set for receivers: an unknown value is dropped, never fatal).
 * `exact`: an exact app name or alias. `alias`: a learned utterance alias (dictionary). `learned`: a
 * learned app name or fix. `sound`: the sound-alike tier. `peer`: a Phase A peer language.
 * `secondary`: a gated secondary hypothesis. `url`: a spoken domain (the voice URL guard).
 * `visible`: a visible item of the take's target context (`open_item`); hosts offer no "Not this" for it
 * and nothing is learned from it. `field`: a fill into the bound focused field (intent `fill`); no "Not
 * this" (a bare "nein/no" within 5 s undoes the typing instead) and nothing is learned from it.
 */
export const VOICE_VIAS = ["exact", "alias", "learned", "sound", "peer", "secondary", "url", "visible", "field"] as const;
export type VoiceVia = (typeof VOICE_VIAS)[number];

/**
 * Optional `voice` on `act`, `list` and `fallthrough` (voice finals). Display and learning hints only:
 * it never authorizes anything (the host re-checks every action with LauncherPolicy).
 */
export interface VoiceMeta {
  /** The open target as heard, ≤ 80 ("page is"): the did-you-mean subtitle and the "Not this" toast. */
  heard?: string;
  /** Recognizer id of the hypothesis that decided. */
  source?: string;
  via?: VoiceVia;
  /**
   * `list` only: a "Did you mean …?" card (DESIGN4 §5.3). Title "Did you mean Pages?" (one row) or
   * "Did you mean…" (2–3 rows), subtitle `Heard "<heard>"`. A pick → POST /dictionary/learn `pick`.
   */
  didYouMean?: boolean;
  /** `fallthrough` `low_confidence` only, and only for hosts that declared `accept: ["check"]`. */
  check?: boolean;
  /**
   * With `check` only, and only for hosts that declared `accept: ["fill"]`: the check card's ↩ types the
   * (possibly edited) card text into the bound field (never with Return) instead of resending it; ⌥↩ still
   * asks pi. Open set for receivers: an unknown value is dropped on its own.
   */
  fill?: VoiceFill;
  /** A learned dictionary rule decided: "Not this" → POST /dictionary/learn `reject` with this id. */
  learnedEntryId?: string;
  /**
   * "No, I meant X" (spoken or typed, ≤ 2 min after an act): the earlier take this one corrects. The host
   * then sends POST /dictionary/learn `{takeId: correctsTakeId, kind: "no_i_meant", correctedText}`.
   */
  correctsTakeId?: string;
}

/** `voice.fill` values (VoiceMeta.fill). */
export const VOICE_FILLS = ["offer"] as const;
export type VoiceFill = (typeof VOICE_FILLS)[number];

export type InstantResponse = InstantBase &
  (
    | { decision: "answer"; intent: InstantIntent; title: string; subtitle?: string; card: CardSpec }
    | { decision: "list"; intent: "file_search" | "open_app" | "open_item"; title: string; card: CardSpec; relaxed?: boolean; voice?: VoiceMeta }
    | { decision: "act"; intent: InstantIntent; title: string; action: HostAction; confirm: boolean; card?: CardSpec; voice?: VoiceMeta }
    | { decision: "refuse"; code: "file_deletion_blocked"; message: string; card: CardSpec }
    | { decision: "fallthrough"; reason: FallthroughReason; hints?: ClassifierHints; voice?: VoiceMeta }
  );

export type InstantDecision = InstantResponse["decision"];

// ---------------------------------------------------------------------------------------------
// Strict parsers (server.ts wires them into POST /instant; errors never echo values)

export type InstantParse<T> = { ok: true; value: T } | { ok: false; error: string };

const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
const TAKE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const ACCEPT_VALUE = /^[a-z][A-Za-z]{0,31}$/;
const PHASES: readonly InstantPhase[] = ["typing", "partial", "final"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
/** An optional member is present unless absent or JSON `null` (Swift `decodeIfPresent` semantics). */
function present(value: unknown): boolean {
  return value !== undefined && value !== null;
}
function isUnit(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}
function oneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}

/** Single-line, well-formed, not blank, at most `max` UTF-16 units. */
export function isVoiceText(value: unknown, max: number = INSTANT_LIMITS.maxHypothesisChars): value is string {
  return typeof value === "string" && value.length <= max && value.trim().length > 0 && !CONTROL.test(value) && !LONE_SURROGATE.test(value);
}

export function parseVoiceHypothesis(value: unknown): InstantParse<VoiceHypothesis> {
  if (!isRecord(value)) return { ok: false, error: "hypothesis must be an object" };
  if (!isVoiceText(value.text)) return { ok: false, error: "hypothesis.text must be 1..200 characters of single-line text" };
  if (!isRecognizerId(value.source)) return { ok: false, error: "hypothesis.source must be a recognizer id" };
  if (!oneOf(VOICE_HYPOTHESIS_ROLES, value.role)) return { ok: false, error: "hypothesis.role must be primary, peer or secondary" };
  const hypothesis: VoiceHypothesis = { text: value.text, source: value.source, role: value.role };
  for (const key of ["confidence", "minConfidence"] as const) {
    if (!present(value[key])) continue;
    if (!isUnit(value[key])) return { ok: false, error: `hypothesis.${key} must be 0..1` };
    hypothesis[key] = value[key];
  }
  if (present(value.locale)) {
    if (typeof value.locale !== "string" || !LOCALE_PATTERN.test(value.locale)) return { ok: false, error: "hypothesis.locale must be a BCP 47 tag" };
    hypothesis.locale = value.locale;
  }
  return { ok: true, value: hypothesis };
}

/** `hypotheses`: absent/null → undefined; otherwise an array of 1..6 valid hypotheses (one bad entry fails all). */
export function parseVoiceHypotheses(value: unknown): InstantParse<VoiceHypothesis[] | undefined> {
  if (!present(value)) return { ok: true, value: undefined };
  if (!Array.isArray(value) || value.length === 0 || value.length > INSTANT_LIMITS.maxHypotheses) {
    return { ok: false, error: "hypotheses must be an array of 1..6 hypotheses" };
  }
  const hypotheses: VoiceHypothesis[] = [];
  for (const [index, item] of value.entries()) {
    const parsed = parseVoiceHypothesis(item);
    if (!parsed.ok) return { ok: false, error: `hypotheses[${index}]: ${parsed.error}` };
    hypotheses.push(parsed.value);
  }
  return { ok: true, value: hypotheses };
}

/**
 * `accept`: absent/null → undefined; an array of ≤ 8 lowerCamel words. Unknown words are dropped (a newer
 * host may declare more), duplicates collapse, and the result keeps INSTANT_ACCEPTS order.
 */
export function parseInstantAccept(value: unknown): InstantParse<InstantAccept[] | undefined> {
  if (!present(value)) return { ok: true, value: undefined };
  if (!Array.isArray(value) || value.length > INSTANT_LIMITS.maxAccept || !value.every((item) => typeof item === "string" && ACCEPT_VALUE.test(item))) {
    return { ok: false, error: "accept must be an array of at most 8 decision kinds" };
  }
  return { ok: true, value: INSTANT_ACCEPTS.filter((kind) => value.includes(kind)) };
}

export function accepts(request: Pick<InstantRequest, "accept">, kind: InstantAccept): boolean {
  return request.accept?.includes(kind) === true;
}

/**
 * Strict validation of a POST /instant body (400 on failure). Unknown keys are dropped; JSON null on an
 * optional member is absent. Same rules as the Swift `InstantRequest` decoder.
 */
export function parseInstantRequest(value: unknown): InstantParse<InstantRequest> {
  if (!isRecord(value)) return { ok: false, error: "Body must be a JSON object" };
  if (typeof value.text !== "string" || value.text.length > INSTANT_LIMITS.maxText) {
    return { ok: false, error: `text (string, at most ${INSTANT_LIMITS.maxText} characters) is required` };
  }
  if (!PHASES.includes(value.phase as InstantPhase)) return { ok: false, error: "phase must be typing, partial or final" };
  if (typeof value.seq !== "number" || !Number.isSafeInteger(value.seq) || value.seq < 0) return { ok: false, error: "seq must be a non-negative integer" };
  const request: InstantRequest = { text: value.text, phase: value.phase as InstantPhase, seq: value.seq };
  for (const key of ["takeId", "contextId"] as const) {
    if (!present(value[key])) continue;
    if (typeof value[key] !== "string" || !TAKE_ID.test(value[key])) return { ok: false, error: `Invalid ${key}` };
    request[key] = value[key];
  }
  if (present(value.locale)) {
    if (typeof value.locale !== "string" || !LOCALE_PATTERN.test(value.locale)) return { ok: false, error: "locale must be a BCP 47 tag" };
    request.locale = value.locale;
  }
  if (present(value.inputMode)) {
    if (value.inputMode !== "text" && value.inputMode !== "voice") return { ok: false, error: "inputMode must be text or voice" };
    request.inputMode = value.inputMode;
  }
  if (present(value.silenceMs)) {
    if (typeof value.silenceMs !== "number" || !Number.isFinite(value.silenceMs) || value.silenceMs < 0) return { ok: false, error: "silenceMs must be a non-negative number" };
    request.silenceMs = value.silenceMs;
  }
  const hypotheses = parseVoiceHypotheses(value.hypotheses);
  if (!hypotheses.ok) return hypotheses;
  if (hypotheses.value) request.hypotheses = hypotheses.value;
  const accept = parseInstantAccept(value.accept);
  if (!accept.ok) return accept;
  if (accept.value) request.accept = accept.value;
  const target = parseInstantTarget(value.target);
  if (!target.ok) return target;
  if (target.value) request.target = target.value;
  return { ok: true, value: request };
}

/** A literal-`true` flag: absent, null and `false` are absent; anything but a boolean is invalid. */
function trueFlag(value: unknown): { ok: boolean; set: boolean } {
  if (!present(value) || value === false) return { ok: true, set: false };
  return { ok: value === true, set: value === true };
}

/**
 * `target`: absent/null → undefined. Strict: closed vocabularies, `ready` required, `takeId` in the TAKE_ID
 * pattern, `credential` never with `empty` (present at all). Unknown keys are dropped at every level; null on
 * an optional member is absent. Errors name the member, never a value. Same rules as Swift `InstantTarget`.
 */
export function parseInstantTarget(value: unknown): InstantParse<InstantTarget | undefined> {
  if (!present(value)) return { ok: true, value: undefined };
  if (!isRecord(value)) return { ok: false, error: "target must be an object" };
  if (!oneOf(INSTANT_APP_CLASSES, value.app)) return { ok: false, error: "target.app must be browser, finder, terminal or other" };
  const target: InstantTarget = { app: value.app };
  if (present(value.anchor)) {
    const anchor = value.anchor;
    if (!isRecord(anchor)) return { ok: false, error: "target.anchor must be an object" };
    const parsed: InstantTargetAnchor = {};
    if (present(anchor.takeId)) {
      if (typeof anchor.takeId !== "string" || !TAKE_ID.test(anchor.takeId)) return { ok: false, error: "Invalid target.anchor.takeId" };
      parsed.takeId = anchor.takeId;
    }
    const settling = trueFlag(anchor.settling);
    if (!settling.ok) return { ok: false, error: "target.anchor.settling must be true or absent" };
    if (settling.set) parsed.settling = true;
    target.anchor = parsed;
  }
  if (present(value.field)) {
    const field = value.field;
    if (!isRecord(field)) return { ok: false, error: "target.field must be an object" };
    if (!oneOf(INSTANT_FIELD_KINDS, field.kind)) return { ok: false, error: "target.field.kind must be a field kind" };
    if (typeof field.ready !== "boolean") return { ok: false, error: "target.field.ready must be a boolean" };
    if (present(field.empty)) {
      if (field.kind === "credential") return { ok: false, error: "target.field.empty is never sent for a credential field" };
      if (typeof field.empty !== "boolean") return { ok: false, error: "target.field.empty must be a boolean" };
    }
    // Wire order: kind, empty, ready, ownFill.
    const parsed: InstantTargetField = { kind: field.kind, ...(typeof field.empty === "boolean" ? { empty: field.empty } : {}), ready: field.ready };
    const ownFill = trueFlag(field.ownFill);
    if (!ownFill.ok) return { ok: false, error: "target.field.ownFill must be true or absent" };
    if (ownFill.set) parsed.ownFill = true;
    target.field = parsed;
  }
  return { ok: true, value: target };
}

/**
 * `act` consistency for continuity (both sides): intent `fill` carries `typeIntoPinned` with one-line text
 * (submitting or not: a CR/LF would be a Return of its own, a Tab would move focus), and only a fill carries
 * `submit`. Swift's `InstantResponse` decoder rejects every other combination.
 */
export function fillActConsistent(intent: string, action: HostAction): boolean {
  const typing = action.type === "typeIntoPinned";
  if (intent === "fill") return typing && isOneLineText(action.text);
  return !(typing && action.submit === true);
}

/**
 * Structural check of a response's `voice` (hosts drop a malformed one, never the response). An unknown
 * `via` or `fill` string is dropped on its own (open sets); any other bad member makes the whole meta null.
 */
export function parseVoiceMeta(value: unknown): VoiceMeta | null {
  if (!isRecord(value)) return null;
  const meta: VoiceMeta = {};
  if (present(value.heard)) {
    if (!isVoiceText(value.heard, INSTANT_LIMITS.maxHeardChars)) return null;
    meta.heard = value.heard;
  }
  if (present(value.source)) {
    if (!isRecognizerId(value.source)) return null;
    meta.source = value.source;
  }
  if (present(value.via)) {
    if (typeof value.via !== "string") return null;
    if (oneOf(VOICE_VIAS, value.via)) meta.via = value.via;
  }
  for (const key of ["didYouMean", "check"] as const) {
    if (!present(value[key])) continue;
    if (typeof value[key] !== "boolean") return null;
    meta[key] = value[key];
  }
  if (present(value.learnedEntryId)) {
    if (typeof value.learnedEntryId !== "string" || !DICTIONARY_ENTRY_ID_PATTERN.test(value.learnedEntryId)) return null;
    meta.learnedEntryId = value.learnedEntryId;
  }
  if (present(value.correctsTakeId)) {
    if (typeof value.correctsTakeId !== "string" || !TAKE_ID.test(value.correctsTakeId)) return null;
    meta.correctsTakeId = value.correctsTakeId;
  }
  if (present(value.fill)) {
    if (typeof value.fill !== "string") return null;
    if (oneOf(VOICE_FILLS, value.fill)) meta.fill = value.fill;
  }
  return meta;
}

/** Router tiers; "instant" means no model at all. */
export const TIERS = ["instant", "quick", "fast", "standard", "deep", "max"] as const;
export type Tier = (typeof TIERS)[number];

export type AgentIntent =
  | "calculate"
  | "search_computer"
  | "open_launch"
  | "answer"
  | "write"
  | "act_in_app"
  | "browse_web"
  | "code"
  | "other";

/**
 * Advisory output of any classifier (Laya sidecar, a pi catalog classifier
 * such as Cloudflare-hosted Jev/Clef, or the built-in heuristics). It may raise
 * a tier or request a screenshot; it never authorizes or triggers an action.
 */
export interface ClassifierHints {
  source: "laya" | "pi-classifier" | "heuristic";
  latencyMs: number;
  intent?: AgentIntent;
  intentP?: number;
  tier?: Tier;
  tierP?: number;
  needsScreen?: number;
  complete?: number;
}

export interface IntentClassifier {
  readonly name: string;
  /**
   * False for classifiers that send text off this machine (kind "pi", e.g. a cloud model). Those
   * are consulted only for a final utterance, never for typing/voice partials. Default: local.
   */
  readonly local?: boolean;
  /** Never throws; resolves null when unavailable, timed out or aborted. */
  classify(text: string, signal: AbortSignal): Promise<ClassifierHints | null>;
}

export const NO_CLASSIFIER: IntentClassifier = {
  name: "off",
  classify: async () => null,
};
