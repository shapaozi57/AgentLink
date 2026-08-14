export type AdapterEvent =
  | { type: "status"; status: "running" | "completed" | "cancelled" }
  | { type: "output"; stream: "stdout" | "stderr"; chunk: string }
  | { type: "artifact"; name: string; mimeType: string; previewUrl: string }
  | { type: "control"; controlMode: EffectiveControlMode; label?: string; reason?: string; desktopMayStealFocus?: boolean }
  | { type: "delivery"; state: DeliveryState; message?: string }
  | { type: "error"; code: string; message: string; details?: Record<string, unknown> };

export type RequestedControlMode = "auto" | "cli" | "desktop";
export type EffectiveControlMode = "cli" | "desktop";
export type DeliveryState = "created" | "sent" | "running" | "delivered" | "refreshable" | "completed" | "failed" | "cancelled";

export interface AgentRunRequest {
  taskId: string;
  cwd: string;
  prompt: string;
  mode: "project" | "chat";
  controlMode?: RequestedControlMode;
  model?: string;
  reasoningEffort?: "low" | "medium" | "high" | "xhigh";
  codexSessionId?: string;
  allowDesktopTakeover?: boolean;
  restoreForegroundWindow?: boolean;
  requireIdleForDesktopTakeover?: boolean;
  onCodexSessionId?: (sessionId: string) => void;
  emit: (event: AdapterEvent) => void;
}

export interface AgentAvailability {
  available: boolean;
  version?: string;
  reason?: string;
}

export interface AgentAdapter {
  readonly id: string;
  checkAvailability(): Promise<AgentAvailability>;
  run(request: AgentRunRequest): Promise<void>;
  cancel(taskId: string): boolean;
}
