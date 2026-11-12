import { describe, expect, it } from "vitest";
import { handle, sameToken, type Env } from "../src/index";

const env: Env = { APP_TOKEN: "app-token", NCKU_STT_TOKEN: "stt", SPEECH_WORKER_TOKEN: " speech ", NCKU_TTS_TOKEN: "" };
const get = (path: string, token?: string, method = "GET") =>
  new Request(`https://keys.example${path}`, { method, headers: token ? { authorization: `Bearer ${token}` } : {} });

describe("key worker", () => {
  it("returns only the configured keys, trimmed and uncached", async () => {
    const response = await handle(get("/v1/keys", "app-token"), env);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ keys: { NCKU_STT_TOKEN: "stt", SPEECH_WORKER_TOKEN: "speech" } });
  });

  it("never returns its own token or other secrets", async () => {
    const response = await handle(get("/v1/keys", "app-token"), { ...env, OTHER: "x" } as Env);
    const body = JSON.stringify(await response.json());
    expect(body).not.toContain("app-token");
    expect(body).not.toContain("OTHER");
  });

  it("rejects a missing or wrong token", async () => {
    expect((await handle(get("/v1/keys"), env)).status).toBe(401);
    expect((await handle(get("/v1/keys", "wrong"), env)).status).toBe(401);
  });

  it("is misconfigured without its own token", async () => {
    expect((await handle(get("/v1/keys", ""), { ...env, APP_TOKEN: "" })).status).toBe(500);
  });

  it("handles other routes and methods", async () => {
    expect((await handle(get("/health"), env)).status).toBe(200);
    expect((await handle(get("/v1/other", "app-token"), env)).status).toBe(404);
    expect((await handle(get("/v1/keys", "app-token", "POST"), env)).status).toBe(405);
  });

  it("applies the rate limiter", async () => {
    const limited = { ...env, KEY_RATE_LIMITER: { limit: async () => ({ success: false }) } as unknown as RateLimit };
    expect((await handle(get("/v1/keys", "app-token"), limited)).status).toBe(429);
  });

  it("compares tokens exactly", () => {
    expect(sameToken("abc", "abc")).toBe(true);
    expect(sameToken("abc", "abcd")).toBe(false);
    expect(sameToken("", "")).toBe(false);
  });
});
