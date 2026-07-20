import fs from "node:fs";
import crypto from "node:crypto";
import { EtalienClient } from "./client.mjs";

const command = process.argv[2] || "inspect";
let localSession = {};
try {
  localSession = JSON.parse(fs.readFileSync(new URL("../.session.json", import.meta.url), "utf8"));
} catch {
  // A session file is optional; deployments should use environment secrets.
}
const deviceFile = new URL("../.device.json", import.meta.url);
let localDevice = {};
try {
  localDevice = JSON.parse(fs.readFileSync(deviceFile, "utf8"));
} catch {
  localDevice = { dvc: crypto.randomUUID().replaceAll("-", "") };
  fs.writeFileSync(deviceFile, JSON.stringify(localDevice, null, 2), { mode: 0o600 });
}
const client = new EtalienClient({
  token: process.env.ETALIEN_TOKEN || localSession.authorization,
  dvc: process.env.ETALIEN_DVC || localSession.dvc || localDevice.dvc,
  channel: process.env.ETALIEN_CHANNEL || localSession.channel || "official",
});

async function main() {
  if (command === "inspect") {
    const task = await client.getAdActivity();
    console.log(JSON.stringify(task, null, 2));
    return;
  }

  if (command === "login-code") {
    const phone = process.argv[3];
    if (!phone) throw new Error("usage: node src/cli.mjs login-code PHONE");
    await client.requestLoginCode(phone);
    console.log("verification code requested");
    return;
  }

  if (command === "login") {
    const phone = process.argv[3];
    const code = process.argv[4];
    if (!phone || !code) throw new Error("usage: node src/cli.mjs login PHONE CODE");
    const session = await client.login(phone, code);
    fs.writeFileSync(new URL("../.session.json", import.meta.url), JSON.stringify({
      ...session,
      dvc: client.dvc,
      channel: client.channel,
    }, null, 2), { mode: 0o600 });
    const masked = session.authorization
      ? `${session.authorization.slice(0, 4)}...${session.authorization.slice(-4)}`
      : "";
    console.log(JSON.stringify({ userId: session.userId, authorization: masked }, null, 2));
    console.error("Saved the full session to the ignored .session.json file.");
    return;
  }

  if (command === "qr-start") {
    const qr = await client.getWxQrUrl(Number(process.argv[3] || 0));
    fs.writeFileSync(new URL("../.qr-session.json", import.meta.url), JSON.stringify({
      ...qr,
      dvc: client.dvc,
      channel: client.channel,
      createdAt: new Date().toISOString(),
    }, null, 2), { mode: 0o600 });
    console.log(JSON.stringify(qr, null, 2));
    return;
  }

  if (command === "qr-poll") {
    const qrFile = new URL("../.qr-session.json", import.meta.url);
    const qr = JSON.parse(fs.readFileSync(qrFile, "utf8"));
    client.dvc = qr.dvc;
    const timeoutAt = Date.now() + Number(process.env.ETALIEN_QR_TIMEOUT_MS || 180000);
    while (Date.now() < timeoutAt) {
      const state = await client.getWxQrState(qr.state);
      if (state.pending) {
        await new Promise((resolve) => setTimeout(resolve, 3000));
        continue;
      }
      if (state.authorization) {
        fs.writeFileSync(new URL("../.session.json", import.meta.url), JSON.stringify({
          ...state,
          dvc: client.dvc,
          channel: client.channel,
        }, null, 2), { mode: 0o600 });
        console.log(JSON.stringify({ ok: true, userId: state.userId, phone: state.phone, bindId: state.bindId }, null, 2));
        return;
      }
      if (state.bindId) {
        throw new Error(`WeChat account requires phone binding (bindId ${state.bindId})`);
      }
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
    throw new Error("QR authorization timed out; run qr-start again");
  }

  throw new Error(`unknown command: ${command}`);
}

await main();
