import type { AgentAdapter, AgentRunRequest } from "./types.js";

export class MockAgentAdapter implements AgentAdapter {
  readonly id = "mock";
  private readonly timers = new Map<string, Set<NodeJS.Timeout>>();

  async checkAvailability() {
    return { available: true, version: "mock-0.1.0" };
  }

  async run(request: AgentRunRequest) {
    const timers = new Set<NodeJS.Timeout>();
    this.timers.set(request.taskId, timers);
    const wait = (delay: number) => new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        timers.delete(timer);
        resolve();
      }, delay);
      timers.add(timer);
    });

    await wait(25);
    if (!this.timers.has(request.taskId)) return;
    request.emit({ type: "status", status: "running" });
    request.emit({ type: "output", stream: "stdout", chunk: `Codex is working on: ${request.prompt}` });
    await wait(125);
    if (!this.timers.has(request.taskId)) return;
    request.emit({ type: "artifact", name: "preview.html", mimeType: "text/html", previewUrl: `/v1/artifacts/${request.taskId}/preview.html` });
    request.emit({ type: "status", status: "completed" });
    this.timers.delete(request.taskId);
  }

  cancel(taskId: string) {
    const timers = this.timers.get(taskId);
    if (!timers) return false;
    for (const timer of timers) clearTimeout(timer);
    this.timers.delete(taskId);
    return true;
  }
}
