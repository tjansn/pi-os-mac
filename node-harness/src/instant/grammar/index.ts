import { spokenCore, type Normalized } from "../normalize.js";
import type { MatchContext, Parsed } from "../types.js";
import { matchFileSearch } from "./files.js";
import { matchBareUrl, matchOpen, matchSystem, matchWeb } from "./launch.js";
import { matchBase, matchCalc, matchConversion } from "./math.js";
import { deletionTarget, isBareEdit, isCompound, isDeictic, isDeletionRequest } from "./policy.js";
import { matchDate, matchTime } from "./time.js";

export interface ParseOptions {
  /**
   * Push-to-talk transcript (DESIGN4 §5.1): adds a second parse of the spoken command core, the spoken
   * open forms (wrappers, German verb-final and particles, weak verbs) and, last, a bare app name. Typed
   * text keeps today's grammar.
   */
  voice?: boolean;
}

/**
 * Anchored instant grammar. Precedence (first match wins):
 *   1. deletion / trash → refuse (before anything else, in every phase)
 *   2. bare edits ("delete it", "lösche alles") and deixis → fallthrough "deictic";
 *      compound → fallthrough "compound"; "delete <bare object>" → app check
 *   3. system · time · date · base · unit/currency · calc · web · files · open/URL
 * Voice (`options.voice`): the raw text first; when that finds nothing (or only a compound, which "go
 * ahead and open Pages" is not), the spoken core ("okay, can you turn it up a bit" → "turn it up") is
 * parsed again with every policy check; a name said alone is the last resort. A refusal of the core
 * always wins, and a deletion target is named by the core ("delete Pages for me" → "pages").
 * Pure and synchronous (microseconds); returns null when nothing matches.
 */
export function parseInstant(n: Normalized, ctx: MatchContext, options: ParseOptions = {}): Parsed | null {
  if (!n.lower) return null;
  if (!options.voice) return parseCore(n, ctx, false);
  const first = parseCore(n, ctx, true);
  if (first?.kind === "refuse") return first;
  const core = spokenCore(n.lower);
  const second = core && core !== n.lower ? parseCore({ ...n, text: core, lower: core, numeric: spokenCore(n.numeric) }, ctx, true) : null;
  // A deletion stays refused however it is wrapped ("um, delete this file"), and "delete Pages for me"
  // names its object without the wrapper, so an installed app is recognized.
  if (second?.kind === "refuse") return second;
  if (first?.kind === "delete_target") return second?.kind === "delete_target" ? second : first;
  if (first && !(first.kind === "fallthrough" && first.reason === "compound")) return first;
  if (second && second.kind !== "fallthrough") return second;
  // A fallthrough of the core ("okay, delete it" → a bare edit, deictic) is policy, never a name said alone.
  return first ?? second ?? matchOpen(n, { voice: true, bare: true });
}

function parseCore(n: Normalized, ctx: MatchContext, voice: boolean): Parsed | null {
  if (!n.lower) return null;
  if (isDeletionRequest(n)) return { kind: "refuse" };
  if (isBareEdit(n) || isDeictic(n)) return { kind: "fallthrough", reason: "deictic" };
  if (isCompound(n)) return { kind: "fallthrough", reason: "compound" };
  const target = deletionTarget(n);
  if (target) return { kind: "delete_target", target };
  return matchSystem(n)
    ?? matchTime(n)
    ?? matchDate(n)
    ?? matchBase(n)
    ?? matchConversion(n)
    ?? matchCalc(n)
    ?? matchWeb(n, ctx)
    ?? matchFileSearch(n, ctx)
    ?? matchOpen(n, { voice })
    ?? matchBareUrl(n);
}

export { DELETION_REFUSAL_MESSAGE, deletionTarget, isBareEdit, isCompound, isDeictic, isDeletionRequest } from "./policy.js";
export { CURRENCY_WORDS, UNIT_WORDS } from "./math.js";
export {
  DEFAULT_WEB_SEARCH, expandTemplate, isKnownSpokenHost, KNOWN_SPOKEN_DOMAINS, openStrength, SITE_HOME, toWebUrl, VOLUME_STEP,
  type OpenParse, type OpenStrength,
} from "./launch.js";
