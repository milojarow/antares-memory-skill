#!/usr/bin/env node
// antares "recall" lobo — headless, READ-ONLY, ISOLATED (settingSources: []).
// Episodic recall: given the current topic, surfaces "we've done this before;
// here's what happened" from past memories + journals. Complements (does not
// replace) the deterministic search hook, which already injects SIMILAR
// memories. Meant to run in the BACKGROUND (gated by a strong-topic signal) so
// it never blocks the prompt.
//
// Reads its task prompt (current topic + dirs to search) from stdin.
// Prints ONLY the recall note to stdout (empty if no relevant episode).
import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-recall-prompt.txt"), "utf8");
const taskPrompt = readFileSync(0, "utf8"); // stdin

const model = process.env.ANTARES_RECALL_MODEL || "sonnet";
const effort = process.env.ANTARES_RECALL_EFFORT || "low";

let note = "", subtype = "error_unknown";
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                          // isolated
      systemPrompt: policy,
      allowedTools: ["Read", "Grep", "Glob"],      // READ-ONLY — never writes
      permissionMode: "bypassPermissions",         // headless: run the reads without prompts
      maxTurns: 15,
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[recall] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      note = (m.result ?? "").trim();
    }
  }
} catch (err) {
  console.error(`[recall] EXCEPTION ${err?.message || err}`);
  process.exit(1);
}

// Surface only a real note; stay silent otherwise.
if (subtype === "success" && note && !/^(nothing|none|no relevant)/i.test(note)) {
  process.stdout.write(note);
}
process.exit(0);
