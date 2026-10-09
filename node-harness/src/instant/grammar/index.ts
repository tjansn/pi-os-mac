import type { Normalized } from "../normalize.js";
import type { MatchContext, Parsed } from "../types.js";
import { matchFileSearch } from "./files.js";
import { matchBareUrl, matchOpen, matchSystem, matchWeb } from "./launch.js";
import { matchBase, matchCalc, matchConversion } from "./math.js";
import { deletionTarget, isBareEdit, isCompound, isDeictic, isDeletionRequest } from "./policy.js";
import { matchDate, matchTime } from "./time.js";

/**
 * Anchored instant grammar. Precedence (first match wins):
 *   1. deletion / trash → refuse (before anything else, in every phase)
 *   2. bare edits ("delete it", "lösche alles") and deixis → fallthrough "deictic";
 *      compound → fallthrough "compound"; "delete <bare object>" → app check
 *   3. system · time · date · base · unit/currency · calc · web · files · open/URL
 * Pure and synchronous (microseconds); returns null when nothing matches.
 */
export function parseInstant(n: Normalized, ctx: MatchContext): Parsed | null {
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
    ?? matchOpen(n)
    ?? matchBareUrl(n);
}

export { DELETION_REFUSAL_MESSAGE, deletionTarget, isBareEdit, isCompound, isDeictic, isDeletionRequest } from "./policy.js";
export { CURRENCY_WORDS, UNIT_WORDS } from "./math.js";
export { DEFAULT_WEB_SEARCH, expandTemplate, SITE_HOME, toWebUrl, VOLUME_STEP } from "./launch.js";
