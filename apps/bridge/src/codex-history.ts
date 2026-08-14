import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface CodexHistorySession {
  id: string;
  title: string;
  updatedAt: string;
  cwd?: string;
}

export interface CodexTranscriptMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  timestamp: string;
}

export function listCodexHistorySessions(limit = 50): CodexHistorySession[] {
  const indexPath = path.join(os.homedir(), ".codex", "session_index.jsonl");
  if (!fs.existsSync(indexPath)) return [];
  const rows: CodexHistorySession[] = [];
  for (const line of fs.readFileSync(indexPath, "utf8").split(/\r?\n/).filter(Boolean)) {
    try {
      const value = JSON.parse(line) as { id?: string; thread_name?: string; updated_at?: string };
      if (!value.id) continue;
      rows.push({
        id: value.id,
        title: value.thread_name || "Codex 会话",
        updatedAt: value.updated_at || new Date(0).toISOString(),
        cwd: readSessionCwd(value.id),
      });
    } catch {
      // Ignore malformed local index rows.
    }
  }
  return rows
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    .slice(0, limit);
}

export function readCodexHistoryTranscript(sessionId: string, limit = 200): CodexTranscriptMessage[] {
  const root = path.join(os.homedir(), ".codex", "sessions");
  const file = findSessionFile(root, sessionId);
  if (!file) return [];
  const messages: CodexTranscriptMessage[] = [];
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean)) {
    try {
      const value = JSON.parse(line) as {
        timestamp?: string;
        type?: string;
        payload?: {
          type?: string;
          id?: string;
          role?: string;
          content?: Array<{ type?: string; text?: string }>;
        };
      };
      if (value.type !== "response_item") continue;
      const payload = value.payload;
      if (payload?.type !== "message") continue;
      const role = payload.role;
      if (role !== "user" && role !== "assistant") continue;
      const text = extractMessageText(payload.content ?? []);
      if (!text || isInternalCodexMessage(text)) continue;
      messages.push({
        id: payload.id || `${role}_${messages.length}`,
        role,
        text,
        timestamp: value.timestamp || new Date(0).toISOString(),
      });
    } catch {
      // Ignore malformed local history rows.
    }
  }
  return messages.slice(-limit);
}

function readSessionCwd(sessionId: string) {
  const root = path.join(os.homedir(), ".codex", "sessions");
  const file = findSessionFile(root, sessionId);
  if (!file) return undefined;
  try {
    const firstLine = fs.readFileSync(file, "utf8").split(/\r?\n/, 1)[0];
    const parsed = JSON.parse(firstLine) as { payload?: { cwd?: string } };
    return parsed.payload?.cwd;
  } catch {
    return undefined;
  }
}

function extractMessageText(content: Array<{ type?: string; text?: string }>) {
  return content
    .filter((item) => item.type === "input_text" || item.type === "output_text")
    .map((item) => item.text?.trim() ?? "")
    .filter(Boolean)
    .join("\n\n")
    .trim();
}

function isInternalCodexMessage(text: string) {
  const trimmed = text.trim();
  return trimmed.startsWith("# AGENTS.md instructions")
    || trimmed.startsWith("<environment_context>")
    || trimmed.startsWith("<app-context>")
    || trimmed.startsWith("<skills_instructions>")
    || trimmed.startsWith("<permissions instructions>")
    || trimmed.startsWith("<collaboration_mode>")
    || trimmed.startsWith("<plugins_instructions>")
    || trimmed.startsWith("<multi_agent_mode>");
}

function findSessionFile(root: string, sessionId: string): string | undefined {
  if (!fs.existsSync(root)) return undefined;
  const stack = [root];
  while (stack.length) {
    const current = stack.pop()!;
    for (const entry of safeReadDir(current)) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(fullPath);
      else if (entry.isFile() && entry.name.includes(sessionId) && entry.name.endsWith(".jsonl")) return fullPath;
    }
  }
  return undefined;
}

function safeReadDir(dirPath: string) {
  try {
    return fs.readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return [];
  }
}
