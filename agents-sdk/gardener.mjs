#!/usr/bin/env node
// antares "gardener" lobo — headless maintenance agent (SessionEnd), ISOLATED
// (settingSources: []). Cross-checks the existing memory base for drift that
// per-entry write-time dedup can't catch: near-duplicates, contradictions,
// time-obsolescence. CONSERVATIVE v1 — annotates + reports, never deletes or
// destructively merges (policy: memory-gardener-prompt.txt).
//
// Reads its task prompt (which dirs to garden) from stdin. Prints a
// CLI-compatible JSON envelope {result, subtype, total_cost_usd, num_turns}.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-gardener-prompt.txt"), "utf8");
const taskPrompt = readFileSync(0, "utf8"); // stdin: dirs to garden + date, built by the launcher

const model = process.env.ANTARES_GARDENER_MODEL || "sonnet";
const effort = process.env.ANTARES_GARDENER_EFFORT || "medium";

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                   // isolated: no persona bias while curating
      systemPrompt: policy,
      allowedTools: ["Read", "Edit", "Grep", "Glob", "Bash"], // Edit (annotate) — NO Write (no new files), non-destructive
      permissionMode: "bypassPermissions",
      maxTurns: 60,                          // crosses the whole base
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[gardener] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[gardener] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
