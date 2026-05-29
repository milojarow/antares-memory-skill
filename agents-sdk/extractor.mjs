#!/usr/bin/env node
// antares "extractor" lobo — replaces the headless `claude -p` in
// memory-precompact-extract.sh with the Agent SDK, ISOLATED from the operator's
// CLAUDE.md / persona files (settingSources: []) so extraction is neutral
// (not biased by the Jarvis voice) and cheaper (no persona tokens loaded).
//
// Reads the sub-prompt (PREPARED transcript path + HOME/CURRENT scope block)
// from stdin. The agent itself does the dedup + writing per the policy
// (memory-precompact-prompt.txt, passed as systemPrompt) — we only swap the
// runtime to an isolated one. Prints a CLI-compatible JSON envelope
// {result, subtype, total_cost_usd, num_turns} so the parent .sh keeps its
// existing jq parsing.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-precompact-prompt.txt"), "utf8");
// stdin — async stream read. readFileSync(0) throws EAGAIN when fd0 is
// non-blocking (intermittent under `printf | node`), so iterate the stream.
let subPrompt = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) subPrompt += chunk;

const model = process.env.ANTARES_PRECOMPACT_MODEL || "sonnet";
const effort = process.env.ANTARES_PRECOMPACT_EFFORT || "medium";

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: subPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude", // node 26: use the system binary
      model,
      effort,
      settingSources: [],                   // ISOLATION — the fix: no CLAUDE.md / persona / auto-memory
      systemPrompt: policy,                 // the extraction policy (neutral extractor, NOT the CLI preset)
      allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"],
      permissionMode: "bypassPermissions",  // headless: write memories without prompts
      maxTurns: 40,                         // bounds cost (the old --max-budget-usd has no clean SDK equiv)
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[extractor] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[extractor] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
