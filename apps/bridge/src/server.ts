import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";
import QRCode from "qrcode";
import { z } from "zod";
import { AgentAdapterRegistry } from "./adapters/registry.js";
import type { AdapterEvent, DeliveryState, EffectiveControlMode, RequestedControlMode } from "./adapters/types.js";
import { listCodexHistorySessions, readCodexHistoryTranscript } from "./codex-history.js";
import { buildPairingInfo } from "./pairing.js";
import { createWorkspace, findWorkspace, listWorkspaces, readWorkspaceFile, readWorkspaceTree } from "./workspaces.js";

type EventName = "task.status" | "task.output" | "task.error" | "artifact.ready" | "session.updated";

export interface BridgeEvent {
  id: string;
  type: EventName;
  timestamp: string;
  data: Record<string, unknown>;
}

interface Session {
  id: string;
  workspaceId: string;
  workspacePath: string;
  title: string;
  createdAt: string;
  codexSessionId?: string;
}

interface Task {
  id: string;
  sessionId: string;
  workspaceId: string;
  agentId: string;
  mode: "project" | "chat";
  controlMode: RequestedControlMode;
  effectiveControlMode?: EffectiveControlMode;
  controlModeDetail?: string;
  desktopMayStealFocus: boolean;
  deliveryState: DeliveryState;
  allowDesktopTakeover: boolean;
  restoreForegroundWindow: boolean;
  requireIdleForDesktopTakeover: boolean;
  model: string;
  reasoningEffort: "low" | "medium" | "high" | "xhigh";
  prompt: string;
  status: "queued" | "running" | "completed" | "failed" | "cancelled";
  createdAt: string;
  summary: string;
  outputLog: string[];
  artifacts: Array<{ name: string; mimeType: string; previewUrl: string }>;
  codexTranscriptBaseline?: number;
  codexReplyWatcherStarted?: boolean;
}

interface BridgeServerOptions {
  port?: number;
  host?: string;
}

const createSessionSchema = z.object({
  workspaceId: z.string().min(1),
  title: z.string().trim().min(1).max(120).default("New Codex session"),
  codexSessionId: z.string().trim().min(1).max(120).optional(),
});

const createWorkspaceSchema = z.object({
  name: z.string().trim().min(1).max(80),
  rootPath: z.string().trim().min(1).max(500).optional(),
});

const createTaskSchema = z.object({
  sessionId: z.string().min(1),
  agentId: z.string().min(1).default("mock"),
  mode: z.enum(["project", "chat"]).default("project"),
  controlMode: z.enum(["auto", "cli", "desktop"]).default("auto"),
  allowDesktopTakeover: z.boolean().default(true),
  restoreForegroundWindow: z.boolean().default(true),
  requireIdleForDesktopTakeover: z.boolean().default(false),
  model: z.string().trim().min(1).max(80).default("gpt-5.6-sol"),
  reasoningEffort: z.enum(["low", "medium", "high", "xhigh"]).default("medium"),
  prompt: z.string().trim().min(1).max(20_000),
});

function newId(prefix: string) {
  return `${prefix}_${crypto.randomUUID()}`;
}

export async function buildServer(registry = new AgentAdapterRegistry(), options: BridgeServerOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  const port = options.port ?? Number(process.env.PORT ?? 4317);
  const host = options.host ?? "0.0.0.0";
  const pairing = buildPairingInfo(port, host);
  const sessions = new Map<string, Session>();
  const tasks = new Map<string, Task>();
  const listeners = new Set<(event: BridgeEvent) => void>();

  const emit = (type: EventName, data: Record<string, unknown>) => {
    const event: BridgeEvent = { id: newId("evt"), type, timestamp: new Date().toISOString(), data };
    for (const listener of listeners) listener(event);
  };

  const failValidation = (result: z.SafeParseReturnType<unknown, unknown>) => ({
    error: "VALIDATION_ERROR",
    details: !result.success ? result.error.flatten() : undefined,
  });

  await app.register(websocket);

  app.get("/v1/health", async () => ({ status: "ok", service: "agent-link-bridge", version: "0.1.0" }));

  app.get("/v1/diagnostics", async () => ({
    status: "ok",
    service: "agent-link-bridge",
    version: "0.1.0",
    pid: process.pid,
    platform: process.platform,
    nodeVersion: process.version,
    uptimeSeconds: Math.round(process.uptime()),
    host,
    port,
    pairing,
    agents: await Promise.all(registry.list().map(async (adapter) => ({
      id: adapter.id,
      ...(await adapter.checkAvailability()),
    }))),
    counts: {
      workspaces: listWorkspaces().length,
      sessions: sessions.size,
      tasks: tasks.size,
      runningTasks: [...tasks.values()].filter((task) => task.status === "running" || task.status === "queued").length,
    },
  }));

  app.get("/v1/pairing", async () => ({
    service: "agent-link-bridge",
    version: "0.1.0",
    urls: pairing.urls,
    preferredUrl: pairing.preferredUrl,
    payload: pairing.payload,
  }));

  app.get("/v1/pairing/qrcode.svg", async (_request, reply) => {
    const svg = await QRCode.toString(pairing.payload, { type: "svg", margin: 1, width: 256 });
    return reply.type("image/svg+xml; charset=utf-8").send(svg);
  });

  app.get("/", async (_request, reply) => reply.redirect("/pair"));

  app.get("/pair", async (_request, reply) => reply.type("text/html; charset=utf-8").send(pairingHtml(pairing)));

  app.get("/manage", async (_request, reply) => reply.type("text/html; charset=utf-8").send(managerHtml(pairing.preferredUrl)));

  app.get("/v1/workspaces", async () => ({ workspaces: listWorkspaces() }));

  app.post("/v1/workspaces", async (request, reply) => {
    const parsed = createWorkspaceSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send(failValidation(parsed));
    try {
      const workspace = createWorkspace(parsed.data);
      return reply.code(201).send({ workspace });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes("EEXIST")) return reply.code(409).send({ error: "WORKSPACE_ALREADY_EXISTS" });
      return reply.code(400).send({ error: message || "WORKSPACE_CREATE_FAILED" });
    }
  });

  app.get("/v1/workspaces/:id/tree", async (request, reply) => {
    const { id } = request.params as { id: string };
    const workspace = findWorkspace(id);
    if (!workspace) return reply.code(404).send({ error: "WORKSPACE_NOT_FOUND" });
    return { workspaceId: id, entries: readWorkspaceTree(workspace.path) };
  });

  app.get("/v1/workspaces/:id/file", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { path: filePath } = request.query as { path?: string };
    const workspace = findWorkspace(id);
    if (!workspace) return reply.code(404).send({ error: "WORKSPACE_NOT_FOUND" });
    if (!filePath) return reply.code(400).send({ error: "FILE_PATH_REQUIRED" });
    try {
      return { workspaceId: id, file: readWorkspaceFile(workspace.path, filePath) };
    } catch {
      return reply.code(404).send({ error: "WORKSPACE_FILE_NOT_FOUND" });
    }
  });

  app.get("/v1/sessions", async () => ({ sessions: [...sessions.values()] }));

  app.get("/v1/codex/history", async () => ({ sessions: listCodexHistorySessions() }));

  app.get("/v1/codex/history/:id/transcript", async (request, reply) => {
    const { id } = request.params as { id: string };
    const messages = readCodexHistoryTranscript(id);
    if (messages.length === 0) return reply.code(404).send({ error: "CODEX_HISTORY_NOT_FOUND" });
    return { sessionId: id, messages };
  });

  app.post("/v1/sessions", async (request, reply) => {
    const parsed = createSessionSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send(failValidation(parsed));
    const workspace = findWorkspace(parsed.data.workspaceId);
    if (!workspace) return reply.code(404).send({ error: "WORKSPACE_NOT_FOUND" });
    const session: Session = { id: newId("ses"), ...parsed.data, workspacePath: workspace.path, createdAt: new Date().toISOString() };
    sessions.set(session.id, session);
    return reply.code(201).send({ session });
  });

  app.get("/v1/tasks", async () => ({
    tasks: [...tasks.values()]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map(serializeTask),
  }));

  app.post("/v1/tasks", async (request, reply) => {
    const parsed = createTaskSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send(failValidation(parsed));
    const session = sessions.get(parsed.data.sessionId);
    if (!session) return reply.code(404).send({ error: "SESSION_NOT_FOUND" });
    const adapter = registry.get(parsed.data.agentId);
    if (!adapter) return reply.code(400).send({ error: "AGENT_NOT_FOUND", agentId: parsed.data.agentId });

    const task: Task = {
      id: newId("task"),
      ...parsed.data,
      workspaceId: session.workspaceId,
      status: "queued",
      createdAt: new Date().toISOString(),
      summary: "任务已创建，等待 Agent 执行。",
      controlMode: parsed.data.controlMode,
      desktopMayStealFocus: parsed.data.controlMode === "desktop",
      deliveryState: "created",
      allowDesktopTakeover: parsed.data.allowDesktopTakeover,
      restoreForegroundWindow: parsed.data.restoreForegroundWindow,
      requireIdleForDesktopTakeover: parsed.data.requireIdleForDesktopTakeover,
      outputLog: [],
      artifacts: [],
    };
    tasks.set(task.id, task);
    emitTaskStatus(task, emit);
    setImmediate(() => {
      if (task.status === "cancelled") return;
      if (session.codexSessionId) {
        task.codexTranscriptBaseline = readCodexHistoryTranscript(session.codexSessionId, 10_000).length;
      }
      void adapter.run({
        taskId: task.id,
        cwd: session.workspacePath,
        prompt: task.prompt,
        mode: task.mode,
        controlMode: task.controlMode,
        model: task.model,
        reasoningEffort: task.reasoningEffort,
        codexSessionId: session.codexSessionId,
        allowDesktopTakeover: task.allowDesktopTakeover,
        restoreForegroundWindow: task.restoreForegroundWindow,
        requireIdleForDesktopTakeover: task.requireIdleForDesktopTakeover,
        onCodexSessionId: (codexSessionId) => {
          session.codexSessionId = codexSessionId;
          task.codexTranscriptBaseline ??= 0;
          sessions.set(session.id, session);
          emit("session.updated", { sessionId: session.id, workspaceId: session.workspaceId, codexSessionId });
        },
        emit: (event) => applyAdapterEvent(task, event, emit),
      })
        .then(() => startCodexReplyWatcher(task, session, emit))
        .catch((error: unknown) => applyAdapterEvent(task, {
          type: "error",
          code: "AGENT_ADAPTER_FAILURE",
          message: "Agent adapter failed unexpectedly",
          details: { reason: error instanceof Error ? error.message : String(error) },
        }, emit));
    });
    return reply.code(202).send({ task: serializeTask(task) });
  });

  app.post("/v1/tasks/:id/cancel", async (request, reply) => {
    const { id } = request.params as { id: string };
    const task = tasks.get(id);
    if (!task) return reply.code(404).send({ error: "TASK_NOT_FOUND" });
    if (task.status === "completed" || task.status === "failed" || task.status === "cancelled") return reply.code(409).send({ error: "TASK_NOT_CANCELLABLE" });
    registry.get(task.agentId)?.cancel(task.id);
    task.status = "cancelled";
    task.deliveryState = "cancelled";
    emitTaskStatus(task, emit);
    return { task: serializeTask(task) };
  });

  app.get("/v1/artifacts/:taskId/preview.html", async (request, reply) => {
    const { taskId } = request.params as { taskId: string };
    const task = tasks.get(taskId);
    if (!task) return reply.code(404).send({ error: "ARTIFACT_NOT_FOUND" });
    return reply.type("text/html; charset=utf-8").send(taskPreviewHtml(task));
  });

  app.get("/v1/events", { websocket: true }, (socket) => {
    const listener = (event: BridgeEvent) => socket.send(JSON.stringify(event));
    listeners.add(listener);
    socket.on("close", () => listeners.delete(listener));
  });

  return app;
}

function applyAdapterEvent(task: Task, event: AdapterEvent, emit: (type: EventName, data: Record<string, unknown>) => void) {
  if (task.status === "cancelled") return;
  if (event.type === "status") {
    task.status = event.status;
    if (event.status === "running" && task.deliveryState === "created") task.deliveryState = "running";
    if (event.status === "completed" && task.deliveryState !== "delivered" && task.deliveryState !== "refreshable") task.deliveryState = "completed";
    if (event.status === "cancelled") task.deliveryState = "cancelled";
    emitTaskStatus(task, emit);
  } else if (event.type === "output") {
    task.outputLog.push(event.chunk);
    const text = event.chunk.trim();
    if (text) task.summary = text.length > 240 ? `${text.slice(0, 237)}...` : text;
    emit("task.output", { taskId: task.id, stream: event.stream, text: event.chunk, chunk: event.chunk });
  } else if (event.type === "artifact") {
    task.artifacts.push({ name: event.name, mimeType: event.mimeType, previewUrl: event.previewUrl });
    task.summary = `产物已就绪：${event.name}`;
    emit("artifact.ready", { taskId: task.id, name: event.name, mimeType: event.mimeType, url: event.previewUrl });
  } else if (event.type === "control") {
    task.effectiveControlMode = event.controlMode;
    task.controlModeDetail = event.reason ?? event.label;
    task.desktopMayStealFocus = event.desktopMayStealFocus ?? event.controlMode === "desktop";
    emitTaskStatus(task, emit);
  } else if (event.type === "delivery") {
    task.deliveryState = event.state;
    if ((event.state === "refreshable" || event.state === "delivered") && task.effectiveControlMode === "desktop" && task.status === "running") {
      task.status = "completed";
    }
    if (event.message) task.summary = event.message;
    emitTaskStatus(task, emit);
  } else {
    task.status = "failed";
    task.deliveryState = "failed";
    task.summary = event.message;
    task.outputLog.push(`${event.message}\n${JSON.stringify(event.details ?? {}, null, 2)}`);
    emit("task.error", { taskId: task.id, error: { code: event.code, message: event.message, details: event.details } });
    emitTaskStatus(task, emit);
  }
}

function emitTaskStatus(task: Task, emit: (type: EventName, data: Record<string, unknown>) => void) {
  emit("task.status", {
    taskId: task.id,
    status: task.status,
    deliveryState: task.deliveryState,
    controlMode: task.controlMode,
    effectiveControlMode: task.effectiveControlMode,
    controlModeDetail: task.controlModeDetail,
    desktopMayStealFocus: task.desktopMayStealFocus,
  });
}

function startCodexReplyWatcher(task: Task, session: Session, emit: (type: EventName, data: Record<string, unknown>) => void) {
  const codexSessionId = session.codexSessionId;
  if (!codexSessionId || task.codexReplyWatcherStarted) return;
  if (task.deliveryState !== "refreshable" && task.effectiveControlMode !== "desktop") return;
  task.codexReplyWatcherStarted = true;
  const baseline = task.codexTranscriptBaseline ?? 0;
  let attempts = 0;
  const maxAttempts = 72;
  const tick = () => {
    if (task.status === "cancelled" || task.status === "failed") return;
    attempts += 1;
    const messages = readCodexHistoryTranscript(codexSessionId, 10_000);
    const newMessages = messages.slice(Math.min(baseline, messages.length));
    const assistantReply = lastAssistantMessage(newMessages);
    if (assistantReply) {
      task.deliveryState = "completed";
      task.status = "completed";
      task.summary = "电脑端回复已同步，可进入会话查看完整内容。";
      task.codexReplyWatcherStarted = false;
      emitTaskStatus(task, emit);
      emit("session.updated", { sessionId: session.id, workspaceId: session.workspaceId, codexSessionId });
      return;
    }
    if (attempts >= maxAttempts) {
      task.deliveryState = "refreshable";
      task.summary = "历史可刷新：电脑端仍可能在运行，进入会话会自动继续刷新。";
      task.codexReplyWatcherStarted = false;
      emitTaskStatus(task, emit);
      return;
    }
    setTimeout(tick, 5_000);
  };
  setTimeout(tick, 5_000);
}

function lastAssistantMessage(messages: ReturnType<typeof readCodexHistoryTranscript>) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role === "assistant") return messages[index];
  }
  return undefined;
}

function serializeTask(task: Task) {
  return task;
}

function pairingHtml(pairing: { urls: string[]; preferredUrl: string }) {
  const urls = pairing.urls.map((url) => `<li><code>${escapeHtml(url)}</code></li>`).join("");
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AgentLink Bridge 配对</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f6f8fa;color:#18212f}.card{max-width:680px;margin:40px auto;padding:28px;background:white;border-radius:18px;box-shadow:0 12px 40px rgba(15,23,42,.12)}h1{margin:0 0 8px}.qr{display:flex;justify-content:center;margin:24px 0}.qr img{width:256px;height:256px;border:1px solid #e5e7eb;border-radius:16px;padding:12px;background:#fff}code{font-size:14px}.hint{color:#526071;line-height:1.7}</style></head><body><main class="card"><h1>AgentLink Bridge 配对</h1><p class="hint">在手机 App 的“设置 → 扫码导入”里扫描下面的二维码，即可导入 Bridge 地址。</p><div class="qr"><img src="/v1/pairing/qrcode.svg" alt="AgentLink pairing QR"></div><p>推荐地址：<code>${escapeHtml(pairing.preferredUrl)}</code></p><p class="hint">可用地址：</p><ul>${urls}</ul></main></body></html>`;
}

function managerHtml(preferredUrl: string) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AgentLink Bridge Manager</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#eef2f7;color:#172033}.wrap{max-width:980px;margin:32px auto;padding:0 18px}.hero{background:#111827;color:#fff;border-radius:22px;padding:26px;box-shadow:0 18px 50px rgba(15,23,42,.22)}.hero h1{margin:0 0 8px;font-size:30px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px;margin-top:16px}.card{background:#fff;border-radius:18px;padding:18px;box-shadow:0 8px 26px rgba(15,23,42,.08)}.muted{color:#667085}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.pill{display:inline-flex;align-items:center;gap:6px;padding:5px 9px;border-radius:999px;background:#e7f8ef;color:#067647;font-size:13px}button,a.btn{border:0;border-radius:12px;padding:10px 13px;background:#0b6e69;color:#fff;text-decoration:none;cursor:pointer;font-weight:600}.secondary{background:#e5e7eb!important;color:#111827!important}code,pre{background:#f3f4f6;border-radius:10px;padding:3px 6px}pre{white-space:pre-wrap;word-break:break-word;padding:12px;min-height:120px}.qr{width:148px;height:148px;border:1px solid #e5e7eb;border-radius:14px;padding:8px;background:#fff}</style></head><body><main class="wrap"><section class="hero"><div class="row"><h1>AgentLink Bridge Manager</h1><span class="pill" id="status">checking</span></div><p class="muted">Local Windows bridge for AgentLink Android. Keep this page open for status, pairing, and diagnostics.</p><div class="row"><a class="btn" href="/pair">Open Pairing QR</a><button onclick="copyUrl()" class="secondary">Copy Bridge URL</button><button onclick="load()" class="secondary">Refresh</button></div></section><section class="grid"><div class="card"><h2>Pairing</h2><img class="qr" src="/v1/pairing/qrcode.svg" alt="QR"><p>Bridge URL</p><code id="url">${escapeHtml(preferredUrl)}</code></div><div class="card"><h2>Runtime</h2><p>PID: <code id="pid">-</code></p><p>Port: <code id="port">-</code></p><p>Uptime: <code id="uptime">-</code></p><p>Node: <code id="node">-</code></p></div><div class="card"><h2>Agents</h2><pre id="agents">loading...</pre></div><div class="card"><h2>Counts</h2><pre id="counts">loading...</pre></div></section><section class="card" style="margin-top:14px"><h2>Diagnostics JSON</h2><pre id="json">loading...</pre></section></main><script>async function load(){const r=await fetch('/v1/diagnostics');const j=await r.json();document.getElementById('status').textContent=j.status==='ok'?'running':'offline';document.getElementById('url').textContent=j.pairing.preferredUrl;document.getElementById('pid').textContent=j.pid;document.getElementById('port').textContent=j.port;document.getElementById('uptime').textContent=j.uptimeSeconds+'s';document.getElementById('node').textContent=j.nodeVersion;document.getElementById('agents').textContent=JSON.stringify(j.agents,null,2);document.getElementById('counts').textContent=JSON.stringify(j.counts,null,2);document.getElementById('json').textContent=JSON.stringify(j,null,2)}function copyUrl(){navigator.clipboard.writeText(document.getElementById('url').textContent)}load();setInterval(load,5000)</script></body></html>`;
}

function taskPreviewHtml(task: Task) {
  const output = task.outputLog.length ? task.outputLog.join("") : task.summary;
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(task.prompt)}</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#0f172a;color:#e5e7eb}main{max-width:860px;margin:0 auto;padding:32px}section{background:#111827;border:1px solid #253044;border-radius:16px;padding:20px;margin:16px 0}h1{font-size:28px;margin:0 0 12px}pre{white-space:pre-wrap;word-break:break-word;background:#020617;border-radius:12px;padding:16px;color:#d1fae5}</style></head><body><main><h1>Codex 任务预览</h1><section><strong>任务</strong><p>${escapeHtml(task.prompt)}</p></section><section><strong>状态</strong><p>${escapeHtml(task.status)}</p></section><section><strong>实时输出</strong><pre>${escapeHtml(output)}</pre></section></main></body></html>`;
}

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character] as string);
}
