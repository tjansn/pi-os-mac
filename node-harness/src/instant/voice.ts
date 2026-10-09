import { classifyUtterance, isUnclearShortUtterance, utteranceWords } from "../agent/routing/heuristics.js";
import { foldPhrase, mentionsDeletionVocabulary, type DictionaryEntryRef, type TakeNearMiss } from "../contracts/dictionary.js";
import {
  accepts, INSTANT_LIMITS, isVoiceText, RECOGNIZERS,
  type InstantRequest, type VoiceHypothesis, type VoiceMeta, type VoiceVia,
} from "../contracts/instant.js";
import { SPOKEN, spokenHead, type AppMatch, type AppMatcher } from "./apps.js";
import { isDeletionRequest } from "./grammar/policy.js";
import { spokenCore, type Normalized } from "./normalize.js";
import { editSimilarity, phoneticKeys, phoneticSimilarity } from "./phonetic.js";
import type { InstantBody, Parsed } from "./types.js";
import type { VisibleMatch } from "./visible.js";

/**
 * The voice decision pipeline's pure parts (DESIGN4 §4.5, §5.3, §5.4, §6.3): how the hypotheses of one
 * push-to-talk final are arbitrated, the did-you-mean card copy, the check gate, "No, I meant X", the
 * secondary-engine consistency gate and the take memo's near miss. The dispatcher runs each hypothesis
 * through the instant lane (policy, learned alias, learned app name, grammar + spoken matcher, learned
 * fixes) and hands the outcomes here; nothing here does I/O or logs (hypothesis texts are user content).
 *
 * Order for a voice final (§6.3, policy first and last):
 *   POLICY on every hypothesis's original words: a refusal in the first tier refuses the take; deletion
 *     vocabulary anywhere turns the alternatives (secondaries) off for the take
 *   1–4 per first-tier hypothesis: exact alias → exact learned app name (open form) → grammar + spoken
 *     matcher (open forms: the take's visible items first, visible.ts) → learned fixes (only turning a miss
 *     into a hit, policy again)
 *   5 arbitration: one actionable result, or several that agree, act (a Phase A peer below
 *     `VOICE.peerConfidence` needs one Return); acts that disagree become "Did you mean …?" (apps) or a
 *     one-Return confirm of the lead; only then the secondary tier (consistent literal app acts at once,
 *     bare names and anything else behind one Return)
 *   6 open-form miss → did-you-mean (≥ 0.66, ≤ 3; visible items first); an unknown spoken domain → one-Return
 *     confirm; a strong open form that missed everything → a Spotlight did-you-mean (hosts with visible items)
 *   7 check gate (`low_confidence`, hosts that accept "check") → else fallthrough with the near miss
 * Gated kinds (`confirm`, `check`) are used only when the request declared them; without `accept` the
 * decision vocabulary is today's.
 */

/** Voice thresholds (DESIGN4 §4.5); recalibrated on the voice journal (N5), not here. */
export const VOICE = Object.freeze({
  /** A Phase A peer acts at once only at or above this mean confidence (absent counts as below). */
  peerConfidence: 0.4,
  /** Check gate: the sent hypothesis's lowest word confidence below this… */
  checkMinConfidence: 0.2,
  /** …on an utterance of at most this many words (routing/heuristics SHORT_SPOKEN_WORDS). */
  checkMaxWords: 8,
  /** Check gate: first-tier hypotheses that share fewer than this fraction of their words disagree… */
  checkWordOverlap: 0.5,
  /**
   * …which counts only when the sent hypothesis's mean confidence is below this. The en-US and de-DE peers
   * of a Phase A take garble each other's language on almost every utterance, so disagreement alone held 15
   * correctly heard agent questions (of 78) for a Return on the clean replay, while every one of them had a
   * mean confidence ≥ 0.5 (integration probe on test/fixtures/voice; recalibrate on the journal, N5).
   */
  checkDisagreeConfidence: 0.5,
  /** Secondary consistency gate: the alternative's app scores at least this on the primary's own target… */
  consistentFloor: 0.45,
  /** …and within this of the primary's top sound-alike. */
  consistentWindow: 0.08,
  /** Or one of the primary's last (≤ 3) words sounds like the alternative's name at least this much. */
  tailSound: 0.6,
  tailWords: 3,
  /** Rows of a did-you-mean card. */
  maxDidYouMean: 3,
  /** Other hypotheses and candidates kept in the take memo's near miss. */
  nearMissItems: 3,
});

// ---------------------------------------------------------------------------------------------
// Lane outcomes

/** Policy the original words triggered (`refuse` also covers "delete <installed app>"). */
export type LanePolicy = "refuse" | "deictic" | "compound" | "delete_target";

/** What the instant lane decided for one hypothesis, plus what arbitration needs to know about it. */
export interface LaneOutcome {
  hypothesis: VoiceHypothesis;
  /** The host's pick (`request.text`), or the first first-tier hypothesis when the text is none of them. */
  sent: boolean;
  /** First tier: the primary engine, or a Phase A peer language. */
  firstTier: boolean;
  n: Normalized;
  parsed: Parsed | null;
  german: boolean;
  policy?: LanePolicy;
  /** The words hold deletion vocabulary (EN/DE): learned rules never apply and alternatives are off. */
  deletion: boolean;
  /** The lane's decision; null when nothing matched. */
  body: InstantBody | null;
  via?: VoiceVia;
  /** The open target as heard (spokenHead, folded, ≤ 80), when an open form decided or nearly did. */
  heard?: string;
  /** The learned dictionary rule that decided. */
  learned?: DictionaryEntryRef;
  /** An app act decided by a name said alone (never immediate from a secondary). */
  bare?: boolean;
  /** An app act on literal evidence (exact name, alias, whole words, a learned name), not on sound. */
  literal?: boolean;
  /** The app an open-app act opens, as a match (did-you-mean rows when peers disagree). */
  acted?: AppMatch;
  /** The lane's open form did not act: these are its "Did you mean …?" candidates (≤ 3). */
  offers: readonly AppMatch[];
  /**
   * Visible items the open form offers (design C: an exact item next to an exact app, several exact items,
   * or sound-alikes): did-you-mean rows that go before the app offers. Never learned.
   */
  visibleOffers?: readonly VisibleMatch[];
  /** Ranked candidates of the open target (the near miss). */
  matches: readonly AppMatch[];
}

/** A decision that ends the take without the agent: an act, an answer, or a non-did-you-mean list (files). */
export function isActionable(body: InstantBody | null): boolean {
  if (!body) return false;
  if (body.decision === "act" || body.decision === "answer") return true;
  return body.decision === "list" && body.voice?.didYouMean !== true;
}

/** Content-free identity of a decision, to tell agreeing hypotheses from disagreeing ones. */
export function decisionSignature(body: InstantBody): string {
  switch (body.decision) {
    case "act": {
      const action = body.action;
      if (action.type === "openApp") return `app:${action.bundleId}`;
      if (action.type === "openURL") return `url:${action.url.replace(/\/$/, "")}`;
      if (action.type === "system") return `system:${action.op}:${String(action.value ?? "")}`;
      // A visible item (open_item): two hypotheses agree only on the same host token.
      if (action.type === "openFile") return `file:${action.token}`;
      return `act:${action.type}`;
    }
    case "answer": return `answer:${body.intent}:${body.title}`;
    case "list": return `list:${body.intent}`;
    case "refuse": return "refuse";
    case "fallthrough": return `fallthrough:${body.reason}`;
  }
}

/** EN/DE deletion vocabulary or a deletion request in the words (the grammar's refusal runs separately). */
export function mentionsDeletion(n: Normalized): boolean {
  return mentionsDeletionVocabulary(n.raw) || isDeletionRequest(n);
}

// ---------------------------------------------------------------------------------------------
// Hypotheses of a request

export interface VoiceTake {
  hypotheses: readonly VoiceHypothesis[];
  /** Index of the host's pick (`request.text`) among `hypotheses`. */
  sent: number;
  /** Indices of the first tier (primary and peers), best first. */
  firstTier: readonly number[];
  /** Indices of the secondaries, best first. */
  secondary: readonly number[];
  /** The request carried no hypotheses (an older host): its text is the only, primary hypothesis. */
  legacy: boolean;
}

/**
 * The take's hypotheses: the request's (voice finals of new hosts) or its text as the only primary one.
 * The first tier is every primary and peer; when a host sent only secondaries, the hypothesis it picked
 * (or its text) stands in as the primary, so a pick is never gated harder than an older host's text.
 */
export function voiceTake(request: Pick<InstantRequest, "text" | "hypotheses">): VoiceTake {
  const given = request.hypotheses?.length ? request.hypotheses : undefined;
  if (!given) return { hypotheses: [{ text: request.text, source: RECOGNIZERS.any, role: "primary" }], sent: 0, firstTier: [0], secondary: [], legacy: true };
  const hypotheses = [...given];
  let firstTier = hypotheses.flatMap((hypothesis, index) => (hypothesis.role === "secondary" ? [] : [index]));
  const same = (hypothesis: VoiceHypothesis) => hypothesis.text === request.text || hypothesis.text.trim() === request.text.trim();
  if (!firstTier.length) {
    const picked = hypotheses.findIndex(same);
    if (picked >= 0) hypotheses[picked] = { ...hypotheses[picked]!, role: "primary" };
    else if (isVoiceText(request.text)) hypotheses.unshift({ text: request.text, source: RECOGNIZERS.any, role: "primary" });
    else hypotheses[0] = { ...hypotheses[0]!, role: "primary" };
    firstTier = [Math.max(0, picked)];
  }
  const sent = firstTier.find((index) => same(hypotheses[index]!)) ?? firstTier[0]!;
  const secondary = hypotheses.flatMap((hypothesis, index) => (firstTier.includes(index) ? [] : [index]));
  return { hypotheses, sent, firstTier, secondary, legacy: false };
}

// ---------------------------------------------------------------------------------------------
// "No, I meant X" / "nein, ich meinte X" / "nein, X"

const END = "(?=[\\s,.!:;—–-]|$)";
const CORRECTION = new RegExp(
  `^(?:no|nope|nah|nein|nee|nö|noe)${END}[\\s,.!:;—–-]*`
    + `((?:i|ich)\\s+(?:meant|mean|said|wanted|meinte|meine|sagte|wollte|hab(?:e)?\\s+(?:gemeint|gesagt))${END}[\\s,.:;—–-]*)?`
    + `(?:(?:actually|eigentlich|doch|natürlich|natuerlich)${END}[\\s,.:;—–-]*)?`
    + "(.*?)[\\s.!?…]*$",
  "iu",
);

/** A correction's X; `explicit` when said as "I meant X" / "ich meinte X" (not just "nein, X"). */
export interface Correction { target: string; explicit: boolean }

/**
 * The X of a spoken or typed correction ("No, I meant Notion", "nein, ich meinte Notion", "nein, Notion"),
 * or null. The dispatcher treats it as a correction only right after an act (the take memo's latest act
 * within 2 minutes); X then goes through the lane like any request, and nothing is learned here. X is at
 * most 6 words ("nein, X": at most 4).
 */
export function correctionTarget(text: string): Correction | null {
  const match = CORRECTION.exec(text.normalize("NFC").trim());
  const target = match?.[2]?.trim().replace(/^["“„'‚]+|["”“'‘]+$/g, "").trim();
  if (!target || target.length > 120) return null;
  const explicit = match?.[1] !== undefined;
  if (target.split(/\s+/).length > (explicit ? 6 : 4)) return null;
  return { target, explicit };
}

// ---------------------------------------------------------------------------------------------
// Secondary consistency gate (r3/mapping consistentAlternative)

export interface FirstTierView { parsed: Parsed | null; n: Normalized; german: boolean }

/**
 * Whether a secondary's app is a re-hearing of what the first tier said, not a different request: the app
 * ranks near the top of a first-tier hypothesis's own spoken candidates (≥ 0.45 and within 0.08 of its
 * top sound-alike: "grave" → Brave), or, when that hypothesis is a bare utterance or did not parse, one
 * of its last words sounds like the alternative's name ("noisyon" → Notion). Without this, n-best invents
 * commands ("open August" → alternative "open the podcast").
 */
export function consistentAlternative(matcher: AppMatcher | null, firstTier: readonly FirstTierView[], bundleId: string, altTarget: string, german: boolean): boolean {
  if (!matcher) return false;
  for (const primary of firstTier) {
    if (primary.parsed?.kind === "open") {
      const candidates = matcher.matchSpoken(primary.parsed.target, { german: german || primary.german, limit: 8 });
      const top = candidates[0]?.score ?? 0;
      const mine = candidates.find((candidate) => candidate.app.bundleId === bundleId)?.score ?? 0;
      if (mine >= Math.max(VOICE.consistentFloor, top - VOICE.consistentWindow)) return true;
      if (primary.parsed.strength !== "bare") continue;
    } else if (primary.parsed && primary.parsed.kind !== "fallthrough") {
      continue;
    }
    if (tailSoundsLike(primary.n, altTarget, german || primary.german)) return true;
  }
  return false;
}

function tailSoundsLike(n: Normalized, altTarget: string, german: boolean): boolean {
  const heard = spokenHead(altTarget).replace(/ /g, "");
  if (heard.length < 3) return false;
  const keys = phoneticKeys(heard);
  const words = foldPhrase(spokenCore(n.lower)).split(" ").filter(Boolean);
  for (let k = 1; k <= Math.min(VOICE.tailWords, words.length); k++) {
    const tail = words.slice(-k).join("");
    if (tail.length < 3) continue;
    if (0.5 * editSimilarity(tail, heard) + 0.5 * phoneticSimilarity(phoneticKeys(tail), keys, german) >= VOICE.tailSound) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// Did you mean (§5.3)

/** "Did you mean Pages?" for one row, "Did you mean…" for two or three. */
export function didYouMeanTitle(labels: readonly string[]): string {
  return labels.length === 1 ? `Did you mean ${labels[0]}?` : "Did you mean…";
}

/** The name a spoken row and title show: the match's label ("Pages"), else the app's name. */
export function spokenLabel(match: AppMatch): string {
  return match.label?.trim() || match.app.name;
}

/** First-tier offers merged: the best score per app, best first, within the offer window of the best, ≤ 3. */
export function mergeOffers(lists: readonly (readonly AppMatch[])[]): AppMatch[] {
  const best = new Map<string, AppMatch>();
  for (const list of lists) for (const match of list) {
    const previous = best.get(match.app.bundleId);
    if (!previous || match.rank > previous.rank) best.set(match.app.bundleId, match);
  }
  const ranked = [...best.values()].sort((a, b) => b.rank - a.rank || a.app.name.length - b.app.name.length);
  const top = ranked[0]?.score ?? 0;
  return ranked.filter((match) => match.score >= top - SPOKEN.offerWindow).slice(0, VOICE.maxDidYouMean);
}

// ---------------------------------------------------------------------------------------------
// Check gate (§4.5 step 5)

/** Folded word sets of two texts share fewer than half their words (of the longer one). */
export function wordsDisagree(a: string, b: string): boolean {
  const left = new Set(foldPhrase(a).split(" ").filter(Boolean));
  const right = new Set(foldPhrase(b).split(" ").filter(Boolean));
  if (!left.size || !right.size) return false;
  let shared = 0;
  for (const word of left) if (right.has(word)) shared++;
  return shared / Math.max(left.size, right.size) < VOICE.checkWordOverlap;
}

/**
 * "Did I hear that right?" instead of the agent: only for hosts that accept `check`, only on a miss, for
 * an utterance of ≤ 8 words with at least one doubt signal: the sent hypothesis's lowest word confidence
 * < 0.2, the heuristic router cannot place it (intent `other` at ≤ 0.3), or the first-tier hypotheses
 * share fewer than half their words while the sent one's mean confidence is below 0.5 (an unknown
 * confidence never counts as low here).
 */
export function checkGate(request: Pick<InstantRequest, "accept">, sent: VoiceHypothesis, firstTier: readonly VoiceHypothesis[]): boolean {
  if (!accepts(request, "check")) return false;
  const words = utteranceWords(sent.text);
  if (words < 1 || words > VOICE.checkMaxWords) return false;
  if (sent.minConfidence !== undefined && sent.minConfidence < VOICE.checkMinConfidence) return true;
  if (isUnclearShortUtterance(words, classifyUtterance(sent.text))) return true;
  if (!(sent.confidence !== undefined && sent.confidence < VOICE.checkDisagreeConfidence)) return false;
  return firstTier.some((a, i) => firstTier.some((b, j) => j > i && wordsDisagree(a.text, b.text)));
}

// ---------------------------------------------------------------------------------------------
// Voice meta and the near miss

/** A `voice` meta without empty members (heard must be wire-valid text, ≤ 80). */
export function voiceMeta(meta: VoiceMeta): VoiceMeta | undefined {
  const out: VoiceMeta = {};
  const heard = meta.heard?.slice(0, INSTANT_LIMITS.maxHeardChars).trim();
  if (heard && isVoiceText(heard, INSTANT_LIMITS.maxHeardChars)) out.heard = heard;
  if (meta.source) out.source = meta.source;
  if (meta.via) out.via = meta.via;
  if (meta.didYouMean) out.didYouMean = true;
  if (meta.check) out.check = true;
  if (meta.learnedEntryId) out.learnedEntryId = meta.learnedEntryId;
  if (meta.correctsTakeId) out.correctsTakeId = meta.correctsTakeId;
  return Object.keys(out).length ? out : undefined;
}

/**
 * What /invoke may tell the agent about a missed take (DESIGN4 §5.5): the heard target, the top three
 * candidates (short labels, scores 0..1), and up to three other hypotheses — never the sent text, and none
 * at all when any hypothesis holds deletion vocabulary. Undefined when there is nothing to tell.
 */
export function nearMissOf(heard: string | undefined, matches: readonly AppMatch[], others: readonly string[], sentText: string): TakeNearMiss | undefined {
  const candidates = matches.slice(0, VOICE.nearMissItems).map((match) => ({
    bundleId: match.app.bundleId,
    display: spokenLabel(match).slice(0, INSTANT_LIMITS.maxHeardChars),
    score: Math.round(Math.min(1, Math.max(0, match.score)) * 100) / 100,
  }));
  const seen = new Set([sentText.trim()]);
  const rest: string[] = [];
  for (const text of others) {
    const trimmed = text.trim();
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    rest.push(trimmed);
    if (rest.length >= VOICE.nearMissItems) break;
  }
  const shown = heard?.slice(0, INSTANT_LIMITS.maxHeardChars).trim() ?? "";
  if (!shown && !candidates.length && !rest.length) return undefined;
  return { heard: shown, candidates, others: rest };
}
