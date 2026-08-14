# AgentLink 开发文档

## 1. 仓库结构

```text
Agent互联app/
  apps/
    bridge/              # Windows Bridge, Node.js + TypeScript + Fastify
    mobile/              # Flutter Android App
  packages/
    protocol/            # 共享类型草案
  docs/
    DEVELOPMENT.md       # 当前开发文档
  tooling/
    scripts/             # Windows 启动脚本
```

## 2. 环境安装

### Node / pnpm

```powershell
node -v
pnpm -v
pnpm install --registry=https://registry.npmmirror.com/
```

### Flutter

已安装位置：

```text
C:\src\flutter
```

推荐环境变量：

```powershell
$env:PATH = 'C:\src\flutter\bin;' + $env:PATH
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
```

当前项目还创建了 ASCII 路径 junction，规避部分 Flutter analysis server 对中文路径的 LSP JSON 解析异常：

```text
C:\agentlink-work -> C:\Users\Administrator\Documents\ChatGPT\Agent互联app
```

## 3. Bridge 开发

### 启动

```powershell
pnpm dev:bridge
```

默认监听：

```text
http://127.0.0.1:4317
```

`apps/bridge/src/index.ts` 使用 `0.0.0.0` 监听，真机访问时使用 Windows 局域网 IP。

启动后终端会打印 AgentLink 配对二维码。电脑端也提供配对页：

```text
http://YOUR_PC_LAN_IP:4317/pair
```

配对相关接口：

```text
GET /v1/pairing
GET /v1/pairing/qrcode.svg
GET /pair
```

项目相关接口：

```text
GET /v1/workspaces
GET /v1/workspaces/:id/tree
POST /v1/sessions
POST /v1/tasks
```

`/v1/workspaces` 会扫描 `AGENTLINK_PROJECT_ROOTS`、当前启动目录、`Documents\ChatGPT`、`Documents`、`Desktop` 等常用位置。手机端选择某个 workspace 后，Bridge 创建 session 时会记录 `workspacePath`，后续 `codex exec` 会在该目录中执行。

### 验证

```powershell
pnpm check
pnpm test
```

### Adapter

当前 Adapter：

- `mock`：稳定模拟任务事件，供 UI 和协议联调。
- `codex`：调用本地 Codex CLI，支持检测、启动、输出转发、取消、结构化错误和 HTML 预览产物。

创建任务时可传：

```json
{
  "sessionId": "ses_xxx",
  "agentId": "mock",
  "prompt": "Create a preview page"
}
```

Bridge API 不传 `agentId` 时默认走 `mock`；Android App 当前默认传 `codex`，用于真实 Codex 任务流。

## 4. Mobile 开发

### 获取依赖

```powershell
cd apps/mobile
flutter pub get
```

### 本地验证

```powershell
dart format --set-exit-if-changed lib test
dart analyze --fatal-infos
flutter test
```

`flutter analyze` 推荐在 ASCII junction 下运行：

```powershell
cd C:\agentlink-work\apps\mobile
flutter analyze
```

### 构建 debug APK

```powershell
cd C:\agentlink-work\apps\mobile
flutter build apk --debug --android-skip-build-dependency-validation
```

输出：

```text
C:\agentlink-work\apps\mobile\build\app\outputs\flutter-apk\app-debug.apk
```

### Bridge URL

默认：

```text
http://10.0.2.2:4317
```

Android 模拟器用 `10.0.2.2` 访问宿主机。真机使用：

```powershell
flutter run --dart-define=BRIDGE_URL=http://YOUR_PC_LAN_IP:4317
```

现在 App 设置页支持运行时配置 Bridge URL，不需要每次换 IP 都重新打包：

1. 打开电脑端 Bridge：`pnpm dev:bridge`。
2. 手机进入 `设置`。
3. 手动填写 `http://YOUR_PC_LAN_IP:4317`，点击 `测试连接`。
4. 测试成功后点击 `保存并连接`。
5. 或点击 `扫码导入`，扫描电脑终端二维码或 `/pair` 页面二维码。

任务页创建任务时会调用真实 `codex` Adapter；任务详情页可查看实时输出、取消运行中任务。普通问答不再自动创建 `preview.html`，只有 Bridge 返回真实产物时，预览页才会用 WebView 打开。

任务输入框左侧是发送目标选择器：

- `项目名`：在该项目目录里运行 Codex。
- `仅对话`：用 Codex 只读模式回答问题，不写入项目文件。

项目选择：

1. 进入 `项目` Tab。
2. 点击顶部 `当前项目` 卡片或 `切换` 按钮。
3. 在项目列表里搜索或选择目录。
4. 选择后文件树会刷新，新任务会在这个项目目录里运行 Codex。

## 5. Windows 脚本

Bridge：

```powershell
tooling\scripts\start-bridge.bat
```

Mobile：

```powershell
tooling\scripts\run-mobile-android.bat http://YOUR_PC_LAN_IP:4317
```

BAT 文件只保留 ASCII 文案。

## 6. 当前验证记录

```text
pnpm check                         PASS
pnpm test                          PASS, 5 tests
flutter pub get                    PASS
flutter test                       PASS, 1 test
flutter analyze                    PASS via C:\agentlink-work
flutter build apk --debug          PASS
```

## 7. 下一步开发路线

1. 加入 token 鉴权和设备公钥签名。
2. 实现文件打开/编辑与 Markdown / Word 原生预览。
3. 增强 CodexAdapter：会话恢复、工具调用结构化、任务输出去重。
4. 增加任务事件持久化和断线补偿。
5. 做 Bridge 托盘程序或 Windows 服务包装。
6. 加入 Cursor / Trae / Claude Code / WorkBuddy Adapter。
