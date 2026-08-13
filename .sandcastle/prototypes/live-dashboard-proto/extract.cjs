// PROTOTYPE — throwaway extractor for the live-dashboard prototype.
// Reads a sandcastle pi session JSONL, pulls a representative subset + cost
// totals, and writes data.js consumed by the prototype index.html.
const fs = require("fs");
const path = require("path");

const SRC = process.argv[2] || path.join(
  __dirname,
  "..",
  "pi-home",
  "sessions",
  "--Users-Daniel.Heinrich-.herdr-worktrees-wormtongue-sandcastle-init-.sandcastle-worktrees-ticket-12--",
  "2026-08-13T10-59-27-241Z_019ffac6-e789-7b53-9786-c6efaaecd918.jsonl",
);
const OUT = process.argv[3] || path.join(__dirname, "data.js");
const SESSION_LABEL = "implement-#12";

const clamp = (s, n) => {
  s = (s == null ? "" : String(s)).replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n) + "…" : s;
};

const recs = fs.readFileSync(SRC, "utf8").split("\n").filter(Boolean).map(JSON.parse);

const partsOf = (rec) => { const m = rec.message || {}; return m.content || []; };
const roleOf = (rec) => (rec.message || {}).role;

let userQuery = "";
let thinking = [];
let assistantText = [];
let toolCalls = [];
let toolResults = [];
let errors = 0;
let toolResultCount = 0;
let usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0 };

for (const r of recs) {
  if (r.type !== "message") continue;
  const role = roleOf(r);
  if (role === "user") {
    for (const p of partsOf(r)) if (p.type === "text" && !userQuery) userQuery = clamp(p.text, 220);
  } else if (role === "assistant") {
    for (const p of partsOf(r)) {
      if (p.type === "thinking") thinking.push(clamp(p.thinking, 140));
      else if (p.type === "text") assistantText.push(clamp(p.text, 260));
      else if (p.type === "toolCall") toolCalls.push({ name: p.name, args: clamp(JSON.stringify(p.arguments), 120) });
    }
    const m = r.message;
    if (m.usage) {
      usage.input += m.usage.input || 0;
      usage.output += m.usage.output || 0;
      usage.cacheRead += m.usage.cacheRead || 0;
      usage.cacheWrite += m.usage.cacheWrite || 0;
      usage.total += m.usage.totalTokens || 0;
      usage.cost += (m.usage.cost && m.usage.cost.total) || 0;
    }
  } else if (role === "toolResult") {
    toolResultCount++;
    if (r.message && r.message.isError) errors++;
    const out = (r.message.content || []).map((c) => c.text || "").join(" ");
    if (toolResults.length < 2) toolResults.push({ toolName: r.message.toolName, isError: !!r.message.isError, out: clamp(out, 180) });
  }
}

const DATA = {
  label: SESSION_LABEL,
  messages: recs.filter((r) => r.type === "message").length,
  toolResults: toolResultCount,
  errors,
  usage: {
    input: Math.round(usage.input), output: Math.round(usage.output),
    cacheRead: Math.round(usage.cacheRead), cacheWrite: Math.round(usage.cacheWrite),
    total: Math.round(usage.total), cost: usage.cost.toFixed(4),
  },
  ticket: {
    number: 12,
    title: "Dictionary entries cannot say what a term is misheard as",
    url: "https://github.com/Danny02/wormtongue/issues/12",
  },
  running: {
    userQuery,
    thinking: thinking.slice(0, 3),
    text: assistantText.slice(0, 4),
    toolCalls: toolCalls.slice(0, 4),
    toolResults,
  },
};

fs.writeFileSync(OUT, "window.PROTO_DATA = " + JSON.stringify(DATA, null, 2) + ";\n");
console.log(`Wrote ${OUT} (${fs.statSync(OUT).size} bytes)`);