#!/usr/bin/env node
// antares "index-curator" lobo — headless, ISOLATED (settingSources: []).
// PROPOSES MEMORY.md index promotions/demotions (memories that became recurrent/
// critical → always-on; stale entries → out) but NEVER edits MEMORY.md. Writes
// proposals to <HOME>/.index-suggestions.md for the operator to apply by hand.
// Policy: memory-curator-prompt.txt. Reads its task prompt (dirs + MEMORY.md +
// optional search log) from stdin. Prints a CLI-compatible JSON envelope.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-curator-prompt.txt"), "utf8");

// stdin — async stream read. readFileSync(0) throws EAGAIN when fd0 is
// non-blocking (intermittent under `printf | node`), so iterate the stream.
let taskPrompt = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) taskPrompt += chunk;

const model = process.env.ANTARES_CURATOR_MODEL || "sonnet";
const effort = process.env.ANTARES_CURATOR_EFFORT || "medium";

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                          // isolated
      systemPrompt: policy,
      allowedTools: ["Read", "Write"], // judges from inline digest; Read only to confirm a candidate; Write ONLY for .index-suggestions.md (policy forbids touching MEMORY.md)
      permissionMode: "bypassPermissions",
      maxTurns: 12, // digest is inline → a few turns: judge → maybe confirm → write
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[index-curator] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[index-curator] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
