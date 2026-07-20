import crypto from "node:crypto";
import { concatBytes, encodeIntField, encodeStringField, intField, boolField, messageFields, parseFields, stringField } from "./protobuf.mjs";

const DEFAULT_BASE_URL = "https://api.et-api.com/";
const SIGN_VERSION = "2023-08-28";

function nonce() {
  return crypto.randomUUID().replaceAll("-", "");
}

export function signRequest(method, url, now = Math.floor(Date.now() / 1000), requestNonce = nonce()) {
  const parsed = new URL(url);
  const params = new Map(parsed.searchParams.entries());
  params.set("ts", String(now));
  params.set("nonce", requestNonce);
  params.set("ver", SIGN_VERSION);
  const sorted = [...params.keys()].sort().map((key) => {
    const value = params.get(key);
    return `${key}=${value == null ? "" : encodeURIComponent(value)}`;
  }).join("&");
  const authority = parsed.port && parsed.port !== "80" && parsed.port !== "443"
    ? `${parsed.host}${parsed.pathname}`
    : `${parsed.hostname}${parsed.pathname}`;
  const canonical = `${method.toUpperCase()}${authority}?${sorted}`;
  const sig = crypto.createHash("sha256").update(canonical, "utf8").digest("hex");
  parsed.search = `${sorted}&sig=${sig}`;
  return parsed;
}

export function decodeAdActivity(buffer) {
  const fields = parseFields(buffer);
  const stages = messageFields(fields, 3).map((stage) => ({
    id: intField(stage, 1),
    hasAward: boolField(stage, 2),
    award: intField(stage, 3),
    isGet: boolField(stage, 4),
  }));
  const userWatchCnt = intField(fields, 1);
  const nextVideoCnt = intField(fields, 5);
  const nextVideoAward = intField(fields, 6);
  return {
    userWatchCnt,
    videoCnt: intField(fields, 2),
    stages,
    watched: boolField(fields, 4),
    nextVideoCnt,
    nextVideoAward,
    complete: nextVideoCnt === 0,
  };
}

export function encodeLoginRequest(phoneNumber, verificationCode, password = "", channel = "official") {
  return concatBytes(
    encodeStringField(1, phoneNumber),
    encodeStringField(2, verificationCode),
    encodeStringField(3, password),
    encodeStringField(4, channel),
  );
}

export function decodeLoginResponse(buffer) {
  const fields = parseFields(buffer);
  return { userId: intField(fields, 1), authorization: new TextDecoder().decode(fields.find((f) => f.fieldNo === 2)?.value ?? new Uint8Array()) };
}

export function decodeApiError(buffer) {
  const fields = parseFields(buffer);
  return {
    code: intField(fields, 1),
    message: stringField(fields, 2),
    detail: stringField(fields, 3),
    timestamp: intField(fields, 4),
  };
}

export function decodeWxQrState(buffer) {
  const fields = parseFields(buffer);
  return {
    phone: stringField(fields, 1),
    userId: intField(fields, 2),
    authorization: stringField(fields, 3),
    bindId: intField(fields, 4),
  };
}

export class EtalienClient {
  constructor({ token = "", dvc = "", channel = "official", baseUrl = DEFAULT_BASE_URL, fetchImpl = fetch } = {}) {
    this.token = token;
    this.dvc = dvc;
    this.channel = channel;
    this.baseUrl = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
    this.fetchImpl = fetchImpl;
  }

  async requestRaw(path, { method = "GET", body, contentType = "application/x-protobuf" } = {}) {
    const url = signRequest(method, new URL(path.replace(/^\//, ""), this.baseUrl).toString());
    const headers = {
      "accept": "application/x-protobuf",
      "x-eta": `os=0&ver=3.13.10&dvc=${this.dvc}&ch=${this.channel}`,
    };
    if (this.token) headers.authorization = this.token;
    if (body) {
      headers["content-type"] = contentType;
      headers["content-length"] = String(body.length);
    }
    const response = await this.fetchImpl(url, { method, headers, body });
    const data = new Uint8Array(await response.arrayBuffer());
    return { ok: response.ok, status: response.status, data };
  }

  async request(path, options = {}) {
    const result = await this.requestRaw(path, options);
    if (!result.ok) {
      let detail;
      try {
        const error = decodeApiError(result.data);
        detail = `${error.code} ${error.message} ${error.detail}`.trim();
      } catch {
        detail = new TextDecoder().decode(result.data).slice(0, 500);
      }
      throw new Error(`${options.method || "GET"} ${path} failed: HTTP ${result.status} ${detail}`);
    }
    return result.data;
  }

  async getAdActivity() {
    return decodeAdActivity(await this.request("/award/v1/ad/activity"));
  }

  async requestLoginCode(phoneNumber) {
    return this.request(`/account/v1/get_login_verification_code?phone_number=${encodeURIComponent(phoneNumber)}`);
  }

  async login(phoneNumber, verificationCode, password = "") {
    const body = encodeLoginRequest(phoneNumber, verificationCode, password, this.channel);
    return decodeLoginResponse(await this.request("/account/v1/login", { method: "POST", body }));
  }


  async getWxQrUrl(type = 0) {
    const body = encodeIntField(1, type);
    const fields = parseFields(await this.request("/v2/account/wx/qrcode/url", { method: "POST", body }));
    const url = stringField(fields, 1);
    if (!url) throw new Error("QR URL response did not include a URL");
    return { url, state: new URL(url).searchParams.get("state") || "" };
  }

  async getWxQrState(uuid) {
    const body = encodeStringField(1, uuid);
    const result = await this.requestRaw("/v2/account/wx/qrcode/login/state", { method: "POST", body });
    if (result.ok) return { pending: false, ...decodeWxQrState(result.data) };
    const error = decodeApiError(result.data);
    if (result.status === 500 && error.detail.includes("not found bind info")) {
      return { pending: true, error };
    }
    throw new Error(`QR state failed: HTTP ${result.status} ${error.code} ${error.message} ${error.detail}`);
  }
}
