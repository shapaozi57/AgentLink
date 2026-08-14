# AgentLink Relay

Render 上运行的云中继服务。电脑端 Bridge 主动连接 Relay，手机端 App 通过 Relay 访问电脑端 Bridge。

## 本地启动

```powershell
$env:AGENTLINK_RELAY_SECRET="dev-secret"
pnpm --filter agent-link-relay dev
```

## Render 环境变量

- `AGENTLINK_RELAY_SECRET`：手机和电脑端共同使用的访问令牌。
- `AGENTLINK_RELAY_DEVICE_ID`：可选，默认允许任意设备 ID；正式部署建议设置为你的电脑设备 ID。
- `AGENTLINK_PUBLIC_URL`：可选，例如 `https://agentlink-relay.onrender.com`，用于生成扫码地址。
