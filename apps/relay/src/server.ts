import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import QRCode from "qrcode";
import type WebSocket from "ws";

export interface RelayOptions {
  publicUrl?: string;
  secret?: string;
  deviceId?: string;
  requestTimeoutMs?: number;
}

type RelaySocket = WebSocket & { readyState: number; send(data: string): void; close(code?: number, reason?: string): void; on(event: string, listener: (...args: unknown[]) => void): void };

type RelayEnvelope =
  | { type: "relay.hello"; deviceId?: string; role?: "bridge" | "mobile"; name?: string }
  | { type: "relay.response"; requestId: string; statusCode: number; headers?: Record<string, string>; body?: unknown }
  | { type: "relay.event"; event: unknown }
  | { type: "relay.ping" }
  | { type: "relay.pong" };

interface BridgeConnection {
  deviceId: string;
  socket: RelaySocket;
  connectedAt: string;
  lastSeenAt: string;
  name?: string;
}

interface PendingRequest {
  resolve: (value: RelayHttpResponse) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface RelayHttpResponse {
  statusCode: number;
  headers?: Record<string, string>;
  body?: unknown;
}

const jsonContent = "application/json; charset=utf-8";

export async function buildRelayServer(options: RelayOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  const secret = options.secret ?? process.env.AGENTLINK_RELAY_SECRET ?? "";
  const fixedDeviceId = options.deviceId ?? process.env.AGENTLINK_RELAY_DEVICE_ID ?? "";
  const publicUrl = trimTrailingSlash(options.publicUrl ?? process.env.AGENTLINK_PUBLIC_URL ?? "");
  const requestTimeoutMs = options.requestTimeoutMs ?? readPositiveInt(process.env.AGENTLINK_RELAY_REQUEST_TIMEOUT_MS, 30_000);
  const bridges = new Map<string, BridgeConnection>();
  const mobileSockets = new Map<string, Set<RelaySocket>>();
  const pending = new Map<string, PendingRequest>();

  await app.register(websocket);

  app.get("/v1/relay/health", async () => ({
    status: "ok",
    service: "agent-link-relay",
    version: "0.1.0",
    uptimeSeconds: Math.round(process.uptime()),
    devices: [...bridges.values()].map((bridge) => serializeBridge(bridge)),
  }));

  app.get("/v1/relay/devices", async (request, reply) => {
    const auth = authenticate(request, { secret, fixedDeviceId, bridges });
    if (!auth.ok) return reply.code(auth.statusCode).send({ error: auth.error });
    return { devices: [...bridges.values()].map((bridge) => serializeBridge(bridge)) };
  });

  app.get("/v1/pairing", async (request) => {
    const url = inferPublicUrl(request, publicUrl);
    return pairingPayload(url, secret);
  });

  app.get("/v1/pairing/qrcode.svg", async (request, reply) => {
    const url = inferPublicUrl(request, publicUrl);
    const pairing = pairingPayload(url, secret);
    return reply.type("image/svg+xml").send(await QRCode.toString(pairing.payload, { type: "svg", margin: 1 }));
  });

  app.get("/pair", async (request, reply) => {
    const url = inferPublicUrl(request, publicUrl);
    const pairing = pairingPayload(url, secret);
    return reply.type("text/html; charset=utf-8").send(pairingHtml(pairing));
  });

  app.get("/v1/relay/bridge", { websocket: true }, (socket, request) => {
    const auth = authenticate(request, { secret, fixedDeviceId, bridges, allowFallback: true });
    if (!auth.ok) {
      socket.send(JSON.stringify({ type: "relay.error", error: auth.error }));
      socket.close(1008, auth.error);
      return;
    }
    const bridge: BridgeConnection = {
      deviceId: auth.deviceId,
      socket: socket as RelaySocket,
      connectedAt: new Date().toISOString(),
      lastSeenAt: new Date().toISOString(),
    };
    const previous = bridges.get(auth.deviceId);
    if (previous && previous.socket !== bridge.socket) previous.socket.close(1000, "replaced");
    bridges.set(auth.deviceId, bridge);
    socket.send(JSON.stringify({ type: "relay.ready", role: "bridge", deviceId: auth.deviceId }));

    socket.on("message", (raw) => {
      bridge.lastSeenAt = new Date().toISOString();
      handleBridgeMessage(bridge, raw, pending, mobileSockets);
    });
    socket.on("close", () => {
      if (bridges.get(auth.deviceId)?.socket === bridge.socket) bridges.delete(auth.deviceId);
      rejectDevicePending(auth.deviceId, pending, "Bridge disconnected");
      broadcastDeviceStatus(auth.deviceId, false, mobileSockets);
    });
    broadcastDeviceStatus(auth.deviceId, true, mobileSockets);
  });

  app.get("/v1/events", { websocket: true }, (socket, request) => {
    const auth = authenticate(request, { secret, fixedDeviceId, bridges });
    if (!auth.ok) {
      socket.send(JSON.stringify({ type: "relay.error", error: auth.error }));
      socket.close(1008, auth.error);
      return;
    }
    const set = mobileSockets.get(auth.deviceId) ?? new Set<RelaySocket>();
    set.add(socket as RelaySocket);
    mobileSockets.set(auth.deviceId, set);
    socket.send(JSON.stringify({
      id: newId("evt"),
      type: "relay.status",
      timestamp: new Date().toISOString(),
      data: { connected: bridges.has(auth.deviceId), deviceId: auth.deviceId },
    }));
    socket.on("close", () => {
      set.delete(socket as RelaySocket);
      if (set.size === 0) mobileSockets.delete(auth.deviceId);
    });
  });

  app.all("/v1/*", async (request, reply) => proxyToBridge(request, reply, { secret, fixedDeviceId, bridges, pending, requestTimeoutMs }));

  app.addHook("onClose", async () => {
    for (const bridge of bridges.values()) bridge.socket.close(1001, "server closing");
    for (const sockets of mobileSockets.values()) for (const socket of sockets) socket.close(1001, "server closing");
    for (const item of pending.values()) {
      clearTimeout(item.timer);
      item.reject(new Error("Relay closing"));
    }
    pending.clear();
  });

  return app;
}

async function proxyToBridge(
  request: FastifyRequest,
  reply: FastifyReply,
  context: {
    secret: string;
    fixedDeviceId: string;
    bridges: Map<string, BridgeConnection>;
    pending: Map<string, PendingRequest>;
    requestTimeoutMs: number;
  },
) {
  const auth = authenticate(request, context);
  if (!auth.ok) return reply.code(auth.statusCode).send({ error: auth.error });
  const bridge = context.bridges.get(auth.deviceId);
  if (!bridge || bridge.socket.readyState !== 1) return reply.code(503).send({ error: "BRIDGE_NOT_CONNECTED", deviceId: auth.deviceId });
  const requestId = newId("req");
  const response = await sendBridgeRequest(bridge, context.pending, context.requestTimeoutMs, {
    type: "relay.request",
    requestId,
    method: request.method,
    path: request.url,
    body: request.body ?? null,
  });
  reply.code(response.statusCode);
  const contentType = response.headers?.["content-type"] ?? response.headers?.["Content-Type"];
  if (contentType) reply.header("content-type", contentType);
  else reply.header("content-type", jsonContent);
  return reply.send(response.body ?? {});
}

function sendBridgeRequest(bridge: BridgeConnection, pending: Map<string, PendingRequest>, timeoutMs: number, payload: Record<string, unknown>) {
  const requestId = payload.requestId as string;
  return new Promise<RelayHttpResponse>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error("Bridge request timed out"));
    }, timeoutMs);
    pending.set(requestId, { resolve, reject, timer });
    bridge.socket.send(JSON.stringify(payload));
  });
}

function handleBridgeMessage(
  bridge: BridgeConnection,
  raw: unknown,
  pending: Map<string, PendingRequest>,
  mobileSockets: Map<string, Set<RelaySocket>>,
) {
  const message = parseEnvelope(raw);
  if (!message) return;
  if (message.type === "relay.hello") {
    bridge.name = message.name;
    return;
  }
  if (message.type === "relay.response") {
    const item = pending.get(message.requestId);
    if (!item) return;
    pending.delete(message.requestId);
    clearTimeout(item.timer);
    item.resolve({ statusCode: message.statusCode, headers: message.headers, body: message.body });
    return;
  }
  if (message.type === "relay.event") {
    const sockets = mobileSockets.get(bridge.deviceId);
    if (!sockets) return;
    const text = JSON.stringify(message.event);
    for (const socket of sockets) {
      if (socket.readyState === 1) socket.send(text);
    }
  }
}

function rejectDevicePending(deviceId: string, pending: Map<string, PendingRequest>, reason: string) {
  for (const [id, item] of pending.entries()) {
    // MVP 只有单设备挂起请求；固定 deviceId 后全部终止，避免手机一直转圈。
    clearTimeout(item.timer);
    item.reject(new Error(`${reason}: ${deviceId}`));
    pending.delete(id);
  }
}

function broadcastDeviceStatus(deviceId: string, connected: boolean, mobileSockets: Map<string, Set<RelaySocket>>) {
  const sockets = mobileSockets.get(deviceId);
  if (!sockets) return;
  const event = JSON.stringify({
    id: newId("evt"),
    type: "relay.status",
    timestamp: new Date().toISOString(),
    data: { deviceId, connected },
  });
  for (const socket of sockets) if (socket.readyState === 1) socket.send(event);
}

function authenticate(
  request: FastifyRequest,
  context: { secret: string; fixedDeviceId: string; bridges: Map<string, BridgeConnection>; allowFallback?: boolean },
): { ok: true; deviceId: string } | { ok: false; statusCode: number; error: string } {
  const query = request.query as Record<string, string | undefined>;
  const bearer = bearerToken(request.headers.authorization);
  const providedSecret = headerValue(request.headers["x-agentlink-device-secret"]) ?? query.secret ?? bearer ?? "";
  if (context.secret && providedSecret !== context.secret) return { ok: false, statusCode: 401, error: "RELAY_UNAUTHORIZED" };

  const requestedDeviceId = headerValue(request.headers["x-agentlink-device-id"]) ?? query.deviceId;
  const fallbackDeviceId = context.fixedDeviceId || (context.bridges.size === 1 ? [...context.bridges.keys()][0] : "default");
  const deviceId = requestedDeviceId || fallbackDeviceId;
  if (context.fixedDeviceId && deviceId !== context.fixedDeviceId) return { ok: false, statusCode: 403, error: "RELAY_DEVICE_FORBIDDEN" };
  if (!deviceId && !context.allowFallback) return { ok: false, statusCode: 400, error: "RELAY_DEVICE_REQUIRED" };
  return { ok: true, deviceId: deviceId || "default" };
}

function parseEnvelope(raw: unknown): RelayEnvelope | undefined {
  try {
    const text = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw);
    const value = JSON.parse(text) as RelayEnvelope;
    return typeof value?.type === "string" ? value : undefined;
  } catch {
    return undefined;
  }
}

function serializeBridge(bridge: BridgeConnection) {
  return {
    deviceId: bridge.deviceId,
    connectedAt: bridge.connectedAt,
    lastSeenAt: bridge.lastSeenAt,
    name: bridge.name,
  };
}

function pairingPayload(url: string, secret: string) {
  const params = new URLSearchParams({ url });
  if (secret) params.set("token", secret);
  return {
    service: "agent-link-relay",
    preferredUrl: url,
    payload: `agentlink://bridge?${params.toString()}`,
  };
}

function pairingHtml(pairing: { preferredUrl: string; payload: string }) {
  const tokenHint = pairing.payload.includes("token=") ? "二维码已包含访问令牌；不要发给不可信的人。" : "当前 Relay 未设置访问令牌，仅建议本地测试使用。";
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AgentLink Relay 配对</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f6f8fa;color:#18212f}.card{max-width:680px;margin:40px auto;padding:28px;background:white;border-radius:18px;box-shadow:0 12px 40px rgba(15,23,42,.12)}h1{margin:0 0 8px}.qr{display:flex;justify-content:center;margin:24px 0}.qr img{width:256px;height:256px;border:1px solid #e5e7eb;border-radius:16px;padding:12px;background:#fff}code{font-size:14px}.hint{color:#526071;line-height:1.7}</style></head><body><main class="card"><h1>AgentLink Relay 配对</h1><p class="hint">手机 App 设置页选择“扫码导入”，扫描后即可把 Bridge 地址切到云中继。</p><div class="qr"><img src="/v1/pairing/qrcode.svg" alt="AgentLink relay QR"></div><p>Relay 地址：<code>${escapeHtml(pairing.preferredUrl)}</code></p><p class="hint">${escapeHtml(tokenHint)}</p></main></body></html>`;
}

function inferPublicUrl(request: FastifyRequest, configured: string) {
  if (configured) return configured;
  const proto = headerValue(request.headers["x-forwarded-proto"]) ?? "http";
  const host = headerValue(request.headers["x-forwarded-host"]) ?? request.headers.host ?? "127.0.0.1";
  return `${proto}://${host}`;
}

function bearerToken(value: string | undefined) {
  const match = value?.match(/^Bearer\s+(.+)$/i);
  return match?.[1];
}

function headerValue(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

function trimTrailingSlash(value: string) {
  return value.endsWith("/") ? value.slice(0, -1) : value;
}

function readPositiveInt(value: string | undefined, fallback: number) {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function newId(prefix: string) {
  return `${prefix}_${crypto.randomUUID()}`;
}

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char] ?? char);
}
