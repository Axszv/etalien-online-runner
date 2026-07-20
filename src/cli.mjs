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

  if (command === "login-password") {
    const phone = process.argv[3];
    const password = process.argv[4];
    if (!phone || !password) throw new Error("usage: node src/cli.mjs login-password PHONE PASSWORD");
    const session = await client.loginPassword(phone, password);
    if (!session.authorization) throw new Error("phone binding succeeded without an authorization token");
    fs.writeFileSync(new URL("../.session.json", import.meta.url), JSON.stringify({
      ...session,
      dvc: client.dvc,
      channel: client.channel,
    }, null, 2), { mode: 0o600 });
    console.log(JSON.stringify({ ok: true, userId: session.userId }, null, 2));
    return;
  }

  throw new Error(`unknown command: ${command}`);
}

await main();
