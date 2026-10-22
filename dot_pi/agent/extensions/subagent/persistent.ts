import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { randomUUID } from "node:crypto";
import { StringEnum } from "@earendil-works/pi-ai";
import { getAgentDir, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
type Brief = { task: string; criteria: string[]; antiCriteria: string[]; context: string };

function delegation({ task, criteria, antiCriteria, context }: Partial<Brief>) {
  if (!task?.trim() || !context?.trim() || !criteria?.length || !antiCriteria?.length ||
      [...criteria, ...antiCriteria].some(item => !item.trim())) {
    throw new Error("start requires task, nonempty criteria and antiCriteria lists, and context; every value must contain text.");
  }
  return {
    task,
    message: "Complete this delegated task using the supplied context; you do not share the parent's conversation. " +
      "Criteria define success; antiCriteria are outcomes that must not occur. Return blockers when necessary context is missing. " +
      "Verify each criterion and anti-criterion, then report evidence, changes, and any remaining gaps.\n\n" +
      JSON.stringify({ task, criteria, antiCriteria, context }, null, 2),
  };
}

type Invocation = (args: string[]) => { command: string; args: string[] };
type Command = { id: string; type: string; status: "submitted" | "accepted" | "rejected"; disposition?: string; run?: number };
type Archived = {
  version: 1; id: string; task: string; cwd: string; sessionFile: string;
  conversation: string; output: string; end: number;
  checkpoint: "prompt" | "settled" | "exit" | "shutdown";
  lastTool?: string; lastError?: string;
};
type Session = {
  id: string; task: string; cwd: string; dir: string; sessionFile: string;
  proc: ChildProcessWithoutNullStreams; lifecycle: "running" | "stopping" | "exited";
  active: boolean; ready: boolean; run: number; output: string; conversation: string; end: number; lastTool?: string; lastError?: string; errors: string[];
  pending: Map<string, Command>; acknowledgements: Map<string, () => void>; commands: Command[]; writes: Promise<void>;
  closed: Promise<void>; stop?: Promise<void>; exitCode?: number | null;
};
const CAP = 32768;

// The entry point supplies invocation selection for compiled Pi, npm Node/Bun, or PATH.
export function registerPersistentSessions(pi: ExtensionAPI, invocation: Invocation) {
  const sessions = new Map<string, Session>();
  const archived = new Map<string, Archived>();
  let notify: ((message: string, type: "warning") => void) | undefined;
  // Never print environment/configuration. Redact inherited credential values from live diagnostics too.
  const secrets = Object.entries(process.env).filter(([k, v]) => /key|token|secret|password|credential/i.test(k) && v && v.length >= 8).map(([, v]) => v!);
  const clean = (text: string) => secrets.reduce((s, value) => s.split(value).join("[REDACTED]"), text);
  const append = (s: Session, text: string) => {
    text = clean(String(text)); s.end += text.length; s.output = (s.output + text).slice(-CAP);
    s.conversation = (s.conversation + text).slice(-CAP);
  };
  const fail = (s: Session, error: unknown) => { s.lastError = clean(String(error)).slice(-2048); s.errors = [...s.errors, s.lastError].slice(-4); };
  const warning = (message: string) => {
    // A failed history write must never interrupt RPC consumption or child cleanup.
    try { if (notify) notify(message, "warning"); else console.warn(message); }
    catch { console.warn(message); }
  };
  const bounded = (text: string, cap: number) => clean(text).slice(-cap);
  const restore = (data: unknown): Archived | undefined => {
    if (!data || typeof data !== "object" || Array.isArray(data)) return;
    const d = data as Record<string, unknown>;
    if (d.version !== 1 || typeof d.id !== "string" || !/^[\w-]{1,128}$/.test(d.id) ||
        !["task", "cwd", "sessionFile", "conversation", "output"].every(k => typeof d[k] === "string") ||
        !(d.task as string).trim() || !(d.cwd as string) || !(d.sessionFile as string) ||
        !Number.isSafeInteger(d.end) || (d.end as number) < 0 ||
        !["prompt", "settled", "exit", "shutdown"].includes(d.checkpoint as string) ||
        [d.lastTool, d.lastError].some(v => v !== undefined && typeof v !== "string")) return;
    const output = bounded(d.output as string, CAP);
    return { version: 1, id: d.id, task: clean(d.task as string).replace(/\s+/g, " ").trim().slice(0, 120),
      cwd: bounded(d.cwd as string, 4096), sessionFile: bounded(d.sessionFile as string, 4096),
      conversation: bounded(d.conversation as string, CAP), output, end: Math.max(d.end as number, output.length),
      checkpoint: d.checkpoint as Archived["checkpoint"],
      ...(d.lastTool !== undefined ? { lastTool: bounded(d.lastTool as string, 256) } : {}),
      ...(d.lastError !== undefined ? { lastError: bounded(d.lastError as string, 2048) } : {}) };
  };
  const persist = (s: Session, checkpoint: Archived["checkpoint"]) => {
    try {
      // Deliberate allowlist: no process, environment, command payloads, or unbounded transcript.
      pi.appendEntry<Archived>("subagent-history", { version: 1, id: s.id, task: bounded(s.task, 120),
        cwd: bounded(s.cwd, 4096), sessionFile: bounded(s.sessionFile, 4096),
        conversation: bounded(s.conversation, CAP), output: bounded(s.output, CAP), end: s.end, checkpoint,
        ...(s.lastTool ? { lastTool: bounded(s.lastTool, 256) } : {}),
        ...(s.lastError ? { lastError: bounded(s.lastError, 2048) } : {}) });
    } catch (error) {
      fail(s, `Subagent history checkpoint failed: ${String(error)}`);
      warning(s.lastError!);
    }
  };
  const busy = (s: Session) => s.lifecycle !== "exited" && (s.active || [...s.pending.values()].some(c => ["prompt", "steer", "follow_up"].includes(c.type)));
  const state = (s: Session) => s.lifecycle === "exited" ? "exited" : s.lifecycle === "stopping" ? "stopping" : busy(s) ? "working" : "idle";
  const archiveDetail = "Read-only history · previous runtime";
  const publish = () => pi.events?.emit("activity:update", { kind: "subagent", items: [
    ...[...archived.values()].filter(s => !sessions.has(s.id)).map(s => ({
      id: s.id, title: `${s.task} · ${s.id.slice(0, 6)}`, state: "archived", detail: archiveDetail,
    })),
    ...[...sessions.values()].map(s => ({
      id: s.id, title: `${s.task} · ${s.id.slice(0, 6)}`, state: state(s), detail: s.lastError ?? s.lastTool,
    })),
  ] });
  const view = (s: Session) => ({ id: s.id, task: s.task, cwd: s.cwd, lifecycle: s.lifecycle,
    ready: s.ready, busy: busy(s), pid: s.proc.pid, exitCode: s.exitCode, sessionFile: s.sessionFile, sessionDir: path.dirname(s.dir),
    lastTool: s.lastTool, lastError: s.lastError, errors: s.errors, commands: s.commands.slice(-8),
    pending: [...s.pending.values()], output: s.output.slice(-2048), nextOffset: s.end });
  const archivedView = (s: Archived) => ({ id: s.id, task: s.task, cwd: s.cwd, sessionFile: s.sessionFile,
    sessionDir: path.dirname(path.dirname(s.sessionFile)), lifecycle: "archived", state: "archived", busy: false,
    ready: false, detail: archiveDetail, lastTool: s.lastTool, lastError: s.lastError, output: s.output.slice(-2048), nextOffset: s.end });
  const readOutput = (s: { output: string; end: number }, requestedOffset?: number, limit = 8192) => {
    const oldest = s.end - s.output.length, requested = requestedOffset ?? oldest;
    const offset = Math.min(s.end, Math.max(oldest, requested));
    const output = s.output.slice(offset - oldest, offset - oldest + limit);
    return { output, offset, nextOffset: offset + output.length, lost: requested < oldest, more: offset + output.length < s.end };
  };
  const kill = (s: Session, signal: NodeJS.Signals) => {
    try { if (process.platform !== "win32" && s.proc.pid) process.kill(-s.proc.pid, signal); else s.proc.kill(signal); } catch { /* already gone */ }
  };
  const onExit = () => { for (const s of sessions.values()) if (s.lifecycle !== "exited") kill(s, "SIGKILL"); };
  let exitHook = false, shuttingDown = false;
  const write = (s: Session, record: object) => {
    // Serialize writes through callbacks: a full pipe never causes an unbounded command queue.
    s.writes = s.writes.then(() => new Promise<void>((resolve, reject) => {
      s.proc.stdin.write(JSON.stringify(record) + "\n", error => error ? reject(error) : resolve());
    })).catch(error => { if (s.lifecycle !== "exited") fail(s, error); });
  };
  const command = (s: Session, type: string, fields: object = {}) => {
    if (s.lifecycle !== "running") throw new Error("Session is stopping or exited; start a new session.");
    if (s.pending.size >= 32) throw new Error("Too many pending RPC commands; inspect status before sending more.");
    const c: Command = { id: randomUUID(), type, status: "submitted" };
    if (type === "prompt") { c.run = s.run; s.active = true; } // includes startup/compaction before agent_start
    s.pending.set(c.id, c); s.commands.push(c); s.commands = s.commands.slice(-8);
    if (["prompt", "steer", "follow_up"].includes(type) && "message" in fields) {
      s.conversation = (s.conversation + `\nYou (${type}): ${clean(String(fields.message))}\n\n`).slice(-CAP);
    }
    write(s, { id: c.id, type, ...fields });
    if (type === "prompt") persist(s, "prompt");
    publish();
    return c;
  };
  const consume = (s: Session, line: string) => {
    let e: any;
    try { e = JSON.parse(line); } catch { fail(s, "Invalid RPC stdout record (contents omitted)."); return; }
    if (!e || typeof e.type !== "string") return;
    if (e.type === "response") {
      const c = s.pending.get(e.id);
      if (!c || c.type !== e.command) return;
      c.status = e.success ? "accepted" : "rejected";
      c.disposition = e.data?.disposition; s.pending.delete(c.id);
      if (c.type === "prompt" && (!e.success || c.disposition === "handled") && c.run === s.run) s.active = false;
      s.acknowledgements.get(c.id)?.();
      if (!e.success) fail(s, e.error ?? "RPC command rejected");
      if (c.type === "get_state" && e.success) s.ready = true;
      // Acceptance is NOT completion: only agent_settled ends accepted automatic work.
    } else if (e.type === "agent_start") { s.active = true; s.run++; }
    else if (e.type === "agent_settled") { s.active = false; if (e.aborted) fail(s, "Run interrupted (agent_settled.aborted)."); }
    else if (e.type === "message_end" && e.message?.role === "assistant") {
      // Draft deltas can be replaced at message_end. Commit only authoritative text,
      // keeping read cursors append-only and drafts out of persisted history.
      append(s, (e.message.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n"));
      append(s, "\n"); if (e.message.errorMessage) fail(s, e.message.errorMessage);
    }
    else if (e.type.startsWith("tool_execution_")) {
      s.lastTool = `${e.toolName ?? "tool"}: ${e.type.replace("tool_execution_", "")}`.slice(0, 256);
      const result = e.partialResult ?? e.result;
      const text = result?.content?.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n");
      if (text) append(s, `\n[${s.lastTool}] ${text}\n`);
      if (e.isError) fail(s, text || "Tool failed");
    } else if (e.type === "extension_error" || e.errorMessage || e.finalError) fail(s, e.error ?? e.errorMessage ?? e.finalError);
    else if (e.type === "extension_ui_request" && ["confirm", "select", "input", "editor"].includes(e.method)) {
      // Headless children must not hang waiting for approval, and must never auto-approve.
      write(s, { type: "extension_ui_response", id: e.id, cancelled: true });
      fail(s, `Child UI ${e.method} cancelled: persistent sessions are headless.`);
    }
    if (e.type === "agent_settled") persist(s, "settled");
    if (["response", "agent_start", "agent_settled", "message_end", "tool_execution_start", "tool_execution_end"].includes(e.type)) publish();
  };
  const stop = (s: Session) => s.stop ??= (async () => {
    const exited = () => s.lifecycle === "exited";
    if (exited()) return;
    // Cleanup must still work when the bounded command registry is full.
    write(s, { type: "clear_queue", id: randomUUID() }); write(s, { type: "abort", id: randomUUID() }); s.lifecycle = "stopping";
    void s.writes.then(() => s.proc.stdin.end());
    const wait = async (ms: number) => {
      let timer: ReturnType<typeof setTimeout>;
      await Promise.race([s.closed, new Promise<void>(r => { timer = setTimeout(r, ms); })]);
      clearTimeout(timer!);
    };
    await wait(1500);
    if (!exited()) { kill(s, "SIGTERM"); await wait(500); }
    if (!exited()) { kill(s, "SIGKILL"); await s.closed; }
  })();

  const offRefresh = pi.events?.on("activity:refresh", publish);
  const offRequest = pi.events?.on("activity:request", async (request: unknown) => {
    const r = request as { kind?: string; id?: string; action?: string; text?: string; respond?: (result: object) => void };
    if (!r || r.kind !== "subagent" || typeof r.respond !== "function") return;
    try {
      const s = sessions.get(r.id ?? "");
      if (!s) {
        const saved = archived.get(r.id ?? "");
        if (!saved) throw new Error("Unknown subagent handle.");
        if (r.action !== "read") throw new Error("Archived subagent history is read-only; start a new session or resume the private session file manually.");
        r.respond({ output: saved.conversation, state: "archived" });
        return;
      }
      if (r.action === "send") {
        if (typeof r.text !== "string" || !r.text.trim() || r.text.length > 65536) throw new Error("Enter a prompt of 1–65536 characters.");
        command(s, busy(s) ? "steer" : "prompt", { message: r.text, streamingBehavior: "steer" });
      } else if (r.action === "stop") await stop(s);
      else if (r.action !== "read") throw new Error("Unsupported subagent activity action.");
      publish();
      r.respond({ output: s.conversation, state: state(s) });
    } catch (error) { r.respond({ error: clean(String(error)) }); }
  });
  pi.on("session_start", (_event, ctx) => {
    notify = (message, type) => ctx.ui.notify(message, type);
    archived.clear();
    let malformed = 0;
    try {
      // Session-wide history, including other branches, belongs only to this parent session.
      for (const entry of ctx.sessionManager.getEntries()) {
        if (entry.type !== "custom" || entry.customType !== "subagent-history") continue;
        const saved = restore(entry.data);
        if (saved) archived.set(saved.id, saved); else malformed++;
      }
    } catch (error) { warning(`Subagent history restore failed: ${bounded(String(error), 2048)}`); }
    if (malformed) warning(`Skipped ${malformed} malformed subagent history record(s).`);
    publish();
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    if (shuttingDown) return;
    shuttingDown = true;
    const live = [...sessions.values()].filter(s => s.lifecycle !== "exited");
    await Promise.all(live.map(stop));
    for (const s of sessions.values()) persist(s, "shutdown");
    if (exitHook) { process.removeListener("exit", onExit); exitHook = false; }
    publish(); offRefresh?.(); offRequest?.();
    if (live.length) ctx.ui.notify(`Stopped ${live.length} persistent subagent session(s) for shutdown/reload. Live handles do not survive reload; saved read-only history remains in this parent session. Private session files remain for manual resume.`, "warning");
  });
  pi.registerTool({
    name: "subagent", label: "Subagent",
    description: "Asynchronous default Pi worker; no agent definitions. start(task,criteria,antiCriteria,context) requires explicit success criteria, outcomes to avoid, and all necessary facts, files, constraints and prior findings. The child does not share the parent's conversation and inherits its model/thinking with normal Pi tools. Start immediately returns a handle before work completes, so continue your own work and start more agents in parallel as resources allow. Check status/read only when useful or when the next step depends on the result; never busy-poll. send(id,text) submits prompt when idle, steer when busy, or follow_up with followUp=true. send waits at most 2s for acceptance, never for completion; submitted means still awaiting acknowledgement. Inspect commands, busy and lastError via status/read. Completion uses agent_settled, not agent_end. read uses character offsets into bounded output: finalized assistant messages and live tool progress, not draft text deltas (older output may be lost). interrupt clears queued work and aborts; stop closes the child. Children stop on parent shutdown/reload; live handles are not restored. Bounded read-only history remains in this parent session and the activity viewer; archived send/interrupt/stop are rejected. Private sessionFile retains history (potentially sensitive tool data); resume manually with --session <sessionFile> --session-dir <sessionDir>. No automatic parent follow-up/model usage polling.",
    parameters: Type.Object({
      action: StringEnum(["start", "list", "status", "read", "send", "interrupt", "stop"] as const),
      task: Type.Optional(Type.String({ minLength: 1, maxLength: 65536, description: "Required for start: task to complete" })),
      criteria: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 2000 }), { minItems: 1, maxItems: 32, description: "Required for start: checkable success conditions" })),
      antiCriteria: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 2000 }), { minItems: 1, maxItems: 32, description: "Required for start: outcomes that must not occur" })),
      context: Type.Optional(Type.String({ minLength: 1, maxLength: 65536, description: "Required for start: all necessary context, including relevant paths, facts, constraints and prior findings" })),
      cwd: Type.Optional(Type.String()), id: Type.Optional(Type.String()),
      text: Type.Optional(Type.String({ minLength: 1, maxLength: 65536 })), followUp: Type.Optional(Type.Boolean()),
      offset: Type.Optional(Type.Integer({ minimum: 0 })), limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 8192 })),
    }, { additionalProperties: false }),
    async execute(_id, input, signal, _update, ctx) {
      if (signal?.aborted) throw new Error("Cancelled before submission.");
      if (shuttingDown) throw new Error("Persistent sessions stopped for shutdown/reload.");
      let result: object;
      if (input.action === "list") result = { sessions: [
        ...[...archived.values()].filter(s => !sessions.has(s.id)).map(s => ({ id: s.id, task: s.task, cwd: s.cwd, lifecycle: "archived", state: "archived", busy: false, ready: false })),
        ...[...sessions.values()].map(s => ({ id: s.id, task: s.task, cwd: s.cwd, lifecycle: s.lifecycle, busy: busy(s), ready: s.ready })),
      ] };
      else if (input.action === "start") {
        const brief = delegation(input);
        const cwd = path.resolve(ctx.cwd, input.cwd ?? ".");
        // Same project session directory preserves project-memory's cwd-hashed store. A cwd override
        // uses that cwd's default directory rather than accidentally sharing another project's store.
        const key = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
        const projectDir = cwd === path.resolve(ctx.cwd) ? ctx.sessionManager.getSessionDir() : path.join(getAgentDir(), "sessions", key);
        fs.mkdirSync(projectDir, { recursive: true, mode: 0o700 });
        const dir = fs.mkdtempSync(path.join(projectDir, "subagent-")); fs.chmodSync(dir, 0o700);
        const id = randomUUID(), sessionFile = path.join(dir, "session.jsonl");
        fs.writeFileSync(sessionFile, JSON.stringify({ type: "session", version: 3, id, timestamp: new Date().toISOString(), cwd }) + "\n", { mode: 0o600 });
        const args = ["--mode", "rpc", "--session-dir", projectDir, "--session", sessionFile];
        const model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
        if (model) args.push("--model", model);
        if (ctx.thinkingLevel) args.push("--thinking", ctx.thinkingLevel);
        const launch = invocation(args);
        let proc: ChildProcessWithoutNullStreams;
        try { proc = spawn(launch.command, launch.args, { cwd, stdio: ["pipe", "pipe", "pipe"], detached: process.platform !== "win32" }); }
        catch (error) { fs.rmSync(dir, { recursive: true, force: true }); throw error; }
        let closed!: () => void;
        const s: Session = { id, task: clean(brief.task).replace(/\s+/g, " ").trim().slice(0, 120), cwd, dir, sessionFile, proc, lifecycle: "running", active: false, ready: false, run: 0,
          output: "", conversation: "", end: 0, errors: [], pending: new Map(), acknowledgements: new Map(), commands: [], writes: Promise.resolve(), closed: new Promise(r => { closed = r; }) };
        sessions.set(id, s);
        if (!exitHook) { process.once("exit", onExit); exitHook = true; }
        // setEncoding preserves split UTF-8; LF-only framing preserves U+2028/U+2029 in JSON strings.
        let buffer = "";
        proc.stdout.setEncoding("utf8");
        proc.stdout.on("data", (chunk: string) => {
          buffer += chunk;
          let lf: number;
          while ((lf = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, lf).replace(/\r$/, ""); buffer = buffer.slice(lf + 1);
            try { if (line) consume(s, line); } catch { fail(s, "Malformed RPC event (contents omitted)."); }
          }
          if (buffer.length > 8 * 1024 * 1024) { fail(s, "RPC record exceeds 8 MiB; stopping child."); kill(s, "SIGKILL"); buffer = ""; }
        });
        proc.stderr.setEncoding("utf8"); proc.stderr.on("data", (text: string) => fail(s, text));
        proc.stdin.on("error", error => fail(s, error)); proc.on("error", error => fail(s, error));
        proc.on("close", code => {
          if (buffer.trim()) fail(s, "Child closed with an incomplete RPC record.");
          if (s.lifecycle !== "stopping") fail(s, `Child exited unexpectedly (${code}). ${s.lastError ?? ""}`);
          kill(s, "SIGKILL"); s.lifecycle = "exited"; s.active = false; s.exitCode = code;
          for (const c of s.pending.values()) { c.status = "rejected"; s.acknowledgements.get(c.id)?.(); }
          s.pending.clear(); closed(); persist(s, "exit"); publish();
        });
        command(s, "get_state"); const submitted = command(s, "prompt", { message: brief.message, streamingBehavior: "steer" });
        result = { ...view(s), submitted, note: "Child launched; task submitted, not yet acknowledged or completed." };
      } else {
        const s = sessions.get(input.id ?? "");
        if (!s) {
          const saved = archived.get(input.id ?? "");
          if (!saved) throw new Error("Unknown session ID; use list.");
          if (!["status", "read"].includes(input.action)) throw new Error("Archived subagent history is read-only; start a new session or resume the private session file manually.");
          result = { ...archivedView(saved), ...(input.action === "read" ? readOutput(saved, input.offset, input.limit) : {}) };
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        }
        if (input.action === "send") {
          if (!input.text?.trim()) throw new Error("send requires nonempty text.");
          const type = busy(s) ? input.followUp ? "follow_up" : "steer" : "prompt";
          const submitted = command(s, type, { message: input.text, ...(type === "prompt" ? { streamingBehavior: input.followUp ? "followUp" : "steer" } : {}) });
          await new Promise<void>(resolve => {
            const timer = setTimeout(resolve, 2000);
            s.acknowledgements.set(submitted.id, () => { clearTimeout(timer); resolve(); });
          });
          s.acknowledgements.delete(submitted.id);
          result = { ...view(s), submitted };
        } else if (input.action === "interrupt") {
          command(s, "clear_queue"); command(s, "abort"); result = view(s);
        } else if (input.action === "stop") { await stop(s); result = view(s); }
        else if (input.action === "read") {
          result = { ...view(s), ...readOutput(s, input.offset, input.limit) };
        } else result = view(s);
      }
      return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
    },
  });
}
