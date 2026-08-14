import { CodexAutoAdapter } from "./codex-auto.js";
import { MockAgentAdapter } from "./mock.js";
import type { AgentAdapter } from "./types.js";

export class AgentAdapterRegistry {
  private readonly adapters = new Map<string, AgentAdapter>();

  constructor(adapters: AgentAdapter[] = [new MockAgentAdapter(), new CodexAutoAdapter()]) {
    for (const adapter of adapters) this.adapters.set(adapter.id, adapter);
  }

  get(id: string) {
    return this.adapters.get(id);
  }

  list() {
    return [...this.adapters.values()];
  }
}
