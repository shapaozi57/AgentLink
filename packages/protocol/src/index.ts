export type TaskStatus =
  | 'queued'
  | 'running'
  | 'completed'
  | 'failed'
  | 'cancelled';

export interface Device {
  id: string;
  name: string;
  host: string;
  status: 'online' | 'offline';
}

export interface Workspace {
  id: string;
  name: string;
  rootPath: string;
  lastOpenedAt: string;
}

export interface Agent {
  id: string;
  displayName: string;
  status: 'ready' | 'unavailable';
  capabilities: string[];
}

export type AgentAdapterId = 'mock' | 'codex' | (string & {});

export interface Task {
  id: string;
  workspaceId: string;
  agentId: string;
  prompt: string;
  status: TaskStatus;
  createdAt: string;
  startedAt?: string;
  endedAt?: string;
}

export type BridgeEvent =
  | { type: 'task.status'; sequence: number; occurredAt: string; taskId: string; status: TaskStatus }
  | { type: 'task.output'; sequence: number; occurredAt: string; taskId: string; stream: 'stdout' | 'stderr'; chunk: string }
  | { type: 'task.error'; sequence: number; occurredAt: string; taskId: string; error: { code: string; message: string; details?: Record<string, unknown> } }
  | { type: 'task.tool'; sequence: number; occurredAt: string; taskId: string; name: string; state: 'started' | 'completed'; summary: string }
  | { type: 'artifact.ready'; sequence: number; occurredAt: string; taskId: string; artifact: { id: string; name: string; mimeType: string; previewUrl: string } };
