import qrcodeTerminal from "qrcode-terminal";
import { buildRelayServer } from "./server.js";

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? "0.0.0.0";

const app = await buildRelayServer();
await app.listen({ host, port });

const publicUrl = (process.env.AGENTLINK_PUBLIC_URL ?? `http://127.0.0.1:${port}`).replace(/\/$/, "");
const payload = `agentlink://bridge?url=${encodeURIComponent(publicUrl)}${process.env.AGENTLINK_RELAY_SECRET ? `&token=${encodeURIComponent(process.env.AGENTLINK_RELAY_SECRET)}` : ""}`;
console.log(`AgentLink Relay listening on ${publicUrl}`);
console.log(`Pairing page: ${publicUrl}/pair`);
console.log("Scan this QR in AgentLink Android Settings -> QR import:");
qrcodeTerminal.generate(payload, { small: true });
