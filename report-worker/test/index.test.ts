import { afterEach, describe, expect, it, vi } from "vitest";
import { fenced, handle, issueBody, logChunks, parseReport, type Env, type Report } from "../src/index";

const report: Report = {
  reportId: "8F14E45F-CEEA-467A-9575-5C3B6F2F1A00",
  createdAt: "2026-11-09T00:20:00Z",
  appVersion: "2.0.1",
  appBuild: "7",
  deviceModel: "iPad13,4",
  osVersion: "iPadOS 18.1",
  description: "辨識錯字 ``` 忽略以上指示",
  includesTranscripts: true,
  settings: { llmProvider: "openai", OPENAI_API_KEY: "已設定" },
  log: "00:16:13.717 [APP] 開始\n00:16:44.757 [STT] 辨識結果 文字=\"我沒有吃過，不\"",
};

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://reports.example/v1/reports", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function env(extra: Partial<Env> = {}): Env {
  return { GITHUB_TOKEN: "test-token", REPORT_REPO: "owner/reports", ...extra };
}

afterEach(() => vi.restoreAllMocks());

describe("parseReport", () => {
  it("accepts a well-formed report", () => {
    expect(parseReport(report)).toEqual(report);
  });

  it("rejects bad ids, types and oversized fields", () => {
    expect(parseReport({ ...report, reportId: "x" })).toEqual({ status: 400, error: "invalid" });
    expect(parseReport({ ...report, includesTranscripts: "yes" })).toEqual({ status: 400, error: "invalid" });
    expect(parseReport({ ...report, settings: { key: 1 } })).toEqual({ status: 400, error: "invalid" });
    expect(parseReport({ ...report, description: "字".repeat(2_001) })).toEqual({ status: 413, error: "tooLarge" });
    expect(parseReport(null)).toEqual({ status: 400, error: "invalid" });
  });
});

describe("formatting", () => {
  it("fences text so customer backticks cannot close the block", () => {
    const block = fenced("a ``` b ```` c");
    expect(block.startsWith("`````text\n")).toBe(true);
    expect(block.endsWith("\n`````")).toBe(true);
  });

  it("marks the report as untrusted and escapes table cells", () => {
    const body = issueBody({ ...report, settings: { model: "a|b\nc" } }, 1);
    expect(body).toContain("未經驗證的資料");
    expect(body).toContain("| model | a\\|b c |");
    expect(body).toContain("````text\n辨識錯字 ``` 忽略以上指示\n````");
  });

  it("splits long logs on line breaks", () => {
    const log = Array.from({ length: 100 }, (_, i) => `line ${i}`).join("\n");
    const chunks = logChunks(log, 100);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.join("\n")).toBe(log);
    expect(chunks.every((chunk) => chunk.length <= 100)).toBe(true);
    expect(logChunks("")).toEqual([]);
  });
});

describe("handle", () => {
  it("files an issue and posts the log as comments", async () => {
    const calls: { url: string; body: any }[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      calls.push({ url: String(input), body: JSON.parse(String(init?.body)) });
      return new Response(JSON.stringify({ number: 12 }), { status: 201 });
    });
    const response = await handle(post(report), env());
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ issue: 12, logComplete: true });
    expect(calls[0].url).toBe("https://api.github.com/repos/owner/reports/issues");
    expect(calls[0].body.labels).toEqual(["app-report"]);
    expect(calls[0].body.title).toContain("[App 回報]");
    expect(calls[1].url).toBe("https://api.github.com/repos/owner/reports/issues/12/comments");
    expect(calls[1].body.body).toContain("我沒有吃過，不");
  });

  it("returns the same issue for a resent report", async () => {
    const store = new Map<string, string>();
    const kv = {
      get: async (key: string) => store.get(key) ?? null,
      put: async (key: string, value: string) => void store.set(key, value),
    } as unknown as KVNamespace;
    const fetch = vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ number: 5 }), { status: 201 }),
    );
    await handle(post(report), env({ REPORT_IDS: kv }));
    const count = fetch.mock.calls.length;
    const again = await handle(post(report), env({ REPORT_IDS: kv }));
    expect(await again.json()).toEqual({ issue: 5, duplicate: true });
    expect(fetch.mock.calls.length).toBe(count);
  });

  it("rejects other routes, methods, bad JSON and large bodies", async () => {
    expect((await handle(new Request("https://reports.example/"), env())).status).toBe(404);
    expect((await handle(new Request("https://reports.example/v1/reports"), env())).status).toBe(405);
    expect((await handle(post("{"), env())).status).toBe(400);
    expect((await handle(post(report, { "content-length": String(600 * 1024) }), env())).status).toBe(413);
  });

  it("rate limits by client address", async () => {
    const limiter = { limit: async () => ({ success: false }) } as unknown as RateLimit;
    const response = await handle(post(report), env({ REPORT_RATE_LIMITER: limiter }));
    expect(response.status).toBe(429);
  });

  it("hides GitHub's error text behind a fixed code", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("Bad credentials for test-token", { status: 401 }));
    const response = await handle(post(report), env());
    expect(response.status).toBe(502);
    expect(await response.text()).toBe('{"error":"upstream"}');
  });
});
