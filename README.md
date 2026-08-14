# AgentLink

AgentLink 是一个 Android 手机端 + Windows Bridge 的本地 Agent 控制台原型。手机端负责切换设备、工作区和 Agent，Windows Bridge 负责接入本机 Codex CLI、读取项目结构、转发任务事件，并提供 HTML / Markdown / Word 等产物预览入口。

## 当前进度

- `apps/bridge`：Node.js + TypeScript + Fastify Bridge。
  - 已实现 health、工作区、目录树、会话、任务、取消、WebSocket 事件流、HTML 预览。
  - 已实现 `/pair` 配对页、`/v1/pairing` 配对信息和 `/v1/pairing/qrcode.svg` 二维码。
  - 已抽象 `AgentAdapter`，内置 `MockAgentAdapter` 和 `CodexCliAdapter` 雏形。
  - `CodexCliAdapter` 支持 CLI 检测、启动 `codex exec`、stdout/stderr 流式事件、取消进程、结构化错误和预览产物入口。
- `apps/mobile`：Flutter Android 原型。
  - 已补齐 Android 工程文件，可构建 debug APK。
  - 已实现任务、项目、预览、设备、设置五个 Tab。
  - 已接入 `BridgeClient`：REST、WebSocket、自动重连、离线 mock fallback。
  - 设置页已支持 Bridge 地址输入、本地保存、一键测试连接、扫码导入和连接状态展示。
  - 项目页已支持像 Codex 一样选择电脑端项目；新任务会在当前选中的项目目录里运行。
  - 任务默认走真实 `codex` Adapter，支持创建任务、查看实时输出、取消任务；仅在真实产物存在时才显示 WebView 预览。
  - 任务输入框左侧可选择发送目标：当前项目、其他项目或“仅对话”。
  - 运行中任务图标已增加旋转动画。
- `packages/protocol`：Bridge / App 共享领域类型草案。
- `docs/DEVELOPMENT.md`：本地开发、运行、验证和下一步路线。

## 环境

- Node.js：已验证 `v24.16.0`
- pnpm：已验证 `10.12.1`
- Flutter：已安装到 `C:\src\flutter`，已验证 `3.44.9 stable`
- Android SDK：已接受 licenses，可构建 debug APK

## 常用命令

```powershell
pnpm install
pnpm check
pnpm test
pnpm dev:bridge
```

```powershell
cd apps/mobile
flutter pub get
flutter test
flutter analyze
flutter build apk --debug --android-skip-build-dependency-validation
```

如果当前路径包含中文导致 `flutter analyze` 的 analysis server 异常，可用已创建的 ASCII junction：

```powershell
cd C:\agentlink-work\apps\mobile
flutter analyze
```

## 运行

启动 Windows Bridge：

```powershell
pnpm dev:bridge
```

Bridge 启动后会在终端打印二维码；也可以在电脑浏览器打开：

```text
http://YOUR_PC_LAN_IP:4317/pair
```

手机端进入 `设置 → 扫码导入`，扫描二维码后会自动保存 Bridge 地址并连接。

选择项目：

```text
手机 App → 项目 → 当前项目卡片 → 切换
```

Bridge 会扫描电脑端常用项目目录，例如 `Documents`、`Documents\ChatGPT` 和当前 AgentLink 项目，按最近修改时间展示。选择项目后，任务页发出的 Codex 请求会以该项目路径作为工作目录。

发送任务时，也可以直接点击输入框左侧的目标按钮：

```text
项目名       # 在该项目里创建 Codex 任务
仅对话       # 只回答问题，不写入项目文件
```

Android 模拟器访问 Windows 主机默认使用：

```text
http://10.0.2.2:4317
```

真机在同一局域网访问时，也可以在 App 设置页手动填写 Windows 局域网地址：

```text
http://YOUR_PC_LAN_IP:4317
```

构建时仍可用 Windows 的局域网 IP 作为默认值：

```powershell
cd apps/mobile
flutter run --dart-define=BRIDGE_URL=http://YOUR_PC_LAN_IP:4317
```

也可以使用脚本：

```powershell
tooling\scripts\start-bridge.bat
tooling\scripts\run-mobile-android.bat http://YOUR_PC_LAN_IP:4317
```

## 最新验证

- `pnpm check`：通过
- `pnpm test`：5 passed
- `dart analyze --fatal-infos`：通过
- `flutter test`：1 passed
- `flutter analyze`：通过（ASCII junction 路径）
- `flutter build apk --debug --android-skip-build-dependency-validation`：通过
- Debug APK：`C:\agentlink-work\apps\mobile\build\app\outputs\flutter-apk\app-debug.apk`
