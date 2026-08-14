import os from "node:os";

export interface PairingInfo {
  urls: string[];
  preferredUrl: string;
  payload: string;
}

export function buildPairingInfo(port: number, host = "0.0.0.0"): PairingInfo {
  const urls = getBridgeUrls(port, host);
  const preferredUrl = urls[0] ?? `http://127.0.0.1:${port}`;
  return { urls, preferredUrl, payload: pairingPayload(preferredUrl) };
}

export function pairingPayload(url: string) {
  return `agentlink://bridge?url=${encodeURIComponent(url)}`;
}

export function getBridgeUrls(port: number, host = "0.0.0.0") {
  if (host && host !== "0.0.0.0" && host !== "::") return [`http://${host}:${port}`];
  const addresses = new Set<string>();
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      if (entry.address.startsWith("169.254.")) continue;
      addresses.add(entry.address);
    }
  }
  const sorted = [...addresses].sort(compareBridgeAddress);
  sorted.push("127.0.0.1");
  return sorted.map((address) => `http://${address}:${port}`);
}

function compareBridgeAddress(a: string, b: string) {
  return addressScore(a) - addressScore(b) || a.localeCompare(b, undefined, { numeric: true });
}

function addressScore(address: string) {
  const octets = address.split(".").map(Number);
  const [a, b, , d] = octets;
  const isPrivate = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  if (isPrivate && d !== 1) return 0;
  if (isPrivate) return 1;
  return 2;
}
