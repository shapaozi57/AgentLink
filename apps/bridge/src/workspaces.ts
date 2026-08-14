import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface WorkspaceInfo {
  id: string;
  name: string;
  path: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface WorkspaceFilePreview {
  name: string;
  path: string;
  kind: "text" | "markdown" | "json" | "image" | "binary";
  mimeType: string;
  size: number;
  content?: string;
  truncated?: boolean;
}

interface CandidateWorkspace extends WorkspaceInfo {
  mtimeMs: number;
  createdMs: number;
  score: number;
}

const ignoredDirs = new Set([
  ".git",
  ".dart_tool",
  ".idea",
  ".next",
  ".pnpm-store",
  ".vscode",
  "android",
  "build",
  "coverage",
  "dist",
  "ios",
  "node_modules",
  "out",
  "target",
  "tmp",
]);

const projectMarkers = new Set([
  ".git",
  "AGENTS.md",
  "README.md",
  "package.json",
  "pnpm-workspace.yaml",
  "pubspec.yaml",
  "pyproject.toml",
  "Cargo.toml",
  "go.mod",
]);

const createdWorkspacePaths = new Set<string>();

export function listWorkspaces(limit = 80): WorkspaceInfo[] {
  const candidates = new Map<string, CandidateWorkspace>();
  const cwd = normalizePath(process.env.AGENTLINK_WORKSPACE ?? process.env.INIT_CWD ?? process.cwd());

  for (const root of candidateRoots()) {
    const normalizedRoot = normalizePath(root);
    if (!isDirectory(normalizedRoot)) continue;

    addCandidate(candidates, normalizedRoot, normalizedRoot === cwd ? 0 : 2);
    if (normalizedRoot === cwd && looksLikeProject(normalizedRoot)) continue;

    for (const child of safeReadDir(normalizedRoot)) {
      if (!child.isDirectory()) continue;
      if (shouldIgnoreDir(child.name)) continue;
      const childPath = normalizePath(path.join(normalizedRoot, child.name));
      addCandidate(candidates, childPath, childPath === cwd ? 0 : 1);
    }
  }

  for (const workspacePath of createdWorkspacePaths) {
    addCandidate(candidates, workspacePath, 0);
  }

  return [...candidates.values()]
    .sort((a, b) => b.createdMs - a.createdMs || a.score - b.score || b.mtimeMs - a.mtimeMs || a.name.localeCompare(b.name, "zh-CN"))
    .slice(0, limit)
    .map(({ id, name, path, createdAt, updatedAt }) => ({ id, name, path, createdAt, updatedAt }));
}

export function findWorkspace(workspaceId: string) {
  return listWorkspaces().find((workspace) => workspace.id === workspaceId);
}

export function createWorkspace(input: { name: string; rootPath?: string }): WorkspaceInfo {
  const root = normalizePath(input.rootPath?.trim() || defaultProjectRoot());
  fs.mkdirSync(root, { recursive: true });
  const safeName = sanitizeWorkspaceName(input.name);
  const workspacePath = normalizePath(path.join(root, safeName));
  const relative = path.relative(root, workspacePath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error("WORKSPACE_PATH_OUTSIDE_ROOT");
  }
  fs.mkdirSync(workspacePath, { recursive: false });
  const readme = path.join(workspacePath, "README.md");
  if (!fs.existsSync(readme)) {
    fs.writeFileSync(readme, `# ${safeName}\n\nCreated by AgentLink.\n`, "utf8");
  }
  createdWorkspacePaths.add(workspacePath);
  const stats = fs.statSync(workspacePath);
  return {
    id: workspaceId(workspacePath),
    name: path.basename(workspacePath),
    path: workspacePath,
    createdAt: stats.birthtime.toISOString(),
    updatedAt: stats.mtime.toISOString(),
  };
}

export function readWorkspaceTree(rootPath: string) {
  const root = normalizePath(rootPath);
  if (!isDirectory(root)) return [];
  return readTreeEntries(root, 0);
}

export function readWorkspaceFile(rootPath: string, relativePath: string, limitBytes = 512 * 1024): WorkspaceFilePreview {
  const root = normalizePath(rootPath);
  const filePath = resolveInside(root, relativePath);
  const stats = fs.statSync(filePath);
  if (!stats.isFile()) throw new Error("WORKSPACE_FILE_NOT_FOUND");
  const name = path.basename(filePath);
  const mimeType = mimeTypeForName(name);
  const kind = previewKindForName(name, mimeType);
  const previewPath = normalizeRelativePath(path.relative(root, filePath));

  if (kind === "image" || kind === "binary") {
    return { name, path: previewPath, kind, mimeType, size: stats.size };
  }

  const bytesToRead = Math.min(stats.size, limitBytes);
  const handle = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(bytesToRead);
    fs.readSync(handle, buffer, 0, bytesToRead, 0);
    return {
      name,
      path: previewPath,
      kind,
      mimeType,
      size: stats.size,
      content: buffer.toString("utf8"),
      truncated: stats.size > limitBytes,
    };
  } finally {
    fs.closeSync(handle);
  }
}

function candidateRoots() {
  const home = os.homedir();
  const explicitRoots = (process.env.AGENTLINK_PROJECT_ROOTS ?? "")
    .split(/[;,]/)
    .map((item) => item.trim())
    .filter(Boolean);
  const current = normalizePath(process.env.AGENTLINK_WORKSPACE ?? process.env.INIT_CWD ?? process.cwd());
  return uniquePaths([
    ...explicitRoots,
    current,
    path.dirname(current),
    path.join(home, "Documents", "ChatGPT"),
    path.join(home, "Documents"),
    path.join(home, "Desktop"),
  ]);
}

function defaultProjectRoot() {
  return path.join(os.homedir(), "Documents", "ChatGPT");
}

function addCandidate(candidates: Map<string, CandidateWorkspace>, candidatePath: string, baseScore: number) {
  if (!isDirectory(candidatePath)) return;
  const normalized = normalizePath(candidatePath);
  const name = path.basename(normalized);
  if (shouldIgnoreDir(name)) return;
  const stats = fs.statSync(normalized);
  const createdMs = stats.birthtimeMs || stats.ctimeMs || stats.mtimeMs;
  const score = baseScore + (looksLikeProject(normalized) ? 0 : 3);
  const workspace: CandidateWorkspace = {
    id: workspaceId(normalized),
    name,
    path: normalized,
    createdAt: new Date(createdMs).toISOString(),
    updatedAt: stats.mtime.toISOString(),
    mtimeMs: stats.mtimeMs,
    createdMs,
    score,
  };
  const key = normalized.toLowerCase();
  const existing = candidates.get(key);
  if (!existing || workspace.score < existing.score || workspace.mtimeMs > existing.mtimeMs) {
    candidates.set(key, workspace);
  }
}

function readTreeEntries(dirPath: string, depth: number): Array<{ name: string; type: "directory" | "file"; children?: unknown[] }> {
  if (depth >= 3) return [];
  return safeReadDir(dirPath)
    .filter((entry) => !shouldIgnoreDir(entry.name))
    .sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name, "zh-CN"))
    .slice(0, 80)
    .map((entry) => {
      const fullPath = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        return { name: entry.name, type: "directory" as const, children: readTreeEntries(fullPath, depth + 1) };
      }
      return { name: entry.name, type: "file" as const };
    });
}

function workspaceId(workspacePath: string) {
  return `ws_${createHash("sha1").update(workspacePath.toLowerCase()).digest("hex").slice(0, 14)}`;
}

function sanitizeWorkspaceName(name: string) {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("WORKSPACE_NAME_REQUIRED");
  const sanitized = trimmed
    .replace(/[<>:"/\\|?*\x00-\x1f]/g, "-")
    .replace(/\s+/g, " ")
    .replace(/[. ]+$/g, "")
    .slice(0, 80);
  if (!sanitized || sanitized === "." || sanitized === "..") throw new Error("WORKSPACE_NAME_INVALID");
  return sanitized;
}

function resolveInside(rootPath: string, relativePath: string) {
  const normalizedRelative = relativePath.replace(/\\/g, "/");
  if (!normalizedRelative || normalizedRelative.includes("\0")) throw new Error("WORKSPACE_FILE_NOT_FOUND");
  const fullPath = normalizePath(path.resolve(rootPath, normalizedRelative));
  const relative = path.relative(rootPath, fullPath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) throw new Error("WORKSPACE_FILE_NOT_FOUND");
  return fullPath;
}

function normalizeRelativePath(value: string) {
  return value.replace(/\\/g, "/");
}

function mimeTypeForName(name: string) {
  const extension = path.extname(name).toLowerCase();
  switch (extension) {
    case ".md":
    case ".markdown":
      return "text/markdown; charset=utf-8";
    case ".json":
      return "application/json; charset=utf-8";
    case ".js":
    case ".ts":
    case ".tsx":
    case ".dart":
    case ".py":
    case ".txt":
    case ".yaml":
    case ".yml":
    case ".toml":
    case ".html":
    case ".css":
      return "text/plain; charset=utf-8";
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".webp":
      return "image/webp";
    default:
      return "application/octet-stream";
  }
}

function previewKindForName(name: string, mimeType: string): WorkspaceFilePreview["kind"] {
  const extension = path.extname(name).toLowerCase();
  if (extension === ".md" || extension === ".markdown") return "markdown";
  if (extension === ".json") return "json";
  if (mimeType.startsWith("image/")) return "image";
  if (mimeType.startsWith("text/")) return "text";
  return "binary";
}

function looksLikeProject(dirPath: string) {
  for (const marker of projectMarkers) {
    if (fs.existsSync(path.join(dirPath, marker))) return true;
  }
  return false;
}

function shouldIgnoreDir(name: string) {
  return ignoredDirs.has(name) || name.startsWith(".") && name !== ".codex";
}

function safeReadDir(dirPath: string) {
  try {
    return fs.readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return [];
  }
}

function isDirectory(dirPath: string) {
  try {
    return fs.statSync(dirPath).isDirectory();
  } catch {
    return false;
  }
}

function normalizePath(value: string) {
  try {
    return fs.realpathSync.native(value);
  } catch {
    return path.resolve(value);
  }
}

function uniquePaths(values: string[]) {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const normalized = normalizePath(value);
    const key = normalized.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
  }
  return result;
}
