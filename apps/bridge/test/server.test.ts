import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import WebSocket from "ws";
import { CodexCliAdapter } from "../src/adapters/codex-cli.js";
import { MockAgentAdapter } from "../src/adapters/mock.js";
import { AgentAdapterRegistry } from "../src/adapters/registry.js";
import { buildServer } from "../src/server.js";

test("creates a session and mock task", async (t) => {
  const app = await buildServer();
  t.after(() => app.close());

  const health = await app.inject({ method: "GET", url: "/v1/health" });
  assert.equal(health.statusCode, 200);
  assert.equal(health.json().status, "ok");

  const workspaceId = await firstWorkspaceId(app);
  const sessionReply = await app.inject({ method: "POST", url: "/v1/sessions", payload: { workspaceId, title: "Test" } });
  assert.equal(sessionReply.statusCode, 201);
  const taskReply = await app.inject({ method: "POST", url: "/v1/tasks", payload: { sessionId: sessionReply.json().session.id, prompt: "Create a page" } });
  assert.equal(taskReply.statusCode, 202);
  assert.equal(taskReply.json().task.status, "queued");
  const preview = await app.inject({ method: "GET", url: `/v1/artifacts/${taskReply.json().task.id}/preview.html` });
  assert.equal(preview.statusCode, 200);
  assert.match(preview.body, /Codex 任务预览/);
});

test("streams mock task events over WebSocket", async (t) => {
  const app = await buildServer();
  t.after(() => app.close());
  const address = await app.listen({ host: "127.0.0.1", port: 0 });
  const socket = new WebSocket(address.replace("http", "ws") + "/v1/events");
  const events: Array<{ type: string }> = [];
  const completed = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Timed out waiting for task completion")), 1_000);
    socket.on("message", (message) => {
      try {
        const event = JSON.parse(message.toString("utf8")) as { type: string; data: { status?: string } };
        events.push(event);
        if (event.type === "task.status" && event.data.status === "completed") {
          clearTimeout(timeout);
          resolve();
        }
      } catch (error) {
        clearTimeout(timeout);
        reject(error);
      }
    });
    socket.on("error", () => reject(new Error("WebSocket connection failed")));
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });

  const workspaceId = await firstWorkspaceId(app);
  const session = await app.inject({ method: "POST", url: "/v1/sessions", payload: { workspaceId, title: "Stream test" } });
  await app.inject({ method: "POST", url: "/v1/tasks", payload: { sessionId: session.json().session.id, prompt: "Stream output" } });
  await completed;
  socket.close();
  assert.deepEqual(events.map((event) => event.type), ["task.status", "task.status", "task.output", "artifact.ready", "task.status"]);
});

test("serves pairing info and QR page", async (t) => {
  const app = await buildServer(undefined, { port: 4317, host: "127.0.0.1" });
  t.after(() => app.close());

  const pairing = await app.inject({ method: "GET", url: "/v1/pairing" });
  assert.equal(pairing.statusCode, 200);
  assert.equal(pairing.json().preferredUrl, "http://127.0.0.1:4317");
  assert.match(pairing.json().payload, /^agentlink:\/\/bridge\?url=/);

  const qr = await app.inject({ method: "GET", url: "/v1/pairing/qrcode.svg" });
  assert.equal(qr.statusCode, 200);
  assert.match(qr.body, /<svg/);

  const page = await app.inject({ method: "GET", url: "/pair" });
  assert.equal(page.statusCode, 200);
  assert.match(page.body, /AgentLink Bridge 配对/);
});

test("serves manager page and diagnostics", async (t) => {
  const app = await buildServer(new AgentAdapterRegistry([new MockAgentAdapter()]), { port: 4317, host: "127.0.0.1" });
  t.after(() => app.close());

  const diagnostics = await app.inject({ method: "GET", url: "/v1/diagnostics" });
  assert.equal(diagnostics.statusCode, 200);
  assert.equal(diagnostics.json().service, "agent-link-bridge");
  assert.equal(diagnostics.json().port, 4317);

  const manager = await app.inject({ method: "GET", url: "/manage" });
  assert.equal(manager.statusCode, 200);
  assert.match(manager.body, /AgentLink Bridge Manager/);
});

test("serves local Codex history list", async (t) => {
  const app = await buildServer();
  t.after(() => app.close());

  const reply = await app.inject({ method: "GET", url: "/v1/codex/history" });
  assert.equal(reply.statusCode, 200);
  assert.ok(Array.isArray(reply.json().sessions));
});

test("creates workspaces and previews text files safely", async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agentlink-workspaces-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const app = await buildServer();
  t.after(() => app.close());

  const created = await app.inject({
    method: "POST",
    url: "/v1/workspaces",
    payload: { name: "demo project", rootPath: root },
  });
  assert.equal(created.statusCode, 201);
  const workspace = created.json().workspace as { id: string; path: string };
  fs.writeFileSync(path.join(workspace.path, "data.json"), '{"hello":"world"}', "utf8");

  const file = await app.inject({
    method: "GET",
    url: `/v1/workspaces/${encodeURIComponent(workspace.id)}/file?path=${encodeURIComponent("data.json")}`,
  });
  assert.equal(file.statusCode, 200);
  assert.equal(file.json().file.kind, "json");
  assert.match(file.json().file.content, /hello/);

  const traversal = await app.inject({
    method: "GET",
    url: `/v1/workspaces/${encodeURIComponent(workspace.id)}/file?path=${encodeURIComponent("../secret.json")}`,
  });
  assert.equal(traversal.statusCode, 404);
});

test("routes Codex tasks through the registry and records unavailable CLI failure", async (t) => {
  const registry = new AgentAdapterRegistry([new CodexCliAdapter("agent-link-codex-cli-does-not-exist")]);
  const app = await buildServer(registry);
  t.after(() => app.close());
  const workspaceId = await firstWorkspaceId(app);
  const session = await app.inject({ method: "POST", url: "/v1/sessions", payload: { workspaceId, title: "Codex test" } });
  const created = await app.inject({
    method: "POST",
    url: "/v1/tasks",
    payload: { sessionId: session.json().session.id, agentId: "codex", prompt: "Run Codex" },
  });
  assert.equal(created.statusCode, 202);

  await new Promise((resolve) => setTimeout(resolve, 50));
  const tasks = await app.inject({ method: "GET", url: "/v1/tasks" });
  assert.equal(tasks.json().tasks[0].status, "failed");
  assert.equal(tasks.json().tasks[0].agentId, "codex");
});

async function firstWorkspaceId(app: Awaited<ReturnType<typeof buildServer>>) {
  const reply = await app.inject({ method: "GET", url: "/v1/workspaces" });
  assert.equal(reply.statusCode, 200);
  const workspaces = reply.json().workspaces as Array<{ id: string }>;
  assert.ok(workspaces.length > 0);
  return workspaces[0].id;
}
