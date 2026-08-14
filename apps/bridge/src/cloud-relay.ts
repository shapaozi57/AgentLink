import os from "node:os";
import WebSocket, { type RawData } from "ws";

interface CloudRelayOptions {
  localPort: number;
  localHost?: string;
  relayUrl?: string;
  deviceId?: string;
  secret?: string;
}

type RelayMessage =
  | { type: "relay.ready"; deviceId: string; role: "bridge" }
  | { type: "relay.request"; requestId: string; method: string; path: string; body?: unknown }
  | { type: "relay.error"; error: string };

export function startCloudRelayClient(options: CloudRelayOptions) {
  const relayUrl = normalizeRelayUrl(options.relayUrl ?? process.env.AGENTLINK_RELAY_URL ?? "");
  if (!relayUrl) return undefined;
  const deviceId = options.deviceId ?? process.env.AGENTLINK_RELAY_DEVICE_ID ?? os.hostname();
  const secret = options.secret ?? process.env.AGENTLINK_RELAY_SECRET ?? "";
  const localHost = options.localHost ?? "127.0.0.1";
  const localBaseUrl = `http://${localHost}:${options.localPort}`;
  const client = new CloudRelayClient({ relayUrl, deviceId, secret, localBaseUrl });
  client.start();
  return client;
}

class CloudRelayClient {
  private relaySocket?: WebSocket;
  private eventSocket?: WebSocket;
  private reconnectTimer?: NodeJS.Timeout;
  private stopped = false;
  private attempt = 0;

  constructor(private readonly options: { relayUrl: string; deviceId: string; secret: string; localBaseUrl: string }) {}

  start() {
    this.connect();
  }

  stop() {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.relaySocket?.close();
    this.eventSocket?.close();
  }

  private connect() {
    if (this.stopped) return;
    const url = new URL("/v1/relay/bridge", this.options.relayUrl);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.searchParams.set("deviceId", this.options.deviceId);
    if (this.options.secret) url.searchParams.set("secret", this.options.secret);
    const socket = new WebSocket(url);
    this.relaySocket = socket;

    socket.on("open", () => {
      this.attempt = 0;
      socket.send(JSON.stringify({ type: "relay.hello", role: "bridge", deviceId: this.options.deviceId, name: os.hostname() }));
      this.connectLocalEvents();
      console.log(`AgentLink Relay connected: ${this.options.relayUrl} as ${this.options.deviceId}`);
    });
    socket.on("message", (raw) => void this.handleRelayMessage(raw));
    socket.on("close", () => {
      this.eventSocket?.close();
      this.scheduleReconnect();
    });
    socket.on("error", (error) => {
      console.warn(`AgentLink Relay connection error: ${error instanceof Error ? error.message : String(error)}`);
      socket.close();
    });
  }

  private scheduleReconnect() {
    if (this.stopped || this.reconnectTimer) return;
    const delay = Math.min(30_000, 1000 * 2 ** Math.min(this.attempt, 5));
    this.attempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
  }

  private async handleRelayMessage(raw: RawData) {
    const message = parseRelayMessage(raw);
    if (!message) return;
    if (message.type === "relay.error") {
      console.warn(`AgentLink Relay rejected connection: ${message.error}`);
      return;
    }
    if (message.type !== "relay.request") return;
    const response = await this.performLocalRequest(message);
    this.relaySocket?.send(JSON.stringify({ type: "relay.response", requestId: message.requestId, ...response }));
  }

  private async performLocalRequest(message: Extract<RelayMessage, { type: "relay.request" }>) {
    try {
      const target = new URL(message.path, this.options.localBaseUrl);
      const init: RequestInit = { method: message.method };
      if (message.body !== null && message.body !== undefined && !["GET", "HEAD"].includes(message.method.toUpperCase())) {
        init.headers = { "content-type": "application/json" };
        init.body = JSON.stringify(message.body);
      }
      const response = await fetch(target, init);
      const contentType = response.headers.get("content-type") ?? "application/json; charset=utf-8";
      const text = await response.text();
      const body = contentType.includes("application/json") ? parseJson(text) : text;
      return { statusCode: response.status, headers: { "content-type": contentType }, body };
    } catch (error) {
      return {
        statusCode: 502,
        headers: { "content-type": "application/json; charset=utf-8" },
        body: { error: "LOCAL_BRIDGE_REQUEST_FAILED", message: error instanceof Error ? error.message : String(error) },
      };
    }
  }

  private connectLocalEvents() {
    this.eventSocket?.close();
    const url = new URL("/v1/events", this.options.localBaseUrl);
    url.protocol = "ws:";
    const eventSocket = new WebSocket(url);
    this.eventSocket = eventSocket;
    eventSocket.on("message", (raw) => {
      if (this.relaySocket?.readyState !== WebSocket.OPEN) return;
      this.relaySocket.send(JSON.stringify({ type: "relay.event", event: parseJson(raw.toString()) }));
    });
    eventSocket.on("close", () => {
      if (!this.stopped && this.relaySocket?.readyState === WebSocket.OPEN) {
        setTimeout(() => this.connectLocalEvents(), 2_000);
      }
    });
    eventSocket.on("error", () => eventSocket.close());
  }
}

function parseRelayMessage(raw: RawData): RelayMessage | undefined {
  try {
    const value = JSON.parse(raw.toString()) as RelayMessage;
    return typeof value?.type === "string" ? value : undefined;
  } catch {
    return undefined;
  }
}

function parseJson(text: string) {
  if (!text) return {};
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

function normalizeRelayUrl(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return "";
  const withScheme = trimmed.includes("://") ? trimmed : `https://${trimmed}`;
  return withScheme.replace(/\/$/, "");
}
