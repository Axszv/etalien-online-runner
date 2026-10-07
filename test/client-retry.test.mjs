import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { EtalienClient } from "../src/client.mjs";

function okResponse(payload = new Uint8Array([1, 2, 3])) {
  return { ok: true, status: 200, arrayBuffer: async () => payload.buffer };
}

describe("EtalienClient retries", () => {
  it("retries network failures and succeeds", async () => {
    let calls = 0;
    const client = new EtalienClient({
      token: "t",
      dvc: "d",
      fetchImpl: async () => {
        calls += 1;
        if (calls < 3) throw new TypeError("fetch failed");
        return okResponse();
      },
      retryBaseDelayMs: 1,
    });
    const data = await client.request("/award/v1/ad/activity");
    assert.equal(calls, 3);
    assert.deepEqual([...data], [1, 2, 3]);
  });

  it("gives up after maxAttempts and rethrows", async () => {
    let calls = 0;
    const client = new EtalienClient({
      token: "t",
      dvc: "d",
      fetchImpl: async () => {
        calls += 1;
        throw new TypeError("fetch failed");
      },
      maxAttempts: 2,
      retryBaseDelayMs: 1,
    });
    await assert.rejects(() => client.request("/award/v1/ad/activity"), /fetch failed/);
    assert.equal(calls, 2);
  });

  it("does not retry a 401 (expired token must fail fast)", async () => {
    let calls = 0;
    const client = new EtalienClient({
      token: "t",
      dvc: "d",
      fetchImpl: async () => {
        calls += 1;
        return { ok: false, status: 401, arrayBuffer: async () => new Uint8Array().buffer };
      },
      retryBaseDelayMs: 1,
    });
    await assert.rejects(() => client.request("/award/v1/ad/activity"), /HTTP 401/);
    assert.equal(calls, 1);
  });

  it("retries a 500 and then succeeds", async () => {
    let calls = 0;
    const client = new EtalienClient({
      token: "t",
      dvc: "d",
      fetchImpl: async () => {
        calls += 1;
        if (calls === 1) {
          return { ok: false, status: 503, arrayBuffer: async () => new Uint8Array().buffer };
        }
        return okResponse();
      },
      retryBaseDelayMs: 1,
    });
    await client.request("/award/v1/ad/activity");
    assert.equal(calls, 2);
  });
});
