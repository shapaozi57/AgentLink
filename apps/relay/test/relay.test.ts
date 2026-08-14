import assert from "node:assert/strict";
import test from "node:test";
import WebSocket, { type RawData } from "ws";
import { buildRelayServer } from "../src/server.js";

test("relays REST calls from mobile to bridge websocket", async () => {
  const app = await buildRelayServer({ secret: "test-secret", deviceId: "pc1", requestTimeoutMs: 2_000 });
  await app.listen({ host: "127.0.0.1", port: 0 });
  const address = app.server.address();
  assert.equal(typeof address, "object");
  const port = typeof address === "object" && address ? address.port : 0;
  const bridge = new WebSocket(`ws://127.0.0.1:${port}/v1/relay/bridge?deviceId=pc1&secret=test-secret`);
  await onceOpen(bridge);
  bridge.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    if (message.type !== "relay.request") return;
    bridge.send(JSON.stringify({
      type: "relay.response",
      requestId: message.requestId,
      statusCode: 200,
      headers: { "content-type": "application/json; charset=utf-8" },
      body: { status: "ok", path: message.path },
    }));
  });
  const response = await fetch(`http://127.0.0.1:${port}/v1/health`, { headers: { Authorization: "Bearer test-secret" } });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "ok", path: "/v1/health" });
  bridge.close();
  await app.close();
});

test("broadcasts bridge events to mobile event websocket", async () => {
  const app = await buildRelayServer({ secret: "test-secret", deviceId: "pc1", requestTimeoutMs: 2_000 });
  await app.listen({ host: "127.0.0.1", port: 0 });
  const address = app.server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  const bridge = new WebSocket(`ws://127.0.0.1:${port}/v1/relay/bridge?deviceId=pc1&secret=test-secret`);
  const mobile = new WebSocket(`ws://127.0.0.1:${port}/v1/events?secret=test-secret`);
  await Promise.all([onceOpen(bridge), onceOpen(mobile)]);
  const event = { id: "evt_1", type: "task.status", timestamp: new Date().toISOString(), data: { taskId: "task_1", status: "completed" } };
  const nextTaskEvent = waitForMessage(mobile, (text) => JSON.parse(text).type === "task.status");
  bridge.send(JSON.stringify({ type: "relay.event", event }));
  assert.deepEqual(JSON.parse(await nextTaskEvent), event);
  bridge.close();
  mobile.close();
  await app.close();
});

function onceOpen(socket: WebSocket) {
  return new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });
}

function onceMessage(socket: WebSocket) {
  return new Promise<string>((resolve, reject) => {
    socket.once("message", (raw) => resolve(raw.toString()));
    socket.once("error", reject);
  });
}

function waitForMessage(socket: WebSocket, predicate: (text: string) => boolean) {
  return new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("Timed out waiting for websocket message"));
    }, 2_000);
    const onMessage = (raw: RawData) => {
      const text = raw.toString();
      if (!predicate(text)) return;
      cleanup();
      resolve(text);
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("message", onMessage);
      socket.off("error", onError);
    };
    socket.on("message", onMessage);
    socket.on("error", onError);
  });
}
