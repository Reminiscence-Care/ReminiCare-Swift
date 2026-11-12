// Hands the ReminiCare iPad app its service keys, so each iPad needs only this
// Worker's token instead of every key typed in by hand.
//
// The app still sends every service request itself; this Worker only answers
// "which keys should I use". Values are never logged.

/** Keys this Worker may hand out. The app accepts only these names too. */
export const DISTRIBUTED = [
  "NCKU_STT_TOKEN",
  "NCKU_TTS_TOKEN",
  "SPEECH_WORKER_TOKEN",
  "CLOUDFLARE_IMAGE_APP_TOKEN",
] as const;

export type Env = { APP_TOKEN: string; KEY_RATE_LIMITER?: RateLimit } & Partial<
  Record<(typeof DISTRIBUTED)[number], string>
>;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

/** Constant-time comparison, so response timing does not reveal the token. */
export function sameToken(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0 && expected.length > 0;
}

export async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/health") return json(200, { ok: true });
  if (url.pathname !== "/v1/keys") return json(404, { error: "notFound" });
  if (request.method !== "GET") return json(405, { error: "method" });
  if (!env.APP_TOKEN) return json(500, { error: "misconfigured" });
  const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1] ?? "";
  if (!sameToken(bearer, env.APP_TOKEN)) {
    console.log("keys unauthorized");
    return json(401, { error: "unauthorized" });
  }
  if (env.KEY_RATE_LIMITER) {
    const { success } = await env.KEY_RATE_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" });
    if (!success) return json(429, { error: "rate_limited" });
  }
  const keys: Record<string, string> = {};
  for (const name of DISTRIBUTED) {
    const value = env[name]?.trim();
    if (value) keys[name] = value;
  }
  console.log(`keys ok count=${Object.keys(keys).length}`);
  return json(200, { keys });
}

export default {
  fetch: (request: Request, env: Env) => handle(request, env),
} satisfies ExportedHandler<Env>;
