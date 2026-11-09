import { afterEach, describe, expect, it, vi } from "vitest";
import { handle, sameToken, streamingMs, upstreamFailure, type Deps, type Env, type Socket } from "../src/index";

const env: Env = { YATING_API_KEY: "yating-key", APP_TOKEN: "app-token" };

/** A scripted Yating socket: `onOpen` and `onEnd` messages are sent back asynchronously. */
class FakeSocket implements Socket {
  sent: (ArrayBuffer | string)[] = [];
  closed = false;
  private listeners: Record<string, ((event: { data: unknown }) => void)[]> = {};
  constructor(
    private onOpen: (string | null)[] = ['{"status":"ok"}'],
    private onEnd: (string | null)[] = [],
  ) {
    setTimeout(() => this.emit(this.onOpen), 0);
  }
  addEventListener(type: string, listener: (event: { data: unknown }) => void): void {
    (this.listeners[type] ??= []).push(listener);
  }
  send(data: ArrayBuffer | string): void {
    this.sent.push(data);
    if (data instanceof ArrayBuffer && data.byteLength === 0) setTimeout(() => this.emit(this.onEnd), 0);
  }
  close(): void {
    this.closed = true;
  }
  emit(messages: (string | null)[]): void {
    for (const message of messages) {
      if (message === null) this.listeners.close?.forEach((l) => l({ data: undefined }));
      else this.listeners.message?.forEach((l) => l({ data: message }));
    }
  }
}

const sentence = (text: string, final: boolean) => JSON.stringify({ pipe: { asr_sentence: text, asr_final: final } });
const eof = JSON.stringify({ pipe: { asr_eof: true } });

function tokenFetch(status = 201, body: unknown = { success: true, auth_token: "a+b" }) {
  return vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), { status }),
  );
}

function deps(socket: FakeSocket | (() => Promise<Socket>), fetch = tokenFetch()): Deps & { urls: string[] } {
  const urls: string[] = [];
  return {
    fetch: fetch as unknown as typeof globalThis.fetch,
    connect: async (url) => {
      urls.push(url);
      return typeof socket === "function" ? socket() : socket;
    },
    pace: async () => {},
    readyMs: 50,
    completionMs: 50,
    tokenMs: 50,
    urls,
  };
}

function transcribe(bytes: number, token = "app-token"): Request {
  return new Request("https://speech.example/v1/transcribe", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/octet-stream" },
    body: new Uint8Array(bytes),
  });
}

afterEach(() => vi.restoreAllMocks());

describe("access", () => {
  it("answers /health without a token", async () => {
    const response = await handle(new Request("https://speech.example/health"), env);
    expect(response.status).toBe(200);
  });

  it("rejects a missing or wrong app token before touching Yating", async () => {
    const fetch = tokenFetch();
    for (const token of ["", "wrong", "app-token-longer"]) {
      const response = await handle(transcribe(4, token), env, deps(new FakeSocket(), fetch));
      expect(response.status).toBe(401);
    }
    expect(fetch).not.toHaveBeenCalled();
  });

  it("compares tokens without accepting an empty secret", () => {
    expect(sameToken("abc", "abc")).toBe(true);
    expect(sameToken("abd", "abc")).toBe(false);
    expect(sameToken("", "")).toBe(false);
  });

  it("is rate limited per client address", async () => {
    const limiter = { limit: vi.fn(async () => ({ success: false })) };
    const response = await handle(transcribe(4), { ...env, SPEECH_RATE_LIMITER: limiter as unknown as RateLimit }, deps(new FakeSocket()));
    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "rate_limited" });
  });

  it("refuses to run without its secrets", async () => {
    const response = await handle(transcribe(4), { YATING_API_KEY: "", APP_TOKEN: "app-token" }, deps(new FakeSocket()));
    expect(response.status).toBe(500);
  });

  it("rejects odd-length, empty and wrong-method requests", async () => {
    expect((await handle(transcribe(3), env, deps(new FakeSocket()))).status).toBe(400);
    expect((await handle(transcribe(0), env, deps(new FakeSocket()))).status).toBe(400);
    const get = new Request("https://speech.example/v1/transcribe", { headers: { authorization: "Bearer app-token" } });
    expect((await handle(get, env, deps(new FakeSocket()))).status).toBe(405);
    expect((await handle(new Request("https://speech.example/other"), env)).status).toBe(404);
  });
});

describe("transcribe", () => {
  it("streams the audio in 2,000-byte chunks, ends with an empty frame and joins final sentences", async () => {
    const socket = new FakeSocket(['{"status":"ok"}'], [sentence("我沒有", false), sentence("我沒有織過布", true), sentence("真的", true), eof]);
    const fetch = tokenFetch();
    const d = deps(socket, fetch);
    const response = await handle(transcribe(5_000), env, d);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "我沒有織過布，真的", sentences: 2 });
    const sizes = socket.sent.map((data) => (data as ArrayBuffer).byteLength);
    expect(sizes).toEqual([2_000, 2_000, 1_000, 0]);
    expect(socket.closed).toBe(true);
    // Token request carries the Yating key; the socket URL carries the encoded token.
    const [url, init] = fetch.mock.calls[0]!;
    expect(String(url)).toBe("https://asr.api.yating.tw/v1/token");
    expect((init!.headers as Record<string, string>).key).toBe("yating-key");
    expect(JSON.parse(String(init!.body))).toEqual({ pipeline: "asr-zh-tw-std" });
    expect(d.urls[0]).toBe("https://asr.api.yating.tw/ws/v1/?token=a%2Bb");
  });

  it("returns empty text when Yating heard nothing", async () => {
    const socket = new FakeSocket(['{"status":"ok"}'], [eof]);
    const response = await handle(transcribe(2_000), env, deps(socket));
    expect(await response.json()).toEqual({ text: "", sentences: 0 });
  });

  it("maps token failures to fixed codes without forwarding Yating's body", async () => {
    const cases: [number, string, number, string][] = [
      [402, "{}", 402, "quota"],
      [400, '{"message":"quota exceeded"}', 402, "quota"],
      [401, "{}", 502, "upstream_auth"],
      [429, "{}", 429, "upstream_rate_limit"],
      [503, "secret detail", 502, "upstream_error"],
      [400, "{}", 502, "upstream_invalid"],
    ];
    for (const [status, body, expected, code] of cases) {
      const response = await handle(transcribe(4), env, deps(new FakeSocket(), tokenFetch(status, body)));
      expect(response.status).toBe(expected);
      expect(await response.text()).toBe(JSON.stringify({ error: code }));
    }
  });

  it("reports an unreachable Yating", async () => {
    const fetch = vi.fn(async () => {
      throw new TypeError("network");
    });
    const response = await handle(transcribe(4), env, deps(new FakeSocket(), fetch as never));
    expect(await response.json()).toEqual({ error: "upstream_unreachable" });
    const socketDown = deps(async () => {
      throw new Error("refused");
    });
    expect(await (await handle(transcribe(4), env, socketDown)).json()).toEqual({ error: "upstream_unreachable" });
  });

  it("times out when Yating never says ready", async () => {
    const response = await handle(transcribe(4), env, deps(new FakeSocket([])));
    expect(response.status).toBe(504);
    expect(await response.json()).toEqual({ error: "upstream_timeout" });
  });

  it("returns the partial text when the result never completes or the socket closes", async () => {
    const stalled = new FakeSocket(['{"status":"ok"}'], [sentence("一半", true)]);
    const timedOut = await handle(transcribe(4), env, deps(stalled));
    expect(timedOut.status).toBe(504);
    expect(await timedOut.json()).toEqual({ error: "timeout", partial: "一半，" });

    const closed = new FakeSocket(['{"status":"ok"}'], [sentence("一半", false), null]);
    const response = await handle(transcribe(4), env, deps(closed));
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "upstream_closed", partial: "一半" });
  });

  it("maps a Yating error message, using quota wording only to pick the code", async () => {
    const quota = new FakeSocket(['{"status":"error","message":"insufficient balance"}']);
    expect(await (await handle(transcribe(4), env, deps(quota))).json()).toEqual({ error: "quota" });
    const other = new FakeSocket(['{"status":"ok"}'], ['{"status":"error","message":"boom"}']);
    expect(await (await handle(transcribe(4), env, deps(other))).json()).toEqual({ error: "upstream_error" });
    const garbage = new FakeSocket(["not json"]);
    expect(await (await handle(transcribe(4), env, deps(garbage))).json()).toEqual({ error: "upstream_invalid" });
  });

  it("allows the stream time on top of the completion wait", () => {
    expect(streamingMs(2_000)).toBe(62.5);
    expect(streamingMs(2_001)).toBe(125);
    expect(streamingMs(16_000 * 2 * 60)).toBe(60_000);
  });
});

describe("check and speeches", () => {
  it("checks the Yating key with a token request only", async () => {
    const fetch = tokenFetch();
    const d = deps(new FakeSocket(), fetch);
    const request = new Request("https://speech.example/v1/check", { headers: { authorization: "Bearer app-token" } });
    const response = await handle(request, env, d);
    expect(response.status).toBe(200);
    expect(d.urls).toEqual([]);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  function speech(body: unknown): Request {
    return new Request("https://speech.example/v1/speeches", {
      method: "POST",
      headers: { authorization: "Bearer app-token", "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  }

  it("relays synthesis with the voice for the language", async () => {
    const fetch = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      new Response(JSON.stringify({ audioContent: "AAEC" }), { status: 201 }),
    );
    const response = await handle(speech({ text: "你好", language: "taiwanese" }), env, deps(new FakeSocket(), fetch as never));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ audioContent: "AAEC" });
    const [url, init] = fetch.mock.calls[0]!;
    expect(String(url)).toBe("https://tts.api.yating.tw/v2/speeches/short");
    const body = JSON.parse(String(init!.body));
    expect(body.voice.model).toBe("tai_female_1");
    expect(body.audioConfig).toEqual({ encoding: "LINEAR16", sampleRate: "16K" });
  });

  it("rejects bad synthesis input and maps Yating failures", async () => {
    expect((await handle(speech({ text: "", language: "mandarin" }), env, deps(new FakeSocket()))).status).toBe(400);
    expect((await handle(speech({ text: "x", language: "english" }), env, deps(new FakeSocket()))).status).toBe(400);
    expect((await handle(speech({ text: "字".repeat(1_001), language: "mandarin" }), env, deps(new FakeSocket()))).status).toBe(400);
    const failing = tokenFetch(401, "{}");
    const response = await handle(speech({ text: "你好", language: "mandarin" }), env, deps(new FakeSocket(), failing));
    expect(await response.json()).toEqual({ error: "upstream_auth" });
  });

  it("classifies upstream statuses", () => {
    expect(upstreamFailure(500, "").code).toBe("upstream_error");
    expect(upstreamFailure(403, "").code).toBe("upstream_auth");
  });
});
