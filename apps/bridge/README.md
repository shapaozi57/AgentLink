# Agent Link Bridge

Windows desktop companion service for the Android client. This initial version exposes a local mock Codex task stream so the mobile client can develop against a stable contract.

## Run

```powershell
cd apps/bridge
npm install
npm run dev
```

The service listens on `http://localhost:4317` by default. Set `PORT` to use another port.
If `4317` is already occupied, the launcher now checks whether an AgentLink Bridge is already running; otherwise it automatically tries the next port up to `4337` unless `AGENTLINK_AUTO_PORT=0` is set.

## Windows Manager

Double-click the desktop shortcut **AgentLink Bridge Manager** or run:

```powershell
tooling\scripts\agentlink-bridge-manager.bat
```

The manager can start, stop, restart, inspect diagnostics, open logs, copy the current Bridge URL, and open the pairing QR. It writes logs to `tooling\logs\bridge-manager.log`.

The web manager is available while Bridge is running:

- `GET /manage`
- `GET /v1/diagnostics`

## Endpoints

- `GET /v1/health`
- `GET /v1/diagnostics`
- `GET /manage`
- `GET /v1/workspaces`
- `GET /v1/workspaces/local-demo/tree`
- `GET`, `POST /v1/sessions`
- `GET`, `POST /v1/tasks`
- `POST /v1/tasks/:id/cancel`
- `GET /v1/artifacts/:taskId/preview.html`
- `WS /v1/events`

Task creation emits `task.status`, `task.output`, `artifact.ready`, and a final `task.status` event. The implementation is deliberately in-memory and resets when the service restarts.

`POST /v1/tasks` accepts an optional `agentId`. It defaults to `mock`; use `codex` to run `codex exec` in `AGENTLINK_WORKSPACE` (or the Bridge working directory). Override the executable with `CODEX_BINARY`. Missing or failing CLI processes emit a structured `task.error` event and set the task status to `failed`.

## Check

```powershell
npm run check
npm test
```
