import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import type { ClassifierAnswer } from "@earendil-works/pi-ai";
import { LAYA_MAX_LINE_BYTES } from "../src/classifier/laya.js";
import { TIERS } from "../src/contracts/instant.js";
import {
  LAYA_INTENT_LABELS, LAYA_INTENT_TO_AGENT_INTENT, LAYA_TIER_LEVELS, LAYA_TIER_TO_TIER, layaResultToHints,
  normalizeUtterance, parseLayaIntentResult, PI_OS_INTENT_QUESTIONS, piAnswersToHints,
} from "../src/classifier/questions.js";

const AGENT_INTENTS = ["calculate", "search_computer", "open_launch", "answer", "write", "act_in_app", "browse_web", "code", "other"];
const sidecarSource = readFileSync(join(import.meta.dirname, "..", "..", "sidecars", "laya", "laya_intent_sidecar.py"), "utf8");

function sample(label = "calculate", tier = "little"): Record<string, unknown> {
  return {
    advisory: true,
    questions: "pi-os-intent-v1",
    intent: { label, p: 0.9909, probs: { [label]: 0.9909, agent_task: 0.0009 } },
    tier: { label: tier, p: 0.8447, expected: 0.9777, probs: { none: 0.0919, [tier]: 0.8447 } },
    screen: { p: 0.0631 },
    surface: { label: "none", p: 0.9838, probs: { browser: 0.0073, native_app: 0.0089, none: 0.9838 } },
    usage: { input_tokens: 303, state_tokens: 13 },
  };
}

test("every Laya label maps into the shared AgentIntent/Tier vocabulary", () => {
  for (const label of LAYA_INTENT_LABELS) assert.ok(AGENT_INTENTS.includes(LAYA_INTENT_TO_AGENT_INTENT[label]), label);
  for (const level of LAYA_TIER_LEVELS) assert.ok(TIERS.includes(LAYA_TIER_TO_TIER[level]), level);
  assert.equal(LAYA_INTENT_TO_AGENT_INTENT.calculate, "calculate");
  assert.equal(LAYA_INTENT_TO_AGENT_INTENT.convert, "calculate");
  assert.equal(LAYA_INTENT_TO_AGENT_INTENT.file_search, "search_computer");
  assert.equal(LAYA_INTENT_TO_AGENT_INTENT.open_url, "open_launch");
  assert.equal(LAYA_INTENT_TO_AGENT_INTENT.dictation, "write");
  // A setting falling through to the agent must not look like act_in_app (that would request a screenshot).
  assert.equal(LAYA_INTENT_TO_AGENT_INTENT.system_toggle, "other");
  assert.deepEqual(LAYA_TIER_LEVELS.map((level) => LAYA_TIER_TO_TIER[level]), ["instant", "quick", "standard", "deep"]);
});

test("the Python sidecar and the Node mapping agree on labels, levels and the question set", () => {
  const ids = [...sidecarSource.matchAll(/"[a-z ]+": "([a-z_]+)"/gu)].map((m) => m[1]);
  for (const label of LAYA_INTENT_LABELS) assert.ok(ids.includes(label), `sidecar lacks ${label}`);
  assert.match(sidecarSource, /TIER_LEVELS = \["none", "little", "moderate", "heavy"\]/u);
  assert.match(sidecarSource, /QSET_VERSION = "pi-os-intent-v1"/u);
  assert.match(sidecarSource, /MAX_TEXT_CHARS = 500/u);
  assert.match(sidecarSource, /MAX_LINE_BYTES = 64 \* 1024/u);
  assert.equal(LAYA_MAX_LINE_BYTES, 64 * 1024);
  const intent = PI_OS_INTENT_QUESTIONS.intent;
  assert.equal(intent?.type, "choice");
  assert.deepEqual(intent?.type === "choice" ? Object.keys(intent.criteria) : [], [...LAYA_INTENT_LABELS]);
  const tier = PI_OS_INTENT_QUESTIONS.tier;
  assert.equal(tier?.type === "score" ? tier.criteria.length : 0, LAYA_TIER_LEVELS.length);
  assert.equal(PI_OS_INTENT_QUESTIONS.screen?.type, "bool");
});

test("sidecar results decode strictly and map to advisory laya hints", () => {
  const result = parseLayaIntentResult(sample());
  assert.ok(result);
  assert.deepEqual(layaResultToHints(result, 113.84), {
    source: "laya", latencyMs: 113.8, intent: "calculate", intentP: 0.9909, tier: "quick", tierP: 0.8447, needsScreen: 0.0631,
  });
  const agent = parseLayaIntentResult(sample("agent_task", "heavy"));
  assert.ok(agent);
  assert.deepEqual([layaResultToHints(agent, 1).intent, layaResultToHints(agent, 1).tier], ["other", "deep"]);

  const broken: unknown[] = [
    null, [], { ...sample(), advisory: false }, { ...sample(), intent: { label: "delete_file", p: 0.9, probs: {} } },
    { ...sample(), intent: { label: "calculate", p: 1.5, probs: {} } },
    { ...sample(), tier: { label: "little", p: 0.8, probs: {} } }, // no expected score
    { ...sample(), screen: {} }, { ...sample(), surface: { label: "terminal", p: 0.9, probs: {} } },
    { ...sample(), intent: { label: "calculate", p: 0.9, probs: { calculate: "0.9" } } },
  ];
  for (const value of broken) assert.equal(parseLayaIntentResult(value), null, JSON.stringify(value));
});

test("utterances are trimmed and collapsed, and refused (not truncated) over 500 chars", () => {
  assert.equal(normalizeUtterance("  open \n  Spotify\t "), "open Spotify");
  assert.equal(normalizeUtterance("   "), null);
  assert.equal(normalizeUtterance("x".repeat(500)), "x".repeat(500));
  assert.equal(normalizeUtterance("x".repeat(501)), null);
  assert.equal(normalizeUtterance(42 as unknown as string), null);
});

test("pi catalog answers map to pi-classifier hints; unusable answers give null", () => {
  const answers: Record<string, ClassifierAnswer> = {
    intent: { type: "choice", choice: "file_search", probabilities: { file_search: 0.8, agent_task: 0.2 }, confidence: 0.7 },
    tier: { type: "score", score: 2.6, confidence: 0.4 },
    screen: { type: "bool", probability: 0.12 },
    surface: { type: "choice", choice: "none", probabilities: { none: 1 }, confidence: 1 },
  };
  assert.deepEqual(piAnswersToHints(answers, 512.04), {
    source: "pi-classifier", latencyMs: 512, intent: "search_computer", intentP: 0.8, tier: "deep", needsScreen: 0.12,
  });
  assert.equal(piAnswersToHints({ tier: { type: "score", score: -3, confidence: 1 } }, 1)?.tier, "instant");
  assert.equal(piAnswersToHints({ tier: { type: "score", score: 99, confidence: 1 } }, 1)?.tier, "deep");
  assert.equal(piAnswersToHints({ intent: { type: "choice", choice: "rm -rf", probabilities: {}, confidence: 1 } }, 1), null);
  assert.equal(piAnswersToHints({ screen: { type: "bool", probability: Number.NaN } }, 1), null);
  assert.equal(piAnswersToHints({}, 1), null);
});
