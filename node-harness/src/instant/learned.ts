import {
  DICTIONARY_LIMITS, foldPhrase, isBundleId, isFoldedPhrase, isRefusedPhrase, NO_DICTIONARY, recognizerApplies,
  type DictionaryEditRequest, type DictionaryEntryInput, type DictionaryLearnRequest, type DictionaryList, type DictionaryLookup,
  type DictionaryMatch, type DictionarySource, type DictionaryWriteCode, type DictionaryWriteResponse, type RegressionTake, type SafeTarget,
} from "../contracts/dictionary.js";
import { INSTANT_ACCEPTS, isVoiceText, RECOGNIZERS, type InstantResponse, type VoiceHypothesis } from "../contracts/instant.js";
import type { AppRecord } from "../contracts/launcher.js";
import { BUILTIN_APP_ALIASES } from "./apps.js";
import {
  contentWords, hasContentWord, isNotAName, nameCore, nonCountingLookup, utteranceCore,
  type DictionaryStore, type EntryContent, type WriteOutcome,
} from "./dictionary.js";
import type { InstantDispatcher } from "./dispatcher.js";
import { DEFAULT_WEB_SEARCH, openStrength, parseInstant } from "./grammar/index.js";
import { normalize } from "./normalize.js";
import { safeTargetOf, type TakeRecord } from "./takeMemo.js";
import { correctionTarget } from "./voice.js";

/**
 * Learning from user gestures (DESIGN4 §6.2, §6.5, §6.6, §6.8): POST /dictionary/learn and
 * POST /dictionary/edit decide here what — if anything — a gesture may teach, and the DictionaryStore
 * persists it. A port of the r3/learning prototype (`sim/learn/engine.ts`) to the frozen contracts:
 *
 * - Only a take in the memo can teach; a pick or confirm only a bundle the take offered or acted on;
 *   "No, I meant" and transcript edits only a target the instant lane itself resolves (`unresolved`).
 * - Policy first and last: words the grammar refuses, or marks deictic or compound, and deletion
 *   vocabulary are never learned (`refused_phrase`); targets are closed (`SafeTarget`).
 * - The alias guard (§6.5): an utterance alias needs ≥ 2 content words or one non-common content word
 *   of ≥ 5 letters; a bare verb, politeness, a number or a filler never becomes one. An app name that is
 *   one common word asks first (`common_word`).
 * - Shadowing an installed app's exact name asks first (`shadows_app`) and stays recognizer-scoped.
 * - Explicit gestures (pick, confirm) learn at once with Undo; inferred ones (no_i_meant, edit) ask once
 *   (`inferred`); learn mode "ask" asks for everything, "off" persists nothing.
 * - No generalized verb rewrites: an edit that changes the verb becomes an exact utterance alias.
 *
 * Nothing here logs: callers log the content-free outcome (kind, status, code).
 */

// ---------------------------------------------------------------------------------------------
// The instant lane as learning sees it

export interface LearnLane {
  /**
   * Canonical heard name (nameCore) of an "open X" form in `text`, or null when the grammar sees none.
   * `voice`: the words were spoken, so the spoken grammar applies (wrappers, German verb-final "X öffnen");
   * a name said alone is never an open form here (it learns an alias, behind the alias guard).
   */
  openTarget(text: string, locale?: string, voice?: boolean): string | null;
  /**
   * True when the grammar (typed or spoken) refuses the words, or marks them deictic or compound, or names a
   * deletion object, or they hold deletion vocabulary.
   */
  blocked(text: string, locale?: string): boolean;
  /** The closed target the instant lane acts on for `text` as a final, or null. */
  resolve(text: string, options: { locale?: string; inputMode: "text" | "voice" }, signal?: AbortSignal): Promise<SafeTarget | null>;
  /** The installed app's display name; null when the host index does not list it, undefined when the index is unknown. */
  appDisplay(bundleId: string): string | null | undefined;
  /** The installed app whose exact name or alias folds to `folded`. */
  exactApp(folded: string): string | undefined;
  /** Optional EN/DE common-word lexicon (N1's lexicon.ts): a single common word never acts as an alias on its own. */
  isCommonWord?(word: string): boolean;
  /**
   * The regression check (DESIGN4 §6.7): what one journal take decides as a single voice hypothesis from its
   * recognizer — with the dictionary as it is, or with the candidate rule added.
   */
  outcome?(take: RegressionTake, rule: CandidateRule | undefined, signal?: AbortSignal): Promise<TakeOutcome>;
}

/** A take's decision as the regression check compares it: what an act does, an answer, or anything else. */
export type TakeOutcome = { kind: "act"; target: SafeTarget | undefined } | { kind: "answer" } | { kind: "none" };

/** Valid app records of a host index (shape and an openApp-able bundle id). */
export function appRecords(apps: unknown): AppRecord[] {
  if (!Array.isArray(apps)) return [];
  return apps.filter((app): app is AppRecord => typeof app === "object" && app !== null
    && isBundleId((app as AppRecord).bundleId) && typeof (app as AppRecord).name === "string" && typeof (app as AppRecord).path === "string"
    && Array.isArray((app as AppRecord).aliases) && (app as AppRecord).aliases.every((alias) => typeof alias === "string"));
}

/** The shorter proper name a card shows: an alias that is a whole-word prefix of the name ("Pages" for "Pages Creator Studio"). */
export function displayName(app: Pick<AppRecord, "name" | "aliases">): string {
  const name = app.name.trim();
  const folded = foldPhrase(name);
  const shorter = app.aliases.map((alias) => alias.trim())
    .filter((alias) => alias && foldPhrase(alias) && (folded === foldPhrase(alias) || folded.startsWith(`${foldPhrase(alias)} `)))
    .sort((a, b) => a.length - b.length)[0];
  const display = shorter && shorter.length < name.length ? shorter : name;
  return display.slice(0, DICTIONARY_LIMITS.displayChars);
}

/** Every exact spoken form of an app: its name, the host's aliases, the built-in EN/DE aliases, the bundle file name. */
function exactForms(app: AppRecord): string[] {
  return [app.name, ...app.aliases, ...(BUILTIN_APP_ALIASES[app.bundleId] ?? []), app.path.split("/").pop()?.replace(/\.app$/i, "") ?? ""]
    .map(foldPhrase).filter(Boolean);
}

export interface LaneOptions {
  /** A dispatcher without the advisory classifier or file search (resolving never leaves the machine). */
  dispatcher: Pick<InstantDispatcher, "dispatch">;
  /** The host's app index when known. */
  apps: () => readonly AppRecord[] | undefined;
  isCommonWord?: (word: string) => boolean;
  /**
   * The dictionary the regression check starts from (with and without the candidate rule; pass a
   * non-counting lookup). Default: none.
   */
  dictionary?: DictionaryLookup;
}

/** The production lane: the anchored EN/DE grammar (`parseInstant`) and the instant dispatcher. */
export function createLearnLane(options: LaneOptions): LearnLane {
  const parse = (text: string, locale?: string, voice = false) => {
    try {
      return parseInstant(normalize(text, locale), { now: new Date(), locale: locale ?? "en-US", webSearchTemplate: DEFAULT_WEB_SEARCH }, voice ? { voice: true } : {});
    } catch {
      return null;
    }
  };
  const isBlocked = (parsed: ReturnType<typeof parse>): boolean => parsed?.kind === "refuse" || parsed?.kind === "delete_target"
    || (parsed?.kind === "fallthrough" && (parsed.reason === "deictic" || parsed.reason === "compound"));
  // Replays are not uses: the regression check never counts a rule that decided.
  const base = nonCountingLookup(options.dictionary ?? NO_DICTIONARY);
  let cached: { apps: readonly AppRecord[]; byBundle: Map<string, AppRecord>; byForm: Map<string, string> } | undefined;
  const index = () => {
    const apps = options.apps();
    if (!apps) return undefined;
    if (cached?.apps !== apps) {
      const byForm = new Map<string, string>();
      for (const app of apps) for (const form of exactForms(app)) if (!byForm.has(form)) byForm.set(form, app.bundleId);
      cached = { apps, byBundle: new Map(apps.map((app) => [app.bundleId, app])), byForm };
    }
    return cached;
  };
  return {
    openTarget(text, locale, voice) {
      const parsed = parse(text, locale, voice);
      if (parsed?.kind !== "open" || openStrength(parsed) === "bare") return null;
      return nameCore(parsed.target) || null;
    },
    blocked(text, locale) {
      if (isRefusedPhrase(text)) return true;
      // Typed and spoken policy: the spoken grammar also checks the command core ("um, delete this file").
      return isBlocked(parse(text, locale)) || isBlocked(parse(text, locale, true));
    },
    async resolve(text, { locale, inputMode }, signal) {
      try {
        const response = await options.dispatcher.dispatch({ text, phase: "final", seq: 0, inputMode, ...(locale ? { locale } : {}) }, signal);
        if (response.decision !== "act") return null;
        const target = safeTargetOf(response.action);
        if (target?.kind === "openApp" && index()?.byBundle.has(target.bundleId) === false) return null;
        return target ?? null;
      } catch {
        return null;
      }
    },
    appDisplay(bundleId) {
      const known = index();
      if (!known) return undefined;
      const app = known.byBundle.get(bundleId);
      return app ? displayName(app) : null;
    },
    exactApp(folded) {
      return index()?.byForm.get(folded);
    },
    async outcome(take, rule, signal) {
      try {
        const response = await options.dispatcher.dispatch({
          text: take.text, phase: "final", seq: 0, inputMode: "voice", accept: [...INSTANT_ACCEPTS],
          hypotheses: [{ text: take.text, source: take.source, role: "primary" }],
        }, signal, { dictionary: rule ? withCandidate(base, rule) : base });
        return takeOutcome(response);
      } catch {
        return { kind: "none" };
      }
    },
    ...(options.isCommonWord ? { isCommonWord: options.isCommonWord } : {}),
  };
}

function takeOutcome(response: InstantResponse): TakeOutcome {
  if (response.decision === "act") return { kind: "act", target: safeTargetOf(response.action) };
  if (response.decision === "answer") return { kind: "answer" };
  return { kind: "none" };
}

/** Entry id the candidate rule answers with (never stored). */
const CANDIDATE_ID = "candidate";

/**
 * `base` plus the candidate rule, which wins over a stored rule for the same heard phrase (as a new binding
 * would replace it). Exact like the store: folded, or without wrapper particles. Never counts uses.
 */
export function withCandidate(base: DictionaryLookup, rule: CandidateRule): DictionaryLookup {
  const applies = (recognizer: string) => recognizerApplies(rule.recognizer, recognizer);
  return {
    revision: () => base.revision(),
    settings: () => base.settings(),
    alias(phrase, recognizer) {
      if (rule.list === "aliases" && applies(recognizer) && [foldPhrase(phrase), utteranceCore(phrase)].includes(rule.phrase)) {
        return { ref: { list: "aliases", id: CANDIDATE_ID }, value: rule.target };
      }
      return base.alias(phrase, recognizer);
    },
    appName(heard, recognizer) {
      if (rule.list === "appNames" && applies(recognizer) && [foldPhrase(heard), nameCore(heard)].includes(rule.heard)) {
        return { ref: { list: "appNames", id: CANDIDATE_ID }, value: { bundleId: rule.bundleId, display: rule.display } };
      }
      return base.appName(heard, recognizer);
    },
    fixes(recognizer) {
      const stored = base.fixes(recognizer);
      if (rule.list !== "fixes" || !applies(recognizer)) return stored;
      const candidate: DictionaryMatch<{ heard: string; intended: string }> = { ref: { list: "fixes", id: CANDIDATE_ID }, value: { heard: rule.heard, intended: rule.intended } };
      const words = (text: string) => text.split(" ").length;
      return [candidate, ...stored.filter((fix) => fix.value.heard !== rule.heard)]
        .sort((a, b) => words(b.value.heard) - words(a.value.heard) || b.value.heard.length - a.value.heard.length);
    },
    noteUse: () => {},
  };
}

// ---------------------------------------------------------------------------------------------
// Guards

/**
 * DESIGN4 §6.5: an utterance alias needs ≥ 2 content words, or one content word of ≥ 5 letters that is not
 * a common word. Function words, bare verbs ("Open", "Oben"), politeness ("Bitte"), numbers ("Drei") and
 * tokens of ≤ 2 characters are never content.
 */
export function aliasGuardPasses(phrase: string, isCommonWord?: (word: string) => boolean): boolean {
  const content = contentWords(foldPhrase(phrase));
  if (content.length >= 2) return true;
  const [only] = content;
  return only !== undefined && only.replace(/\d/g, "").length >= 5 && !isCommonWord?.(only);
}

/** An app name that is a single common word ("notes", "music") asks before it is learned. */
function isCommonName(heard: string, lane: LearnLane): boolean {
  const parts = heard.split(" ");
  return parts.length === 1 && lane.isCommonWord?.(parts[0]!) === true;
}

// ---------------------------------------------------------------------------------------------
// Candidate rules

export type CandidateRule =
  | { list: "appNames"; heard: string; bundleId: string; display: string; recognizer: string; shadows?: string }
  | { list: "aliases"; phrase: string; target: SafeTarget; recognizer: string }
  | { list: "fixes"; heard: string; intended: string; recognizer: string };

type Plan =
  | { ok: true; rule: CandidateRule; source: DictionarySource; label: string }
  | { ok: false; code: DictionaryWriteCode };

function ruleContent(rule: CandidateRule): EntryContent {
  switch (rule.list) {
    case "appNames": return { list: "appNames", heard: rule.heard, bundleId: rule.bundleId, display: rule.display, ...(rule.shadows ? { shadows: rule.shadows } : {}) };
    case "aliases": return { list: "aliases", phrase: rule.phrase, target: rule.target };
    case "fixes": return { list: "fixes", heard: rule.heard, intended: rule.intended };
  }
}

/** The rule's heard phrase occurs in the take's words (a cheap filter before replaying the take). */
function mayTouch(rule: CandidateRule, text: string): boolean {
  const heard = rule.list === "aliases" ? rule.phrase : rule.heard;
  const words = ` ${foldPhrase(text)} `;
  return heard.split(" ").every((word) => words.includes(` ${word} `));
}

const sameTarget = (a: SafeTarget | undefined, b: SafeTarget | undefined): boolean => JSON.stringify(a) === JSON.stringify(b);

/**
 * Accepted journal takes the rule would change (DESIGN4 §6.7). Each take is replayed as one voice hypothesis
 * from its recognizer, with and without the rule. A take whose decision does not change is no conflict.
 * One that changes conflicts when the user kept a different target, or — without a `target`, which may be
 * an acted URL, a volume change or an answer just as well as an agent hand-off — when it acted or answered
 * before the rule: a missing target never means "did not act". A take that went to the agent and now acts
 * is what a rule is for. Lanes without `outcome` (tests) fall back to an exact comparison of heard phrases.
 */
export async function regressionConflicts(rule: CandidateRule, takes: readonly RegressionTake[], lane: LearnLane, signal?: AbortSignal): Promise<number[]> {
  const conflicts: number[] = [];
  for (const [index, take] of takes.entries()) {
    if (rule.recognizer !== RECOGNIZERS.any && rule.recognizer !== take.source) continue;
    if (!mayTouch(rule, take.text)) continue;
    if (!lane.outcome) {
      if (!take.target || rule.list === "fixes") continue;
      const matches = rule.list === "aliases" ? utteranceCore(take.text) === rule.phrase : lane.openTarget(take.text, undefined, true) === rule.heard;
      const target: SafeTarget = rule.list === "aliases" ? rule.target : { kind: "openApp", bundleId: rule.bundleId };
      if (matches && !sameTarget(target, take.target)) conflicts.push(index);
      continue;
    }
    const before = await lane.outcome(take, undefined, signal);
    const after = await lane.outcome(take, rule, signal);
    const changed = before.kind !== after.kind || (before.kind === "act" && after.kind === "act" && !sameTarget(before.target, after.target));
    if (!changed) continue;
    if (take.target ? !(after.kind === "act" && sameTarget(after.target, take.target)) : before.kind !== "none") conflicts.push(index);
  }
  return conflicts;
}

/** User-visible label of a target ("Raycast", "example.com", "Volume 50 %"). */
function targetLabel(target: SafeTarget, lane: LearnLane): string {
  switch (target.kind) {
    case "openApp": return lane.appDisplay(target.bundleId) ?? target.bundleId;
    case "openURL": {
      try { return new URL(target.url).host; } catch { return "the page"; }
    }
    case "system":
      if (target.op === "volume.mute") return target.value === false ? "Unmute" : "Mute";
      if (target.op === "volume.set") return `Volume ${Math.round(Number(target.value) * 100)} %`;
      return Number(target.value) > 0 ? "Volume up" : "Volume down";
  }
}

const MAX_QUOTE = 48;

function quote(text: string): string {
  const short = text.length > MAX_QUOTE ? `${text.slice(0, MAX_QUOTE - 1)}…` : text;
  return `“${short}”`;
}

function line(text: string): string {
  const single = text.replace(/\s+/g, " ").trim();
  return single.length > DICTIONARY_LIMITS.lineChars ? `${single.slice(0, DICTIONARY_LIMITS.lineChars - 1)}…` : single;
}

function ruleLine(rule: CandidateRule, label: string): string {
  switch (rule.list) {
    case "appNames": return `${quote(rule.heard)} → ${label}`;
    case "aliases": return `${quote(rule.phrase)} → ${label}`;
    case "fixes": return `${quote(rule.heard)} means ${rule.intended}`;
  }
}

const REFUSAL_LINES: Partial<Record<DictionaryWriteCode, string>> = {
  unknown_take: "That take is too old to learn from.",
  not_offered: "That app was not offered for this take.",
  unresolved: "pi could not tell what that should open.",
  nothing_to_learn: "Nothing to learn from that.",
  alias_guard: "Too short to remember safely.",
  learning_off: "Learning from corrections is off.",
  refused_phrase: "pi never learns that.",
  unsafe_target: "pi cannot learn that action.",
  unknown_entry: "That entry no longer exists.",
  undo_expired: "That can no longer be undone.",
  limit_reached: "The dictionary is full. Remove some entries in Settings.",
  invalid_phrase: "That phrase cannot be learned.",
};

function refused(code: DictionaryWriteCode, revision: number): DictionaryWriteResponse {
  return { status: "refused", code, line: REFUSAL_LINES[code] ?? "pi did not learn that.", revision };
}

// ---------------------------------------------------------------------------------------------
// POST /dictionary/learn

export interface LearnDeps {
  store: DictionaryStore;
  memo: { get(takeId: string): TakeRecord | undefined };
  lane: LearnLane;
  /** Picks and confirms are app usage (FileFrecencyStore.record). */
  recordUse?: (bundleId: string) => void;
  /**
   * Bounds the regression check's replays (≤ 50 takes, two dispatches each). Separate from the resolve
   * signal: a replay cut short by it would read as "unchanged" and hide a conflict, so give it room.
   */
  regressionSignal?: AbortSignal;
}

/** The hypothesis a gesture refers to: the deciding recognizer's first-tier final, else the best first-tier one. */
function heardHypothesis(record: TakeRecord): VoiceHypothesis | undefined {
  const firstTier = record.hypotheses.filter((hypothesis) => hypothesis.role !== "secondary");
  return firstTier.find((hypothesis) => hypothesis.source === record.recognizer) ?? firstTier[0] ?? record.hypotheses[0];
}

/** The primary engine's final (DESIGN4 §6.6 #3: a confirm teaches what the primary heard). */
function primaryHypothesis(record: TakeRecord): VoiceHypothesis | undefined {
  return record.hypotheses.find((hypothesis) => hypothesis.role === "primary")
    ?? record.hypotheses.find((hypothesis) => hypothesis.role === "peer")
    ?? record.hypotheses[0];
}

/** An app-name rule for `heard` → bundle, or the guard's refusal. */
function appNamePlan(heard: string, bundleId: string, recognizer: string, source: DictionarySource, lane: LearnLane): Plan {
  // Policy first, then the guard.
  if (isRefusedPhrase(heard) || lane.blocked(heard)) return { ok: false, code: "refused_phrase" };
  if (!isFoldedPhrase(heard) || isNotAName(heard) || !hasContentWord(heard)) return { ok: false, code: "alias_guard" };
  const display = lane.appDisplay(bundleId);
  if (display === null) return { ok: false, code: "unsafe_target" };
  const owner = lane.exactApp(heard);
  const rule: CandidateRule = {
    list: "appNames", heard, bundleId, display: display ?? bundleId, recognizer,
    ...(owner && owner !== bundleId ? { shadows: owner } : {}),
  };
  return { ok: true, rule, source, label: rule.display };
}

/** An utterance alias for `text` → target, behind the alias guard. */
function aliasPlan(text: string, target: SafeTarget, recognizer: string, source: DictionarySource, lane: LearnLane): Plan {
  const phrase = utteranceCore(text);
  if (!phrase) return { ok: false, code: "alias_guard" };
  if (isRefusedPhrase(phrase) || lane.blocked(text) || lane.blocked(phrase)) return { ok: false, code: "refused_phrase" };
  if (!isFoldedPhrase(phrase)) return { ok: false, code: "invalid_phrase" };
  if (!aliasGuardPasses(phrase, lane.isCommonWord?.bind(lane))) return { ok: false, code: "alias_guard" };
  if (target.kind === "openApp" && lane.appDisplay(target.bundleId) === null) return { ok: false, code: "unsafe_target" };
  return { ok: true, rule: { list: "aliases", phrase, target, recognizer }, source, label: targetLabel(target, lane) };
}

/**
 * pick / confirm / No-I-meant: the heard open target becomes an app name, a bare utterance an alias, scoped
 * to the recognizer that heard it (DESIGN4 C8).
 */
function bindingPlan(hypothesis: VoiceHypothesis, heard: string | undefined, target: SafeTarget, source: DictionarySource, lane: LearnLane, voice = false): Plan {
  if (lane.blocked(hypothesis.text, hypothesis.locale)) return { ok: false, code: "refused_phrase" };
  const openTarget = heard ?? lane.openTarget(hypothesis.text, hypothesis.locale, voice);
  if (openTarget !== null && openTarget !== undefined && target.kind === "openApp") return appNamePlan(nameCore(openTarget), target.bundleId, hypothesis.source, source, lane);
  return aliasPlan(hypothesis.text, target, hypothesis.source, source, lane);
}

/** A take that was spoken (its hypotheses came from a voice final). */
const spoken = (record: TakeRecord): boolean => record.voiceHypotheses === true || record.inputMode === "voice";

async function resolveMeant(text: string, record: TakeRecord, lane: LearnLane, signal?: AbortSignal): Promise<SafeTarget | DictionaryWriteCode> {
  // "No, I meant X" / "nein, ich meinte X" / "nein, X" as sent by the host (the instant lane's grammar), else X itself.
  const meant = (correctionTarget(text)?.target ?? text).trim();
  if (!meant) return "unresolved";
  if (lane.blocked(text) || lane.blocked(meant)) return "refused_phrase";
  const options = { inputMode: spoken(record) ? "voice" as const : "text" as const };
  const direct = await lane.resolve(meant, options, signal);
  if (direct) return direct;
  // "No, I meant Notion": the lane resolves the open form of the name.
  const viaOpen = lane.openTarget(meant, undefined, spoken(record)) === null ? await lane.resolve(`open ${meant}`, options, signal) : null;
  return viaOpen ?? "unresolved";
}

/** A word-level diff with one changed span (DESIGN4 §6.6 #4): `from` → `to`, starting at word `start`. */
function diffSpan(heard: string, corrected: string): { from: string[]; to: string[]; start: number } {
  const a = utteranceCore(heard).split(" ").filter(Boolean);
  const b = utteranceCore(corrected).split(" ").filter(Boolean);
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length - 1;
  let endB = b.length - 1;
  while (endA >= start && endB >= start && a[endA] === b[endB]) { endA--; endB--; }
  return { from: a.slice(start, endA + 1), to: b.slice(start, endB + 1), start };
}

const MAX_FIX_WORDS = 4;

async function editPlan(request: DictionaryLearnRequest, record: TakeRecord, deps: LearnDeps, signal?: AbortSignal): Promise<Plan> {
  const { lane, store } = deps;
  const hypothesis = heardHypothesis(record);
  const corrected = request.correctedText ?? "";
  if (!hypothesis) return { ok: false, code: "nothing_to_learn" };
  if (lane.blocked(hypothesis.text) || lane.blocked(corrected)) return { ok: false, code: "refused_phrase" };
  const recognizer = hypothesis.source;
  const target = await lane.resolve(corrected, { inputMode: "text" }, signal);
  const { from, to, start } = diffSpan(hypothesis.text, corrected);
  if (!from.length && !to.length) return { ok: false, code: "nothing_to_learn" };
  // An object span (the verb unchanged) that became a known name: an app name or a fix, never a verb rewrite.
  const named = to.join(" ");
  const app = to.length ? lane.exactApp(named) : undefined;
  const term = to.length ? store.document().terms.find((entry) => foldPhrase(entry.text) === named) : undefined;
  if (start > 0 && from.length && from.length <= MAX_FIX_WORDS && to.length <= MAX_FIX_WORDS && (app || term)) {
    const heardOpen = lane.openTarget(hypothesis.text, hypothesis.locale, spoken(record));
    if (heardOpen && target?.kind === "openApp" && app === target.bundleId) return appNamePlan(heardOpen, target.bundleId, recognizer, "transcript-edit", lane);
    const intended = app ? lane.appDisplay(app) ?? named : term!.text;
    const heard = from.join(" ");
    if (!isFoldedPhrase(heard) || !isVoiceText(intended, DICTIONARY_LIMITS.textChars)) return { ok: false, code: "invalid_phrase" };
    if (isRefusedPhrase(heard) || isRefusedPhrase(intended)) return { ok: false, code: "refused_phrase" };
    if (!hasContentWord(heard)) return { ok: false, code: "alias_guard" };
    return { ok: true, rule: { list: "fixes", heard, intended, recognizer }, source: "transcript-edit", label: intended };
  }
  if (!target) return { ok: false, code: "unresolved" };
  return aliasPlan(hypothesis.text, target, recognizer, "transcript-edit", lane);
}

async function plan(request: DictionaryLearnRequest, record: TakeRecord, deps: LearnDeps, signal?: AbortSignal): Promise<Plan> {
  const { lane } = deps;
  switch (request.kind) {
    case "pick": {
      const bundleId = request.bundleId!;
      if (!record.offered.includes(bundleId)) return { ok: false, code: "not_offered" };
      const hypothesis = heardHypothesis(record);
      if (!hypothesis) return { ok: false, code: "nothing_to_learn" };
      const source: DictionarySource = record.didYouMean ? "did-you-mean" : "list-pick";
      const heard = record.heard && hypothesis.source === record.recognizer ? record.heard : undefined;
      return bindingPlan(hypothesis, heard, { kind: "openApp", bundleId }, source, lane, spoken(record));
    }
    case "confirm": {
      const acted = record.acted;
      if (!acted) return { ok: false, code: request.bundleId ? "not_offered" : "nothing_to_learn" };
      if (request.bundleId && !(acted.kind === "openApp" && acted.bundleId === request.bundleId) && !record.offered.includes(request.bundleId)) {
        return { ok: false, code: "not_offered" };
      }
      const target: SafeTarget = request.bundleId ? { kind: "openApp", bundleId: request.bundleId } : acted;
      const hypothesis = primaryHypothesis(record);
      if (!hypothesis) return { ok: false, code: "nothing_to_learn" };
      const heard = lane.openTarget(hypothesis.text, hypothesis.locale, spoken(record));
      // The primary already said the app's own name: the grammar acts on it without a rule.
      if (heard && target.kind === "openApp" && lane.exactApp(heard) === target.bundleId) return { ok: false, code: "nothing_to_learn" };
      return bindingPlan(hypothesis, heard ?? undefined, target, "confirm", lane, spoken(record));
    }
    case "no_i_meant": {
      // A take that opened a visible item (open_item) teaches nothing: no rule may point its words elsewhere.
      if (record.item) return { ok: false, code: "nothing_to_learn" };
      const target = await resolveMeant(request.correctedText ?? "", record, lane, signal);
      if (typeof target === "string") return { ok: false, code: target };
      if (record.acted && JSON.stringify(record.acted) === JSON.stringify(target)) return { ok: false, code: "nothing_to_learn" };
      const hypothesis = heardHypothesis(record);
      if (!hypothesis) return { ok: false, code: "nothing_to_learn" };
      return bindingPlan(hypothesis, undefined, target, "no-i-meant", lane, spoken(record));
    }
    case "edit":
      return editPlan(request, record, deps, signal);
    case "reject":
      return { ok: false, code: "nothing_to_learn" };
  }
}

/** The first reason (if any) the user must confirm the rule first, and its line. */
async function confirmation(request: DictionaryLearnRequest, rule: CandidateRule, label: string, deps: LearnDeps, signal?: AbortSignal): Promise<{ code: DictionaryWriteCode; line: string; conflicts?: number[] } | null> {
  if (request.confirmed === true) return null;
  const conflicts = request.regression?.length ? await regressionConflicts(rule, request.regression, deps.lane, signal) : [];
  const withConflicts = conflicts.length ? { conflicts } : {};
  if (rule.list === "appNames" && rule.shadows) {
    const shadowed = deps.lane.appDisplay(rule.shadows) ?? rule.shadows;
    return { code: "shadows_app", line: `${quote(rule.heard)} will open ${label} instead of ${shadowed}. Remember?`, ...withConflicts };
  }
  if (conflicts.length) {
    return { code: "regression", line: `This would change ${conflicts.length} earlier ${conflicts.length === 1 ? "take" : "takes"}. Remember anyway?`, conflicts };
  }
  if (rule.list === "appNames" && isCommonName(rule.heard, deps.lane)) return { code: "common_word", line: `Remember: ${quote(rule.heard)} means ${label}?` };
  if (request.kind === "no_i_meant" || request.kind === "edit") {
    return { code: "inferred", line: rule.list === "appNames" || rule.list === "aliases" ? `Remember ${ruleLine(rule, label)}?` : `Remember: ${ruleLine(rule, label)}?` };
  }
  if (deps.store.settings().learn === "ask") return { code: "ask_mode", line: `Remember ${ruleLine(rule, label)}?` };
  return null;
}

/**
 * POST /dictionary/learn. Never throws for a valid request: every outcome is a DictionaryWriteResponse
 * (`refused` with a code when nothing may be learned). `signal` bounds the lane's resolve.
 */
export async function learnFromGesture(request: DictionaryLearnRequest, deps: LearnDeps, signal?: AbortSignal): Promise<DictionaryWriteResponse> {
  const { store, memo } = deps;
  const record = memo.get(request.takeId);
  if (!record) return refused("unknown_take", store.revision());
  if (request.kind === "reject") return reject(request, record, store);
  // A pick or a confirm of an app is app usage (frecency), whatever is learned from it.
  const used = request.kind === "pick" ? request.bundleId
    : request.kind === "confirm" ? request.bundleId ?? (record.acted?.kind === "openApp" ? record.acted.bundleId : undefined) : undefined;
  if (used && record.offered.includes(used)) deps.recordUse?.(used);
  if (store.settings().learn === "off") return refused("learning_off", store.revision());
  const planned = await plan(request, record, deps, signal);
  if (!planned.ok) return refused(planned.code, store.revision());
  const { rule, source, label } = planned;
  const ask = await confirmation(request, rule, label, deps, deps.regressionSignal);
  if (ask) return { status: "needs_confirmation", code: ask.code, line: line(ask.line), revision: store.revision(), ...(ask.conflicts ? { conflicts: ask.conflicts } : {}) };
  const outcome = store.bind(ruleContent(rule), { recognizer: rule.recognizer, source });
  return written(outcome, "learned", `Learned: ${ruleLine(rule, label)}`);
}

function reject(request: DictionaryLearnRequest, record: TakeRecord, store: DictionaryStore): DictionaryWriteResponse {
  // Only the rule that decided this take can be rejected through it (no arbitrary entry ids).
  const entryId = request.entryId ?? record.learnedEntryId;
  if (!entryId) return { status: "refused", code: "nothing_to_learn", line: "Got it.", revision: store.revision() };
  if (record.learnedEntryId !== entryId) return refused("unknown_entry", store.revision());
  const list = (["appNames", "aliases", "fixes", "terms"] as const).find((candidate) => store.entry({ list: candidate, id: entryId }));
  if (!list) return refused("unknown_entry", store.revision());
  const outcome = store.reject({ list, id: entryId });
  if (!outcome.ok) return refused(outcome.code, outcome.revision);
  return {
    status: "learned", code: outcome.code ?? "rejection_recorded", entry: { list, id: entryId },
    line: outcome.code === "rule_disabled" ? "Got it. pi won’t do that again." : "Got it. Showing other matches.",
    revision: outcome.revision, ...(outcome.undoToken ? { undoToken: outcome.undoToken } : {}),
  };
}

function written(outcome: WriteOutcome, status: "learned" | "updated", text?: string): DictionaryWriteResponse {
  if (!outcome.ok) return refused(outcome.code, outcome.revision);
  return {
    status,
    ...(outcome.code ? { code: outcome.code } : {}),
    ...(outcome.ref ? { entry: outcome.ref } : {}),
    ...(text ? { line: line(text) } : {}),
    ...(outcome.undoToken ? { undoToken: outcome.undoToken } : {}),
    revision: outcome.revision,
  };
}

// ---------------------------------------------------------------------------------------------
// POST /dictionary/edit

export interface EditDeps {
  store: DictionaryStore;
  lane: LearnLane;
  /** "Forget everything" also forgets the take memo. */
  onReset?: () => void;
}

function inputContent(entry: DictionaryEntryInput, lane: LearnLane): { ok: true; content: EntryContent } | { ok: false; code: DictionaryWriteCode } {
  switch (entry.list) {
    case "terms":
      if (entry.bundleId && lane.appDisplay(entry.bundleId) === null) return { ok: false, code: "unsafe_target" };
      return {
        ok: true,
        content: { list: "terms", text: entry.text, soundsLike: entry.soundsLike ?? [], lang: entry.lang ?? "any", kind: entry.kind ?? "word", ...(entry.bundleId ? { bundleId: entry.bundleId } : {}) },
      };
    case "appNames": {
      if (lane.blocked(entry.heard)) return { ok: false, code: "refused_phrase" };
      if (isNotAName(entry.heard) || !hasContentWord(entry.heard)) return { ok: false, code: "alias_guard" };
      if (lane.appDisplay(entry.bundleId) === null) return { ok: false, code: "unsafe_target" };
      const owner = lane.exactApp(entry.heard);
      return { ok: true, content: { list: "appNames", heard: entry.heard, bundleId: entry.bundleId, display: entry.display, ...(owner && owner !== entry.bundleId ? { shadows: owner } : {}) } };
    }
    case "aliases":
      if (lane.blocked(entry.phrase)) return { ok: false, code: "refused_phrase" };
      if (!hasContentWord(entry.phrase)) return { ok: false, code: "alias_guard" };
      if (entry.target.kind === "openApp" && lane.appDisplay(entry.target.bundleId) === null) return { ok: false, code: "unsafe_target" };
      return { ok: true, content: { list: "aliases", phrase: entry.phrase, target: entry.target } };
    case "fixes":
      if (lane.blocked(entry.heard) || lane.blocked(entry.intended)) return { ok: false, code: "refused_phrase" };
      // A fix rewrites words everywhere they are heard, so it must never touch a command verb ("search" → "open",
      // "beende" → "öffne"): verb rewrites are never generalized (DESIGN4 §6.8 #6), whichever client sends them.
      if (hasCommandWord(entry.heard) || hasCommandWord(entry.intended)) return { ok: false, code: "refused_phrase" };
      if (!hasContentWord(entry.heard)) return { ok: false, code: "alias_guard" };
      return { ok: true, content: { list: "fixes", heard: entry.heard, intended: entry.intended } };
  }
}

/** Folded command verbs (EN/DE open, launch, show, switch, search, find) a fix may never rewrite; the host's Settings mirrors this list. */
const FIX_COMMAND_WORDS: ReadonlySet<string> = new Set([
  "open", "oben", "offen", "offne", "oeffne", "offnen", "oeffnen", "auf", "launch", "start", "starte", "starten", "run",
  "show", "zeig", "zeige", "zeigen", "switch", "search", "such", "suche", "suchen", "google", "find", "finde", "finden",
]);
const hasCommandWord = (text: string): boolean => foldPhrase(text).split(" ").some((word) => FIX_COMMAND_WORDS.has(word));

/** POST /dictionary/edit (Settings and the bar's Undo). Settings edits are explicit: the learn mode does not gate them. */
export function applyEdit(request: DictionaryEditRequest, deps: EditDeps): DictionaryWriteResponse {
  const { store, lane } = deps;
  switch (request.op) {
    case "upsert": {
      const checked = inputContent(request.entry, lane);
      if (!checked.ok) return refused(checked.code, store.revision());
      const content = checked.content;
      if (content.list === "appNames" && content.shadows && request.confirmed !== true) {
        const shadowed = lane.appDisplay(content.shadows) ?? content.shadows;
        return { status: "needs_confirmation", code: "shadows_app", line: line(`${quote(content.heard)} will open ${content.display} instead of ${shadowed}. Save anyway?`), revision: store.revision() };
      }
      const existing = request.entry.id ? store.entry({ list: request.entry.list, id: request.entry.id }) : undefined;
      const outcome = store.bind(content, {
        recognizer: request.entry.recognizer ?? existing?.recognizer ?? RECOGNIZERS.any,
        source: request.source ?? "manual",
        ...(request.entry.pinned !== undefined ? { pinned: request.entry.pinned } : {}),
        ...(request.entry.id ? { id: request.entry.id } : {}),
      });
      return written(outcome, "updated");
    }
    case "delete":
    case "disable":
    case "enable":
    case "pin":
    case "unpin":
      return written(store.setState({ list: request.list, id: request.id }, request.op), "updated");
    case "undo":
      return written(store.undo(request.undoToken), "updated", "Undone.");
    case "reset": {
      const outcome = store.reset();
      deps.onReset?.();
      return written(outcome, "updated", "Forgot everything pi learned.");
    }
    case "settings":
      return written(store.updateSettings(request.settings), "updated");
  }
}

/** Content-free label of a learn/edit outcome for log lines. */
export function outcomeFields(response: DictionaryWriteResponse, list?: DictionaryList): Record<string, string | number> {
  return {
    status: response.status,
    ...(response.code ? { code: response.code } : {}),
    ...(response.entry ? { list: response.entry.list } : list ? { list } : {}),
    ...(response.conflicts ? { conflicts: response.conflicts.length } : {}),
  };
}
