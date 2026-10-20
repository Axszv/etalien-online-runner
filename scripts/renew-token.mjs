// Keep the ETAlien session token fresh without interrupting the daily run.
//
// Order of preference:
//   1. POST /v2/account/refresh/token with the token we already have. The
//      server rotates it and keeps the old one valid, so this is the cheap
//      path and needs no credentials.
//   2. If the token is already rejected (expired after ~90 days), fall back
//      to a phone + password login, which is what the app itself does.
//
// The rotated token is printed to stdout so the caller can store it, and the
// source ("refresh" or "login") is printed as well so the caller can report
// which path was taken.
import fs from "node:fs";
import crypto from "node:crypto";
import { EtalienClient } from "../src/client.mjs";

const channel = process.env.ETALIEN_CHANNEL || "official";

function loadLocalSession() {
  try {
    return JSON.parse(fs.readFileSync(new URL("../.session.json", import.meta.url), "utf8"));
  } catch {
    return {};
  }
}

function loadLocalDevice() {
  const deviceFile = new URL("../.device.json", import.meta.url);
  try {
    return JSON.parse(fs.readFileSync(deviceFile, "utf8"));
  } catch {
    const device = { dvc: crypto.randomUUID().replaceAll("-", "") };
    fs.writeFileSync(deviceFile, JSON.stringify(device, null, 2), { mode: 0o600 });
    return device;
  }
}

function normalizePhone(phone) {
  // The API validates PhoneNumber to 14 bytes (E.164 with the +86 country
  // code); a bare 11-digit mainland number fails the 'len' tag with a 500.
  if (!phone.startsWith("+") && /^1\d{10}$/.test(phone)) return `+86${phone}`;
  return phone;
}

async function main() {
  const localSession = loadLocalSession();
  const localDevice = loadLocalDevice();
  const currentToken = process.env.ETALIEN_TOKEN || localSession.authorization || "";
  const dvc = process.env.ETALIEN_DVC || localSession.dvc || localDevice.dvc;

  if (currentToken) {
    const client = new EtalienClient({ token: currentToken, dvc, channel });
    try {
      const { token } = await client.refreshToken();
      console.log("source=refresh");
      console.log(`token=${token}`);
      return;
    } catch (error) {
      console.log(`refresh_failed=${String(error.message).replace(/\s+/g, " ").slice(0, 200)}`);
    }
  }

  const phone = process.env.ETALIEN_PHONE || "";
  const password = process.env.ETALIEN_PASSWORD || "";
  if (!phone || !password) {
    throw new Error("token refresh failed and ETALIEN_PHONE/ETALIEN_PASSWORD are not configured");
  }
  const client = new EtalienClient({ token: "", dvc, channel });
  const session = await client.loginPassword(normalizePhone(phone), password);
  if (!session.authorization) throw new Error("phone login returned no authorization token");
  console.log("source=login");
  console.log(`token=${session.authorization}`);
}

await main();
