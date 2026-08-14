import assert from "node:assert/strict";
import test from "node:test";
import { CodexCliAdapter } from "../src/adapters/codex-cli.js";
import type { AdapterEvent } from "../src/adapters/types.js";

test("reports a diagnostic error when Codex CLI is missing", async () => {
  const adapter = new CodexCliAdapter("agent-link-codex-cli-does-not-exist");
  const availability = await adapter.checkAvailability();
  assert.equal(availability.available, false);
  assert.match(availability.reason ?? "", /ENOENT|not found/i);

  const events: AdapterEvent[] = [];
  await adapter.run({ taskId: "missing-cli", cwd: process.cwd(), mode: "project", prompt: "hello", emit: (event) => events.push(event) });
  assert.equal(events.length, 1);
  assert.deepEqual(events[0], {
    type: "error",
    code: "CODEX_CLI_UNAVAILABLE",
    message: "Codex CLI is unavailable",
    details: {
      binary: "agent-link-codex-cli-does-not-exist",
      reason: availability.reason,
    },
  });
});
