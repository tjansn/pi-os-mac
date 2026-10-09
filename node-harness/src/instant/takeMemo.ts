import type { HostAction } from "../contracts/actions.js";
import { bindingToHostAction, type CardSpec } from "../contracts/cards.js";
import {
  foldPhrase, parseSafeTarget, TAKE_MEMO_LIMITS,
  type SafeTarget, type TakeMemo, type TakeMemoRecord, type TakeNearMiss,
} from "../contracts/dictionary.js";
import { INSTANT_LIMITS, isVoiceText, RECOGNIZERS, type InstantRequest, type InstantResponse, type VoiceHypothesis } from "../contracts/instant.js";

/**
 * The take memo (DESIGN4 §6.2): what POST /instant decided for the last 20 takes, for 2 minutes, in
 * memory only. POST /dictionary/learn accepts only a take that is here, `pick`/`confirm` only a bundle
 * id the take offered or acted on, and "No, I meant X" finds the act it corrects (`latestActed`).
 * `/invoke` may read a take's near miss for the agent note (DESIGN4 §5.5).
 *
 * Everything in a record is user content (heard texts, targets): it is never logged and never written
 * to disk. A later final of the same take (Phase B's two-step final, the check state's edited resend)
 * merges into the record: the first voice final's hypotheses and the earliest `at` stay, `offered`
 * accumulates, everything else is the latest final's.
 */

/** A memo record plus what the server derives beside the frozen contract fields. */
export interface TakeRecord extends TakeMemoRecord {
  /** The take's list was a "Did you mean …?" card (`voice.didYouMean`): a pick learns with source `did-you-mean`. */
  didYouMean?: boolean;
  /** `hypotheses` came from a voice final (kept over later typed resends of the take). */
  voiceHypotheses?: boolean;
  /**
   * The take's act opened a file or folder (`open_item`: a visible item): it never teaches a rule ("No, I
   * meant X" acts without naming it, `no_i_meant` against it is refused).
   */
  item?: boolean;
}

/** Bounded so a long-lived take cannot grow without limit (lists show ≤ 8 rows). */
const MAX_OFFERED = 32;

export interface TakeMemoOptions {
  maxTakes?: number;
  ttlMs?: number;
  /** Epoch ms (default Date.now); `get`/`latestActed` callers may pass their own `now`. */
  clock?: () => number;
}

export class InMemoryTakeMemo implements TakeMemo {
  private readonly takes = new Map<string, TakeRecord>();
  private readonly maxTakes: number;
  private readonly ttlMs: number;
  private readonly clock: () => number;

  constructor(options: TakeMemoOptions = {}) {
    this.maxTakes = options.maxTakes ?? TAKE_MEMO_LIMITS.maxTakes;
    this.ttlMs = options.ttlMs ?? TAKE_MEMO_LIMITS.ttlMs;
    this.clock = options.clock ?? (() => Date.now());
  }

  get size(): number {
    return this.takes.size;
  }

  remember(record: TakeMemoRecord): void {
    const previous = this.takes.get(record.takeId);
    const next = previous ? mergeTake(previous, record) : copyTake(record);
    // Newest last: Map order is the eviction order.
    this.takes.delete(record.takeId);
    this.takes.set(record.takeId, next);
    while (this.takes.size > this.maxTakes) {
      const oldest = this.takes.keys().next().value;
      if (oldest === undefined) break;
      this.takes.delete(oldest);
    }
  }

  get(takeId: string, now: number = this.clock()): TakeRecord | undefined {
    const record = this.takes.get(takeId);
    if (!record) return undefined;
    if (this.expired(record, now)) {
      this.takes.delete(takeId);
      return undefined;
    }
    return record;
  }

  latestActed(now: number = this.clock()): TakeRecord | undefined {
    const records = [...this.takes.values()];
    for (let index = records.length - 1; index >= 0; index--) {
      const record = records[index]!;
      if (record.decision === "act" && !this.expired(record, now)) return record;
    }
    return undefined;
  }

  forget(takeId: string): void {
    this.takes.delete(takeId);
  }

  /** "Forget everything" (Settings → Dictionary) also forgets the takes. */
  clear(): void {
    this.takes.clear();
  }

  private expired(record: TakeMemoRecord, now: number): boolean {
    return now - record.at > this.ttlMs || now < record.at - this.ttlMs;
  }
}

function copyTake(record: TakeMemoRecord): TakeRecord {
  const copy = { ...record, hypotheses: [...record.hypotheses], offered: [...record.offered] } as TakeRecord;
  return copy;
}

function mergeTake(previous: TakeRecord, record: TakeMemoRecord): TakeRecord {
  const next = copyTake(record);
  const incomingVoice = (record as TakeRecord).voiceHypotheses === true || (record.inputMode === "voice" && record.hypotheses.length > 0);
  // The first voice final's hypotheses stay: an edited resend (typed) or a second final must not replace what was heard.
  if (previous.hypotheses.length > 0 && (previous.voiceHypotheses || !incomingVoice)) {
    next.hypotheses = previous.hypotheses;
    next.voiceHypotheses = previous.voiceHypotheses;
  }
  next.at = Math.min(previous.at, record.at);
  next.offered = [...new Set([...previous.offered, ...record.offered])].slice(-MAX_OFFERED);
  // A take that opened a file or folder once stays one (it never teaches a rule).
  if (previous.item) next.item = true;
  return next;
}

// ---------------------------------------------------------------------------------------------
// Records from /instant finals

/**
 * What the instant lane knows about a decision beyond the wire response (N2's voice pipeline): the folded
 * open target as heard, the deciding recognizer, the near miss for /invoke and extra offered bundle ids.
 * Attached to the response object in a WeakMap, so it never reaches JSON.stringify or the host.
 */
export interface TakeDetails {
  heard?: string;
  recognizer?: string;
  nearMiss?: TakeNearMiss;
  offered?: readonly string[];
}

const DETAILS = new WeakMap<object, TakeDetails>();

/** The dispatcher attaches details to the response it returns (before the server copies it). */
export function attachTakeDetails<T extends object>(response: T, details: TakeDetails): T {
  DETAILS.set(response, details);
  return response;
}

export function takeDetailsOf(response: object): TakeDetails | undefined {
  return DETAILS.get(response);
}

/** The closed target an `act` performs, or undefined (an action a learned rule could never express). */
export function safeTargetOf(action: HostAction): SafeTarget | undefined {
  switch (action.type) {
    case "openApp": return parseSafeTarget({ kind: "openApp", bundleId: action.bundleId }) ?? undefined;
    case "openURL": return parseSafeTarget({ kind: "openURL", url: action.url }) ?? undefined;
    case "system": return parseSafeTarget({ kind: "system", op: action.op, value: action.value }) ?? undefined;
    default: return undefined;
  }
}

/** Bundle ids of a list card's app rows (their primary binding), in row order. */
export function offeredBundleIds(card: CardSpec | undefined): string[] {
  if (!card) return [];
  const out: string[] = [];
  for (const element of Object.values(card.elements)) {
    if (element.type !== "Item" || !element.on?.primary) continue;
    const action = bindingToHostAction(element.on.primary);
    if (action?.type === "openApp" && !out.includes(action.bundleId)) out.push(action.bundleId);
  }
  return out;
}

/** The request text as the take's only hypothesis (typed takes, voice finals from hosts that send none). */
function textHypothesis(text: string): VoiceHypothesis[] {
  return isVoiceText(text, INSTANT_LIMITS.maxHypothesisChars) ? [{ text, source: RECOGNIZERS.any, role: "primary" }] : [];
}

/**
 * The memo record for a `final` with a `takeId` (undefined otherwise), from the request, the response the
 * host receives and the lane's optional details. The recognizer is the one that decided: the details',
 * then `voice.source`, then the voice hypothesis whose text the host picked, else `any`.
 */
export function takeRecordFor(request: InstantRequest, response: InstantResponse, at: number, details: TakeDetails = {}): TakeRecord | undefined {
  if (request.phase !== "final" || !request.takeId) return undefined;
  const inputMode = request.inputMode ?? "text";
  const voiceHypotheses = inputMode === "voice" && (request.hypotheses?.length ?? 0) > 0;
  const hypotheses = voiceHypotheses ? [...request.hypotheses!] : textHypothesis(request.text);
  const meta = response.decision === "act" || response.decision === "list" || response.decision === "fallthrough" ? response.voice : undefined;
  const picked = voiceHypotheses ? hypotheses.find((hypothesis) => hypothesis.text === request.text) ?? hypotheses[0] : undefined;
  const recognizer = details.recognizer ?? meta?.source ?? picked?.source ?? RECOGNIZERS.any;
  const heard = details.heard ?? (meta?.heard ? foldPhrase(meta.heard) : undefined);
  const offered: string[] = [];
  let acted: SafeTarget | undefined;
  if (response.decision === "list") offered.push(...offeredBundleIds(response.card));
  if (response.decision === "act") {
    acted = safeTargetOf(response.action);
    if (response.action.type === "openApp") offered.push(response.action.bundleId);
    // An app act's card rows (the app, then its close sound-alikes) are what the host shows after "Not this";
    // a pick among them teaches against this take (DESIGN4 §6.6 #6).
    for (const bundleId of offeredBundleIds(response.card)) if (!offered.includes(bundleId)) offered.push(bundleId);
  }
  for (const bundleId of details.offered ?? []) if (!offered.includes(bundleId)) offered.push(bundleId);
  return {
    takeId: request.takeId,
    at,
    inputMode,
    hypotheses,
    voiceHypotheses,
    decision: response.decision,
    ...(response.decision === "fallthrough" ? { reason: response.reason } : {}),
    ...(meta?.via ? { via: meta.via } : {}),
    recognizer,
    ...(heard ? { heard } : {}),
    offered: offered.slice(0, MAX_OFFERED),
    ...(acted ? { acted } : {}),
    ...(meta?.learnedEntryId ? { learnedEntryId: meta.learnedEntryId } : {}),
    ...(details.nearMiss ? { nearMiss: details.nearMiss } : {}),
    ...(response.decision === "list" && meta?.didYouMean ? { didYouMean: true } : {}),
    ...(response.decision === "act" && (response.intent === "open_item" || response.action.type === "openFile") ? { item: true } : {}),
  };
}
