import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { AgentAdapter, AgentAvailability, AgentRunRequest } from "./types.js";

export class CodexCliAdapter implements AgentAdapter {
  readonly id = "codex";
  private readonly processes = new Map<string, ChildProcessWithoutNullStreams>();

  constructor(private readonly binary = process.env.CODEX_BINARY ?? discoverCodexBinary()) {}

  checkAvailability(): Promise<AgentAvailability> {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (result: AgentAvailability) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };
      const child = spawn(this.binary, ["--version"], { windowsHide: true });
      let output = "";
      child.stdout.on("data", (chunk) => { output += chunk.toString(); });
      child.on("error", (error: NodeJS.ErrnoException) => finish({ available: false, reason: formatSpawnError(error) }));
      child.on("close", (code) => finish(code === 0
        ? { available: true, version: output.trim() || "unknown" }
        : { available: false, reason: `codex --version exited with code ${code}` }));
    });
  }

  async run(request: AgentRunRequest) {
    const availability = await this.checkAvailability();
    if (!availability.available) {
      request.emit({
        type: "error",
        code: "CODEX_CLI_UNAVAILABLE",
        message: "Codex CLI is unavailable",
        details: { binary: this.binary, reason: availability.reason },
      });
      return;
    }

    request.emit({ type: "delivery", state: "sent", message: "已发送到后台 Codex CLI。" });
    request.emit({ type: "status", status: "running" });
    request.emit({ type: "delivery", state: "running", message: "后台 Codex 正在执行。" });
    const idleTimeoutMs = readPositiveInt(process.env.AGENTLINK_CODEX_CLI_TIMEOUT_MS, 90_000);
    await new Promise<void>((resolve) => {
      let settled = false;
      let sawStdout = false;
      const prompt = request.mode === "chat"
        ? `仅对话模式：请只回答用户问题，不修改文件，不创建文件，不执行会写入磁盘的命令。\n\n${request.prompt}`
        : request.prompt;
      const args = request.codexSessionId
        ? ["exec", "resume", "--all", "--skip-git-repo-check"]
        : ["exec", "--skip-git-repo-check"];
      if (request.model) args.push("--model", request.model);
      if (request.reasoningEffort) args.push("-c", `model_reasoning_effort="${request.reasoningEffort}"`);
      if (!request.codexSessionId && request.mode === "chat") args.push("--sandbox", "read-only");
      if (request.codexSessionId) args.push(request.codexSessionId);
      args.push(prompt);
      const child = spawn(this.binary, args, {
        cwd: request.cwd,
        windowsHide: true,
        env: process.env,
      });
      this.processes.set(request.taskId, child);
      child.stdin.end();
      let stderrBuffer = "";
      let stdoutGraceTimer: NodeJS.Timeout | undefined;
      let idleTimer: NodeJS.Timeout | undefined;
      const clearStdoutGraceTimer = () => {
        if (stdoutGraceTimer) clearTimeout(stdoutGraceTimer);
        stdoutGraceTimer = undefined;
      };
      const clearIdleTimer = () => {
        if (idleTimer) clearTimeout(idleTimer);
        idleTimer = undefined;
      };
      const resetIdleTimer = () => {
        clearIdleTimer();
        idleTimer = setTimeout(() => {
          if (settled) return;
          settled = true;
          clearStdoutGraceTimer();
          this.processes.delete(request.taskId);
          child.kill();
          request.emit({
            type: "error",
            code: "CODEX_CLI_TIMEOUT",
            message: `后台 Codex 超过 ${Math.round(idleTimeoutMs / 1000)} 秒没有返回，已停止本次后台执行。`,
            details: { timeoutMs: idleTimeoutMs },
          });
          resolve();
        }, idleTimeoutMs);
      };
      resetIdleTimer();
      const rememberCodexSession = () => {
        const codexSessionId = extractCodexSessionId(stderrBuffer);
        if (codexSessionId) request.onCodexSessionId?.(codexSessionId);
      };
      const finishCompleted = () => {
        if (settled) return;
        settled = true;
        clearStdoutGraceTimer();
        clearIdleTimer();
        rememberCodexSession();
        if (!sawStdout) {
          const stderrAnswer = extractCodexAnswerFromStderr(stderrBuffer);
          request.emit({
            type: "output",
            stream: "stdout",
            chunk: stderrAnswer || "Codex 已完成，但本次没有返回正文。\n",
          });
        }
        request.emit({ type: "status", status: "completed" });
        this.processes.delete(request.taskId);
        resolve();
      };
      child.stdout.on("data", (chunk) => {
        const text = chunk.toString();
        if (text.trim()) {
          sawStdout = true;
          resetIdleTimer();
          request.emit({ type: "output", stream: "stdout", chunk: text });
          clearStdoutGraceTimer();
          stdoutGraceTimer = setTimeout(() => {
            finishCompleted();
            child.kill();
          }, 5_000);
        }
      });
      child.stderr.on("data", (chunk) => { stderrBuffer += chunk.toString(); resetIdleTimer(); });
      child.on("error", (error: NodeJS.ErrnoException) => {
        if (settled) return;
        settled = true;
        clearStdoutGraceTimer();
        clearIdleTimer();
        request.emit({ type: "error", code: "CODEX_CLI_START_FAILED", message: "Failed to start Codex CLI", details: { reason: formatSpawnError(error) } });
        this.processes.delete(request.taskId);
        resolve();
      });
      child.on("close", (code, signal) => {
        if (settled) return;
        settled = true;
        clearStdoutGraceTimer();
        clearIdleTimer();
        this.processes.delete(request.taskId);
        if (signal) request.emit({ type: "status", status: "cancelled" });
        else if (code === 0) {
          rememberCodexSession();
          if (!sawStdout) request.emit({ type: "output", stream: "stdout", chunk: extractCodexAnswerFromStderr(stderrBuffer) || "Codex 已完成，但本次没有返回正文。\n" });
          request.emit({ type: "status", status: "completed" });
        }
        else {
          const stderr = cleanCodexStderr(stderrBuffer);
          const activeWriter = isActiveWriterConflict(stderr);
          request.emit({
            type: "error",
            code: activeWriter ? "CODEX_ACTIVE_WRITER_CONFLICT" : "CODEX_CLI_EXIT_FAILED",
            message: activeWriter
              ? "这个电脑端历史会话正在 Codex 桌面端打开，手机端暂时不能同时写入同一个会话"
              : "Codex CLI exited unsuccessfully",
            details: {
              exitCode: code,
              stderr,
              hint: activeWriter
                ? "可以关闭电脑端该会话后再发送，或者在手机端新建会话；历史聊天记录仍可在手机端只读查看。"
                : undefined,
            },
          });
        }
        resolve();
      });
    });
  }

  cancel(taskId: string) {
    const child = this.processes.get(taskId);
    if (!child) return false;
    return child.kill();
  }
}

function formatSpawnError(error: NodeJS.ErrnoException) {
  return [error.code, error.message].filter(Boolean).join(": ");
}

function cleanCodexStderr(value: string) {
  return value
    .split(/\r?\n/)
    .filter((line) => line.trim() && line.trim() !== "Reading additional input from stdin...")
    .join("\n");
}

function isActiveWriterConflict(value: string) {
  return /already has an active writer|thread-store conflict/i.test(value);
}

function extractCodexAnswerFromStderr(value: string) {
  const cleaned = cleanCodexStderr(value);
  const match = cleaned.match(/(?:^|\n)codex\n([\s\S]*?)\ntokens used\b/);
  return match?.[1]?.trimEnd() ? `${match[1].trimEnd()}\n` : "";
}

function extractCodexSessionId(value: string) {
  return value.match(/session id:\s*([0-9a-f-]{36})/i)?.[1];
}

function readPositiveInt(value: string | undefined, fallback: number) {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function discoverCodexBinary() {
  const candidates = [
    path.join(os.homedir(), ".codex", "plugins", ".plugin-appserver", "codex.exe"),
    path.join(os.homedir(), ".codex", ".sandbox-bin", "codex.exe"),
    "codex",
  ];
  return candidates.find((candidate) => candidate === "codex" || fs.existsSync(candidate)) ?? "codex";
}
