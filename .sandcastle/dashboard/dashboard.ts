// Live dashboard for a sandcastle workflow.
//
// The workflow defines a copy of its structure with building blocks —
// `dash.command(...)`, `dash.ai(...)`, `dash.retryLoop(...)` — and that
// definition IS the dashboard graph, known before anything runs. Flow control
// stays entirely in the workflow's own imperative code; it just calls
// `.start()/.ok()/.fail()` on the blocks as it goes.
//
// `aiStep.logging(name)` returns a sandcastle `logging` option (file mode plus
// `onAgentStreamEvent`), so passing it to `box.run` registers the dashboard as
// a listener: text/toolCall/raw events stream to the browser and tail to
// stdout without any further wiring.
//
// Dependency-free: `node:http` + Server-Sent Events. The server lives in the
// workflow's own long-lived process (verified against sandcastle 0.12.0:
// onAgentStreamEvent fires in-process; nothing else keeps a server alive).

import { execFile, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer, type Server, type ServerResponse } from "node:http";
import * as path from "node:path";

const SELF = import.meta.dirname;

export type AgentStreamEvent =
  | { type: "text"; message: string }
  | { type: "toolCall"; name: string; formattedArgs?: string }
  | { type: "raw"; line: string };

/** What actually flows to the browser: agent events plus synthesized lanes. */
export type DashStreamEvent = AgentStreamEvent | { type: "thinking"; text: string };

export interface ExecResult {
  ok: boolean;
  code: number | null;
  output: string;
}

export type NodeState = "pending" | "running" | "green" | "failed" | "skipped" | "info";

export interface StepOptions {
  sub?: string;
  icon?: string;
  optional?: boolean;
}

export interface Step {
  readonly id: string;
  start(label?: string): void;
  ok(label?: string, detail?: string): void;
  fail(label?: string, detail?: string): void;
  skip(label?: string): void;
  info(label?: string, detail?: string): void;
  /**
   * Run a command with live output: stdout+stderr stream line-by-line into the
   * dashboard (tagged with this step) and to the terminal. Unlike execFileSync
   * nothing is buffered until exit. State flips stay yours — exec only reports
   * `{ ok, code, output }`, it never sets the verdict.
   */
  exec(cmd: string, args?: string[], opts?: { cwd?: string }): Promise<ExecResult>;
}

export interface SandcastleLogging {
  type: "file";
  path: string;
  onAgentStreamEvent: (event: AgentStreamEvent) => void;
}

export interface AiStep extends Step {
  /** Sandcastle `logging` option: file log + live forwarding to the dashboard. */
  logging(name: string): SandcastleLogging;
}

export interface RetryLoop {
  readonly id: string;
  /** Begin the next attempt: bumps the counter, resets the unit's steps. */
  attempt(): number;
  command(label: string, opts?: StepOptions): Step;
  ai(label: string, opts?: StepOptions): AiStep;
  exhausted(reason: string): void;
}

export interface Dashboard {
  readonly url: string;
  readonly port: number;
  command(label: string, opts?: StepOptions): Step;
  ai(label: string, opts?: StepOptions): AiStep;
  retryLoop(label: string, opts?: { max?: number }): RetryLoop;
  push(event: DashStreamEvent, stepId?: string): void;
  cost(model: string, spend: { runs: number; totalTokens: number }): void;
  /** Run landed. Keeps serving for `keepAliveMs` (default 15 min), then exits. */
  done(outcome?: string | RunOutcome): void;
  /** Run failed/parked. Resolves after the final frame is flushed to clients. */
  fail(reason: string | RunOutcome): Promise<void>;
}

/**
 * What the workflow knows and the dashboard cannot infer. Everything else on
 * the completion summary — wall clock, attempts, failed steps, spend — the
 * dashboard tracks itself, so a run cannot misreport it.
 */
export interface RunOutcome {
  /** One line: "squash-merged to main", "PR opened", "parked for a human". */
  headline: string;
  kind?: "merged" | "pr" | "parked" | "dry-run";
  /** PR or issue URL, rendered as a link. */
  link?: string;
  /** True when a human must still act (PR review, parked ticket). */
  needsHuman?: boolean;
  /** Extra rows: ["branch", "ticket-12"] etc. */
  facts?: { label: string; value: string }[];
}

export interface CreateOptions {
  title?: string;
  issue?: { number: number; title: string; url?: string };
  port?: number;
  host?: string;
  /** Shell out to `open` (macOS) once the server is bound. */
  open?: boolean;
  /** Directory for `aiStep.logging()` files. */
  logDir?: string;
  keepAliveMs?: number;
}

interface NodeRec {
  id: string;
  label: string;
  sub?: string;
  icon?: string;
  optional?: boolean;
  loopId?: string;
  state: NodeState;
  stateLabel: string;
  detail?: string;
}

interface LoopRec {
  id: string;
  label: string;
  max?: number;
  counter: number;
  unitIds: string[];
}

interface TopEntry {
  kind: "step" | "loop";
  id: string;
}

interface WireEvent {
  seq: number;
  kind: "decl" | "node" | "attempt" | "event" | "cost" | "done";
  data: unknown;
}

// Never throws: if the server cannot bind, the dashboard degrades to a no-op
// — blocks still exist, `aiStep.logging()` still writes the file log and tails
// stdout — so the workflow needs no optional-chaining or fallback paths.
export async function createDashboard(opts: CreateOptions = {}): Promise<Dashboard> {
  let enabled = true;
  const startedAt = Date.now();
  const meta = {
    title: opts.title ?? "sandcastle run",
    issue: opts.issue,
    status: "running" as "running" | "done" | "failed",
    summary: "",
    // Set on completion so a page opened after the run still shows the summary.
    outcome: undefined as unknown,
  };
  // Every step that went red, in order — the failure history a summary needs.
  const failures: { step: string; label: string; detail?: string; attempt: number }[] = [];
  const logDir = opts.logDir ?? path.join(process.cwd(), ".sandcastle", "logs");
  const html = readFileSync(path.join(SELF, "index.html"), "utf8");

  const order: TopEntry[] = [];
  const nodes = new Map<string, NodeRec>();
  const loops = new Map<string, LoopRec>();
  const costs = new Map<string, { runs: number; totalTokens: number; usd?: number }>();
  // Live USD harvested from pi's per-turn usage records; survives the
  // workflow's own end-of-run cost() overwrite for the same model.
  const usdByModel = new Map<string, number>();
  const liveTurns = new Map<string, { turns: number; totalTokens: number }>();
  const timeline: WireEvent[] = [];
  const clients = new Set<ServerResponse>();
  let seq = 0;
  let idCounter = 0;

  function emit(kind: WireEvent["kind"], data: unknown): void {
    if (!enabled) return;
    const e: WireEvent = { seq: ++seq, kind, data };
    timeline.push(e);
    if (timeline.length > 1000) timeline.splice(0, timeline.length - 1000);
    const frame = `event: frontier\ndata: ${JSON.stringify(e)}\n\n`;
    for (const res of clients) {
      try {
        res.write(frame);
      } catch {
        /* dead client; dropped on close */
      }
    }
  }

  function graphPayload() {
    return {
      order,
      nodes: Object.fromEntries(nodes),
      loops: Object.fromEntries(
        [...loops.values()].map((l) => [l.id, { label: l.label, max: l.max, counter: l.counter, unitIds: l.unitIds }]),
      ),
      costs: Object.fromEntries(costs),
    };
  }

  function makeStep(label: string, o: StepOptions, loopId?: string): NodeRec {
    const id = `s${++idCounter}`;
    const rec: NodeRec = {
      id,
      label,
      sub: o.sub,
      icon: o.icon,
      optional: o.optional,
      loopId,
      state: "pending",
      stateLabel: "",
    };
    nodes.set(id, rec);
    if (loopId) loops.get(loopId)!.unitIds.push(id);
    else order.push({ kind: "step", id });
    emit("decl", graphPayload());
    return rec;
  }

  function setState(rec: NodeRec, state: NodeState, label?: string, detail?: string): void {
    rec.state = state;
    rec.stateLabel = label ?? defaultLabel(state);
    rec.detail = detail;
    if (state === "failed") {
      const owner = rec.loopId ? loops.get(rec.loopId) : undefined;
      failures.push({
        step: rec.id,
        label: `${rec.label}${rec.stateLabel ? " — " + rec.stateLabel : ""}`,
        detail,
        attempt: owner?.counter ?? 0,
      });
    }
    emit("node", { id: rec.id, state, stateLabel: rec.stateLabel, detail });
  }

  // The dashboard owns these numbers; the workflow cannot get them wrong.
  function buildSummary(status: "done" | "failed", outcome: string | RunOutcome) {
    const o: RunOutcome = typeof outcome === "string" ? { headline: outcome } : outcome;
    const attempts = [...loops.values()].map((l) => ({
      label: l.label,
      used: l.counter,
      max: l.max,
    }));
    return {
      status,
      headline: o.headline,
      kind: o.kind,
      link: o.link,
      needsHuman: o.needsHuman ?? false,
      facts: o.facts ?? [],
      durationMs: Date.now() - startedAt,
      attempts,
      failures,
      costs: Object.fromEntries(costs),
      issue: meta.issue,
    };
  }
  function defaultLabel(s: NodeState): string {
    switch (s) {
      case "running": return "running";
      case "green": return "ok";
      case "failed": return "failed";
      case "skipped": return "skipped";
      case "info": return "…";
      default: return "";
    }
  }

  function stepHandle(rec: NodeRec): Step {
    return {
      id: rec.id,
      start: (l) => setState(rec, "running", l),
      ok: (l, d) => setState(rec, "green", l, d),
      fail: (l, d) => setState(rec, "failed", l, d),
      skip: (l) => setState(rec, "skipped", l),
      info: (l, d) => setState(rec, "info", l, d),
      exec: (cmd, args = [], o = {}) =>
        new Promise<ExecResult>((resolve) => {
          const child = spawn(cmd, args, { cwd: o.cwd, stdio: ["ignore", "pipe", "pipe"] });
          let output = "";
          const lineBuffer = () => {
            let buf = "";
            return (chunk: Buffer) => {
              output += chunk.toString();
              buf += chunk.toString();
              const lines = buf.split("\n");
              buf = lines.pop() ?? "";
              for (const line of lines) {
                if (!line.trim()) continue;
                process.stdout.write(`    ${line}\n`);
                push({ type: "raw", line }, rec.id);
              }
            };
          };
          child.stdout.on("data", lineBuffer());
          child.stderr.on("data", lineBuffer());
          child.on("error", (err) => resolve({ ok: false, code: null, output: output + String(err) }));
          child.on("close", (code) => resolve({ ok: code === 0, code, output }));
        }),
    };
  }

  function aiHandle(rec: NodeRec): AiStep {
    return {
      ...stepHandle(rec),
      logging: (name) => ({
        type: "file",
        path: path.join(logDir, `${name}.log`),
        onAgentStreamEvent: (event) => {
          // Same stdout tail the workflow had before, plus the live stream.
          if (event.type === "text") {
            process.stdout.write(event.message);
            push(event, rec.id);
          } else if (event.type === "toolCall") {
            process.stdout.write(`\n  · ${event.name} ${event.formattedArgs ?? ""}\n`);
            push(event, rec.id);
          } else if (event.type === "raw") {
            interpretRawLine(event.line, rec.id);
          }
        },
      }),
    };
  }

  // pi in headless mode prints JSONL protocol records; sandcastle forwards
  // them verbatim as `raw` lines. Rendering them as-is is noise, but they
  // carry two signals nothing else has: the model's thinking, and precomputed
  // per-turn USD cost. Surface those, swallow the rest, and pass genuine
  // plain-text lines through untouched.
  function interpretRawLine(line: string, stepId: string): void {
    const trimmed = line.trim();
    if (trimmed.startsWith("{")) {
      try {
        const rec = JSON.parse(trimmed) as {
          type?: string;
          message?: {
            model?: string;
            content?: { type: string; thinking?: string }[];
            usage?: { totalTokens?: number; cost?: { total?: number } };
          };
        };
        if (typeof rec.type === "string") {
          // pi emits the full assistant message in more than one record type
          // (message end + turn end). Extract from turn_end only, or thinking
          // shows up twice and per-turn cost is counted twice.
          if (rec.type !== "turn_end") return;
          for (const part of rec.message?.content ?? []) {
            if (part.type === "thinking" && part.thinking)
              push({ type: "thinking", text: part.thinking }, stepId);
          }
          const usage = rec.message?.usage;
          const model = rec.message?.model;
          if (usage && model) {
            const key = costKey(model);
            const usd = (usdByModel.get(key) ?? 0) + (usage.cost?.total ?? 0);
            usdByModel.set(key, usd);
            const live = liveTurns.get(key) ?? { turns: 0, totalTokens: 0 };
            live.turns += 1;
            live.totalTokens += usage.totalTokens ?? 0;
            liveTurns.set(key, live);
            // Live tick; the workflow's end-of-run cost() overwrites tokens
            // with the authoritative total, while usd sticks.
            costUpdate(model, { runs: live.turns, totalTokens: live.totalTokens });
          }
          return;
        }
      } catch {
        /* not a protocol record; fall through */
      }
    }
    push({ type: "raw", line }, stepId);
  }

  function push(event: DashStreamEvent, stepId?: string): void {
    emit("event", { ...event, step: stepId });
  }

  // pi reports "deepseek/model", the workflow "openrouter/deepseek/model" —
  // key spend by the bare model name so both land on one card.
  function costKey(model: string): string {
    return model.split("/").pop() ?? model;
  }

  function costUpdate(model: string, spend: { runs: number; totalTokens: number }): void {
    const key = costKey(model);
    const usd = usdByModel.get(key);
    const entry = usd && usd > 0 ? { ...spend, usd } : spend;
    costs.set(key, entry);
    emit("cost", { model: key, ...entry });
  }

  // ---- HTTP + SSE ----
  const host = opts.host ?? "127.0.0.1";
  let port = opts.port ?? 4173;
  const server: Server = createServer((req, res) => {
    const url = (req.url ?? "/").split("?")[0];
    if (url === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(html);
    } else if (url === "/state") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ meta, ...graphPayload(), timeline: timeline.slice(-500) }));
    } else if (url === "/events") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      res.write(": connected\n\n");
      clients.add(res);
      res.on("close", () => clients.delete(res));
    } else {
      res.writeHead(404).end("not found");
    }
  });

  try {
    await new Promise<void>((resolve, reject) => {
      let bound = false;
      server.on("listening", () => {
        bound = true;
        resolve();
      });
      server.on("error", (err: NodeJS.ErrnoException) => {
        if (err.code === "EADDRINUSE" && !bound && port < (opts.port ?? 4173) + 20) {
          port += 1;
          server.listen(port, host);
          return;
        }
        reject(err);
      });
      server.listen(port, host);
    });
  } catch (err) {
    enabled = false;
    console.warn(`dashboard disabled (${String(err)}); running without it`);
  }

  const url = enabled ? `http://${host === "0.0.0.0" ? "localhost" : host}:${port}` : "(disabled)";
  if (enabled) console.log(`dashboard: ${url}`);
  if (enabled && opts.open) execFile("open", [url], () => {});

  // The exit timer is deliberately NOT unref'd: it holds the event loop open so
  // the page outlives the workflow body, then lets the process go.
  function scheduleExit(code: number, ms: number): void {
    setTimeout(() => {
      server.closeAllConnections?.();
      process.exit(code);
    }, ms);
  }

  let finished = false;

  return {
    url,
    port,
    command: (label, o = {}) => stepHandle(makeStep(label, o)),
    ai: (label, o = {}) => aiHandle(makeStep(label, o)),
    retryLoop(label, o = {}) {
      const id = `loop${++idCounter}`;
      const loop: LoopRec = { id, label, max: o.max, counter: 0, unitIds: [] };
      loops.set(id, loop);
      order.push({ kind: "loop", id });
      emit("decl", graphPayload());
      return {
        id,
        attempt() {
          loop.counter += 1;
          for (const unitId of loop.unitIds) {
            const rec = nodes.get(unitId)!;
            rec.state = "pending";
            rec.stateLabel = "";
            rec.detail = undefined;
          }
          emit("attempt", { id, n: loop.counter, max: loop.max });
          return loop.counter;
        },
        command: (l, so = {}) => stepHandle(makeStep(l, so, id)),
        ai: (l, so = {}) => aiHandle(makeStep(l, so, id)),
        exhausted(reason) {
          emit("attempt", { id, n: loop.counter, max: loop.max, exhausted: reason });
        },
      };
    },
    push,
    cost: costUpdate,
    done(outcome) {
      if (!enabled || finished) return;
      finished = true;
      meta.status = "done";
      const summary = buildSummary("done", outcome ?? "finished");
      meta.summary = summary.headline;
      meta.outcome = summary;
      emit("done", summary);
      console.log(`\ndashboard: run complete — ${url}`);
      console.log(`  (page stays up ${Math.round((opts.keepAliveMs ?? 900_000) / 60_000)} min; Ctrl-C to stop)`);
      scheduleExit(0, opts.keepAliveMs ?? 900_000);
    },
    async fail(reason) {
      if (!enabled || finished) return;
      finished = true;
      meta.status = "failed";
      const summary = buildSummary("failed", reason);
      meta.summary = summary.headline;
      meta.outcome = summary;
      emit("done", summary);
      console.log(`\ndashboard: run failed — ${url} (${summary.headline})`);
      // Give SSE clients a beat to receive the final frame before the
      // workflow's process.exit tears the socket down.
      await new Promise((r) => setTimeout(r, 1500));
    },
  };
}