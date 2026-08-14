import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { listCodexHistorySessions } from "../codex-history.js";
import type { AgentAdapter, AgentAvailability, AgentRunRequest } from "./types.js";

export class CodexDesktopUiAdapter implements AgentAdapter {
  readonly id = "codex";
  private readonly cancelled = new Set<string>();

  async checkAvailability(): Promise<AgentAvailability> {
    if (process.platform !== "win32") {
      return { available: false, reason: "Codex desktop UI control currently requires Windows" };
    }
    try {
      const result = await runPowerShell(`
        $p = Get-Process ChatGPT -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne 0 } |
          Select-Object -First 1
        if ($p) { Write-Output "ok:$($p.Id)" } else { exit 2 }
      `, 6_000);
      return result.code === 0
        ? { available: true, version: result.stdout.trim() || "codex-desktop-ui" }
        : { available: false, reason: "没有找到已打开的 Codex / ChatGPT 桌面窗口" };
    } catch (error) {
      return { available: false, reason: error instanceof Error ? error.message : String(error) };
    }
  }

  async run(request: AgentRunRequest) {
    this.cancelled.delete(request.taskId);
    const availability = await this.checkAvailability();
    if (!availability.available) {
      request.emit({
        type: "error",
        code: "CODEX_DESKTOP_UI_UNAVAILABLE",
        message: "没有找到可远程控制的 Codex 桌面窗口",
        details: { reason: availability.reason },
      });
      return;
    }

    const prompt = request.mode === "chat"
      ? `仅对话模式：请只回答用户问题，不修改文件，不创建文件，不执行会写入磁盘的命令。\n\n${request.prompt}`
      : request.prompt;
    const knownSessionIds = new Set(listCodexHistorySessions(200).map((session) => session.id));
    const shouldCreateDesktopSession = !request.codexSessionId;

    request.emit({ type: "control", controlMode: "desktop", label: "桌面接管", reason: "通过电脑端当前 Codex 窗口投递消息", desktopMayStealFocus: true });
    request.emit({ type: "delivery", state: "sent", message: "正在准备桌面接管。" });
    request.emit({ type: "status", status: "running" });
    request.emit({
      type: "output",
      stream: "stdout",
      chunk: shouldCreateDesktopSession
        ? "正在电脑端 Codex 新建会话并投递消息...\n"
        : "正在把消息发送到电脑端 Codex 当前会话窗口...\n",
    });

    try {
      await sendPromptToCodexDesktop(prompt, {
        newSession: shouldCreateDesktopSession,
        restoreForegroundWindow: request.restoreForegroundWindow ?? true,
        requireIdle: request.requireIdleForDesktopTakeover ?? false,
      });
    } catch (error) {
      request.emit({
        type: "error",
        code: "CODEX_DESKTOP_UI_SEND_FAILED",
        message: "发送到电脑端 Codex 窗口失败",
        details: { reason: error instanceof Error ? error.message : String(error) },
      });
      return;
    }

    if (shouldCreateDesktopSession) {
      const newSessionId = await waitForNewSessionId(knownSessionIds, request.cwd, 12_000);
      if (newSessionId) request.onCodexSessionId?.(newSessionId);
    }

    if (!this.cancelled.has(request.taskId)) {
      request.emit({ type: "delivery", state: "delivered", message: "已投递到电脑端 Codex，电脑端会继续运行；稍后刷新历史即可查看完整回复。" });
      request.emit({
        type: "output",
        stream: "stdout",
        chunk: "手机端投递已完成。电脑端会继续执行；稍后点进该会话即可刷新历史聊天记录。\n",
      });
      request.emit({ type: "delivery", state: "refreshable", message: "历史可刷新：电脑端 Codex 已收到消息，稍后进入会话查看完整回复。" });
    }
    request.emit({ type: "status", status: this.cancelled.has(request.taskId) ? "cancelled" : "completed" });
    this.cancelled.delete(request.taskId);
  }

  cancel(taskId: string) {
    this.cancelled.add(taskId);
    return true;
  }
}

async function sendPromptToCodexDesktop(prompt: string, options: { newSession: boolean; restoreForegroundWindow: boolean; requireIdle: boolean }) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "agentlink-codex-ui-"));
  const promptPath = path.join(tempDir, "prompt.txt");
  fs.writeFileSync(promptPath, prompt, "utf8");
  try {
    const script = `
      $ErrorActionPreference = 'Stop'
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type @"
using System;
using System.Runtime.InteropServices;
public class AgentLinkWin32 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
}
"@
      $prompt = Get-Content -Raw -Encoding UTF8 -LiteralPath '${escapePowerShell(promptPath)}'
      $oldForeground = [AgentLinkWin32]::GetForegroundWindow()
      $oldClipboard = $null
      try { $oldClipboard = Get-Clipboard -Raw -Format Text -ErrorAction SilentlyContinue } catch {}
      $proc = (@(Get-Process ChatGPT -ErrorAction SilentlyContinue) + @(Get-Process Codex -ErrorAction SilentlyContinue)) |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
      if (-not $proc) { throw 'Codex desktop window not found' }
      if (${options.requireIdle ? "$true" : "$false"}) {
        $info = New-Object AgentLinkWin32+LASTINPUTINFO
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
        [AgentLinkWin32]::GetLastInputInfo([ref]$info) | Out-Null
        $idleMs = [Environment]::TickCount - $info.dwTime
        if ($idleMs -lt 30000) { throw "PC is active; desktop takeover requires 30s idle, current idle $idleMs ms" }
      }
      [AgentLinkWin32]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null
      [AgentLinkWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
      Start-Sleep -Milliseconds 450
      if (${options.newSession ? "$true" : "$false"}) {
        [System.Windows.Forms.SendKeys]::SendWait('^n')
        Start-Sleep -Milliseconds 650
      }
      $rect = New-Object AgentLinkWin32+RECT
      [AgentLinkWin32]::GetWindowRect($proc.MainWindowHandle, [ref]$rect) | Out-Null
      $x = [int](($rect.Left + $rect.Right) / 2)
      $y = [int]($rect.Bottom - 90)
      [AgentLinkWin32]::SetCursorPos($x, $y) | Out-Null
      [AgentLinkWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      [AgentLinkWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 250
      [System.Windows.Forms.SendKeys]::SendWait('^a')
      Start-Sleep -Milliseconds 100
      [System.Windows.Forms.Clipboard]::SetText($prompt, [System.Windows.Forms.TextDataFormat]::UnicodeText)
      Start-Sleep -Milliseconds 200
      [System.Windows.Forms.SendKeys]::SendWait('^v')
      Start-Sleep -Milliseconds 350
      [System.Windows.Forms.SendKeys]::SendWait('^{ENTER}')
      Start-Sleep -Milliseconds 250
      $sendX = [int]($rect.Right - 76)
      $sendY = [int]($rect.Bottom - 88)
      [AgentLinkWin32]::SetCursorPos($sendX, $sendY) | Out-Null
      [AgentLinkWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      [AgentLinkWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 800
      if ($null -ne $oldClipboard) { try { [System.Windows.Forms.Clipboard]::SetText($oldClipboard, [System.Windows.Forms.TextDataFormat]::UnicodeText) } catch {} }
      if (${options.restoreForegroundWindow ? "$true" : "$false"} -and $oldForeground -ne [IntPtr]::Zero -and $oldForeground -ne $proc.MainWindowHandle) {
        [AgentLinkWin32]::SetForegroundWindow($oldForeground) | Out-Null
      }
      Write-Output 'sent'
    `;
    const result = await runPowerShell(script, 15_000);
    if (result.code !== 0) throw new Error(result.stderr || result.stdout || `PowerShell exited ${result.code}`);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function runPowerShell(script: string, timeoutMs: number) {
  return new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve, reject) => {
    const encoded = Buffer.from(script, "utf16le").toString("base64");
    const child = spawn("powershell.exe", ["-NoProfile", "-Sta", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded], {
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("PowerShell UI control timed out"));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

async function waitForNewSessionId(knownIds: Set<string>, cwd: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  const normalizedCwd = normalizePath(cwd);
  while (Date.now() < deadline) {
    await delay(1_000);
    const session = listCodexHistorySessions(20).find((candidate) =>
      !knownIds.has(candidate.id)
      && (!candidate.cwd || normalizePath(candidate.cwd) === normalizedCwd || normalizePath(candidate.cwd).startsWith(`${normalizedCwd}/`)));
    if (session) return session.id;
  }
  return undefined;
}

function escapePowerShell(value: string) {
  return value.replace(/'/g, "''");
}

function normalizePath(value: string) {
  return value.replace(/\\/g, "/").replace(/\/+$/g, "").toLowerCase();
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
