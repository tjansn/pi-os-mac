// Pure deterministic demo data. No model, network, storage, code execution or OS APIs.
export const examples = Object.freeze({
  notes: {
    app: "Notes",
    title: "Weekend plans",
    heading: "A weekend, unhurried.",
    kicker: "A NOTE TO YOURSELF",
    icon: "notes",
    text: "Two days in Copenhagen. A few good places.\nEnough room to get a little lost.\n\nSaturday\nCoffee at a neighborhood bakery.\nA walk along the harbor.\nDinner somewhere small.\n\nSunday\nA slow museum morning, then the train home.",
    prompts: ["Summarize this", "Make a checklist", "Make it shorter"],
  },
  mail: {
    app: "Mail",
    title: "A quick follow-up",
    heading: "A quick follow-up",
    kicker: "AN UNSENT EXAMPLE DRAFT",
    icon: "mail",
    text: "Hi Alex,\n\nThanks for the call yesterday. Could you send the revised proposal by Friday? We would like to review it before our planning meeting on Monday.\n\nThanks,\nSam",
    prompts: ["Make this friendlier", "Summarize this", "Make it shorter"],
  },
  code: {
    app: "Code",
    title: "greet.js",
    heading: "A small function.",
    kicker: "EXAMPLE CODE · NEVER EXECUTED",
    icon: "code",
    text: 'const greet = (name) => {\n  return `Hello, ${name.trim()}!`;\n};\n\nconsole.log(greet("  Ada  "));',
    prompts: [
      "Explain this code",
      "Add TypeScript types",
      "What about an empty name?",
    ],
  },
});

const lines = (text) =>
  String(text)
    .split(/\r\n?|\n/)
    .map((line) => line.trim())
    .filter(Boolean);
const answer = (title, blocks, patch = null) => ({
  kind: "answer",
  title,
  blocks,
  patch,
});

/** Supported intents use obvious string operations or fixed example templates. */
export function mockReply({ example, prompt, text, turn = 1 }) {
  const words = String(prompt).toLowerCase();
  const source = String(text).slice(0, 6000);
  if (/\b(delete|trash|erase|password|credentials)\b|\brm\s+-/.test(words)) {
    return {
      kind: "refusal",
      title: "This stays a safe mock.",
      blocks: [
        {
          text: "No files, passwords or real apps are available here. This demo won’t simulate deletion or credential extraction.",
        },
        {
          text: "Try a summary, a checklist or one of the suggested prompts instead.",
        },
      ],
      patch: null,
    };
  }
  if (/\b(send|publish|post|buy|purchase|login|log in)\b/.test(words)) {
    return answer("Only the demo window, here.", [
      {
        text: "There is no account or app connection. I can prepare a scripted example, but nothing is sent, published or purchased.",
      },
    ]);
  }
  if (/\b(short|shorter|concise|condense|brief)\b/.test(words)) {
    const nonempty = lines(source);
    const short = nonempty.slice(0, 3).join("\n");
    return answer(
      "Less text. Same starting point.",
      [
        {
          text: "This mock keeps the first three non-empty lines of your example — a simple extraction, not an AI rewrite.",
        },
        {
          text:
            short ||
            "The demo document is empty. Add a few lines and try again.",
        },
      ],
      short || null,
    );
  }
  if (/checklist|tasks|action items|to.do|bullet/.test(words)) {
    const items = lines(source)
      .filter((line) => !/^(saturday|sunday|hi |thanks,)/i.test(line))
      .slice(0, 6);
    const patch = items.map((line) => "☐ " + line).join("\n");
    return answer(
      "A list you can work with.",
      [
        {
          text: "The mock converts up to six non-empty lines into a checklist.",
        },
        {
          items: items.length ? items : ["Add some text to the example first."],
        },
      ],
      patch || null,
    );
  }
  if (/summari[sz]e|summary|tl;?dr|main points/.test(words)) {
    return answer("The essentials, at a glance.", [
      {
        text: "An extractive summary of the current demo document. No inference involved.",
      },
      {
        items: lines(source).slice(0, 3).length
          ? lines(source).slice(0, 3)
          : ["Your demo document is empty."],
      },
    ]);
  }
  if (example === "mail" && /friendl|warm|rewrite|polish/.test(words)) {
    const patch =
      "Hi Alex,\n\nIt was lovely speaking yesterday. Would you be able to share the revised proposal by Friday? That would give us time to review it before Monday’s planning meeting.\n\nThanks so much,\nSam";
    return answer(
      "A warmer way to follow up.",
      [
        {
          text: "A fixed rewrite of the sample Alex/Sam email — not a generated rewrite of arbitrary text.",
        },
        { text: patch },
      ],
      patch,
    );
  }
  if (example === "code" && /typescript|types|typed/.test(words)) {
    const patch =
      "const greet = (name: string): string => {\n  return `Hello, ${name.trim()}!`;\n};";
    return answer(
      "A little more explicit.",
      [
        {
          text: "A fixed TypeScript version of the original greet example. Code is shown as text and never executed.",
        },
        { code: patch },
      ],
      patch,
    );
  }
  if (example === "code" && /empty|blank|edge case/.test(words)) {
    return answer("One edge case worth noticing.", [
      {
        text: "In the original greet example, an empty or whitespace-only name becomes “Hello, !”. A missing name would throw when trim() is called.",
      },
      {
        text: "This explanation is scripted for the original example, not a live code analysis.",
      },
    ]);
  }
  if (example === "code" && /explain|what|how|does/.test(words)) {
    return answer("A greeting, without the extra spaces.", [
      {
        items: [
          "Takes a name as its input.",
          "trim() removes spaces from either end.",
          "Returns a greeting. The sample input produces “Hello, Ada!”.",
        ],
      },
      {
        text: "A scripted explanation of the original greet example. Nothing is executed.",
      },
    ]);
  }
  return {
    kind: "unsupported",
    title:
      turn > 1 ? "Same window. Still a scripted demo." : "A mock, not a model.",
    blocks: [
      {
        text: "I can show summaries, shorter text, checklists and the example email/code templates. I don’t understand arbitrary requests or connect to an LLM.",
      },
      {
        text: "Try one of the suggested prompts below, or edit the example document and ask for a summary.",
      },
    ],
    patch: null,
  };
}
