import { CodexCliAdapter } from "./codex-cli.js";
import { CodexDesktopUiAdapter } from "./codex-desktop-ui.js";
import type { AdapterEvent, AgentAdapter, AgentAvailability, AgentRunRequest } from "./types.js";

export class CodexAutoAdapter implements AgentAdapter {
  readonly id = "codex";

  constructor(
    private readonly cli = new CodexCliAdapter(),
    private readonly desktop = new CodexDesktopUiAdapter(),
  ) {}

  async checkAvailability(): Promise<AgentAvailability> {
    const cli = await this.cli.checkAvailability();
    if (cli.available) return { ...cli, version: `auto:cli:${cli.version ?? "unknown"}` };
    const desktop = await this.desktop.checkAvailability();
    if (desktop.available) return { ...desktop, version: `auto:desktop:${desktop.version ?? "unknown"}` };
    return { available: false, reason: `CLI: ${cli.reason ?? "unavailable"}; Desktop: ${desktop.reason ?? "unavailable"}` };
  }

  async run(request: AgentRunRequest) {
    const requestedMode = request.controlMode ?? "auto";

    if (requestedMode === "desktop") {
      if (request.allowDesktopTakeover === false) {
        request.emit({
          type: "error",
          code: "CODEX_DESKTOP_TAKEOVER_DISABLED",
          message: "桌面接管已关闭，请改用自动/后台模式或在设置里允许桌面接管。",
        });
        return;
      }
      request.emit({ type: "control", controlMode: "desktop", label: "桌面接管", reason: "用户手动选择桌面接管模式", desktopMayStealFocus: true });
      await this.desktop.run(request);
      return;
    }

    request.emit({
      type: "control",
      controlMode: "cli",
      label: requestedMode === "cli" ? "后台 Codex" : "自动：先走后台 Codex",
      reason: requestedMode === "cli" ? "用户手动选择后台模式" : "自动模式优先使用后台 CLI，避免打扰电脑桌面",
      desktopMayStealFocus: false,
    });

    const capturedErrors: AdapterEvent[] = [];
    await this.cli.run({
      ...request,
      emit: (event) => {
        if (event.type === "error") capturedErrors.push(event);
        else request.emit(event);
      },
      onCodexSessionId: (sessionId) => {
        request.onCodexSessionId?.(sessionId);
      },
    });

    const conflict = capturedErrors.find((event) => event.type === "error" && event.code === "CODEX_ACTIVE_WRITER_CONFLICT");
    const cliUnavailable = capturedErrors.find((event) => event.type === "error" && event.code === "CODEX_CLI_UNAVAILABLE");
    const cliTimeout = capturedErrors.find((event) => event.type === "error" && event.code === "CODEX_CLI_TIMEOUT");
    if (conflict || cliUnavailable || cliTimeout) {
      if (requestedMode === "cli") {
        for (const event of capturedErrors) request.emit(event);
        return;
      }

      if (request.allowDesktopTakeover === false) {
        request.emit({
          type: "error",
          code: "CODEX_DESKTOP_FALLBACK_DISABLED",
          message: conflict
            ? "后台 Codex 检测到电脑端正在写入同一会话；桌面接管已关闭，所以没有继续发送。"
            : cliTimeout
              ? "后台 Codex 长时间没有响应；桌面接管已关闭，所以没有继续发送。"
            : "Codex CLI 不可用；桌面接管已关闭，所以没有继续发送。",
          details: { reason: conflict ? "active_writer_conflict" : cliTimeout ? "cli_timeout" : "cli_unavailable" },
        });
        return;
      }

      request.emit({ type: "status", status: "running" });
      request.emit({
        type: "control",
        controlMode: "desktop",
        label: "桌面接管",
        reason: conflict ? "后台会话冲突，自动切换到桌面当前会话" : cliTimeout ? "后台长时间无响应，自动切换到桌面接管" : "Codex CLI 不可用，自动切换到桌面接管",
        desktopMayStealFocus: true,
      });
      request.emit({
        type: "output",
        stream: "stdout",
        chunk: conflict
          ? "检测到该 Codex 会话正在电脑端打开，已自动切换为桌面同步模式。\n"
          : cliTimeout
            ? "后台 Codex 长时间没有响应，已自动切换为桌面同步模式。\n"
          : "Codex CLI 不可用，已自动切换为桌面同步模式。\n",
      });
      await this.desktop.run(request);
      return;
    }

    for (const event of capturedErrors) request.emit(event);
  }

  cancel(taskId: string) {
    return this.cli.cancel(taskId) || this.desktop.cancel(taskId);
  }
}
