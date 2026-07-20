import test from "node:test";
import assert from "node:assert/strict";
import { decodeAdActivity, decodeWxQrState, signRequest } from "../src/client.mjs";
import { encodeVarint, encodeStringField, concatBytes } from "../src/protobuf.mjs";

test("signRequest follows the Android canonical ordering", () => {
  const signed = signRequest("GET", "https://api.et-api.com/award/v1/ad/activity?z=last&a=first", 1700000000, "abc123");
  assert.match(signed.toString(), /[?&]sig=[0-9a-f]{64}$/);
  assert.match(signed.toString(), /a=first&nonce=abc123&ts=1700000000&ver=2023-08-28&z=last/);
});

test("decodeWxQrState reads an authorized session", () => {
  const data = concatBytes(
    encodeStringField(1, "13800000000"),
    encodeVarint(16n), encodeVarint(42n),
    encodeStringField(3, "TOKEN"),
    encodeVarint(32n), encodeVarint(0n),
  );
  assert.deepEqual(decodeWxQrState(data), {
    phone: "13800000000",
    userId: 42,
    authorization: "TOKEN",
    bindId: 0,
  });
});

test("decodeAdActivity reads current progress and reward ladder", () => {
  const stage = concatBytes(encodeVarint(8n | 0n), encodeVarint(1n), encodeVarint(16n), encodeVarint(1n), encodeVarint(24n), encodeVarint(60n), encodeVarint(32n), encodeVarint(1n));
  const data = concatBytes(
    encodeVarint(8n), encodeVarint(2n),
    encodeVarint(26n), encodeVarint(BigInt(stage.length)), stage,
    encodeVarint(40n), encodeVarint(3n),
    encodeVarint(48n), encodeVarint(60n),
  );
  assert.deepEqual(decodeAdActivity(data), {
    userWatchCnt: 2,
    videoCnt: 0,
    stages: [{ id: 1, hasAward: true, award: 60, isGet: true }],
    watched: false,
    nextVideoCnt: 3,
    nextVideoAward: 60,
    complete: false,
  });
});
