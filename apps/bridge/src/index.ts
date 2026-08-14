import { buildServer } from "./server.js";
import qrcodeTerminal from "qrcode-terminal";
import { buildPairingInfo } from "./pairing.js";
import { startCloudRelayClient } from "./cloud-relay.js";

const requestedPort = Number(process.env.PORT ?? 4317);
const host = process.env.HOST ?? "0.0.0.0";
const autoPort = process.env.AGENTLINK_AUTO_PORT !== "0";
const maxPort = Number(process.env.AGENTLINK_MAX_PORT ?? requestedPort + 20);

await startBridge();

async function startBridge() {
  for (let port = requestedPort; port <= maxPort; port += 1) {
    const app = await buildServer(undefined, { port, host });
    try {
      await app.listen({ host, port });
      const pairing = buildPairingInfo(port, host);
      printPairing("AgentLink Bridge listening", pairing.preferredUrl, pairing.payload);
      startCloudRelayClient({ localPort: port });
      return;
    } catch (error) {
      await app.close().catch(() => undefined);
      if (!isAddressInUse(error)) throw error;

      const existing = await readExistingBridge(port);
      if (existing?.payload) {
        printPairing("AgentLink Bridge already running", existing.preferredUrl ?? `http://127.0.0.1:${port}`, existing.payload);
        return;
      }

      if (!autoPort || port >= maxPort) {
        throw new Error(`Port ${port} is already in use. Set PORT to another port or enable AGENTLINK_AUTO_PORT=1.`);
      }
      console.log(`Port ${port} is busy; trying ${port + 1}...`);
    }
  }
}

function printPairing(prefix: string, preferredUrl: string, payload: string) {
  console.log(`${prefix} on ${preferredUrl}`);
  console.log(`Manager page: ${preferredUrl}/manage`);
  console.log(`Pairing page: ${preferredUrl}/pair`);
  console.log("Scan this QR in AgentLink Android Settings -> QR import:");
  qrcodeTerminal.generate(payload, { small: true });
}

function isAddressInUse(error: unknown) {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: string }).code === "EADDRINUSE";
}

async function readExistingBridge(port: number) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/v1/pairing`, { signal: AbortSignal.timeout(1200) });
    if (!response.ok) return undefined;
    const value = await response.json() as { service?: string; preferredUrl?: string; payload?: string };
    return value.service === "agent-link-bridge" ? value : undefined;
  } catch {
    return undefined;
  }
}
