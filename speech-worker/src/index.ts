// Relays Yating speech recognition and synthesis for the ReminiCare iPad app.
//
// The app sends plain HTTPS requests here; this Worker holds the Yating key and
// opens the Yating ASR WebSocket itself. Networks that block WebSockets (often
// school or company Wi-Fi) therefore no longer break recognition, and the key
// no longer lives on the iPad.
//
// Audio and text are never logged: console lines carry only codes, sizes and
// durations.

export interface Env {
  YATING_API_KEY: string;
  /** Shared secret the app sends as `Authorization: Bearer …`. */
  APP_TOKEN: string;
  SPEECH_RATE_LIMITER?: RateLimit;
}

/** A Yating ASR WebSocket, reduced to what the relay needs. */
export interface Socket {
  send(data: ArrayBuffer | string): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  addEventListener(type: "close" | "error", listener: () => void): void;
}

export interface Deps {
  fetch: typeof fetch;
  connect: (url: string) => Promise<Socket>;
  /** Pause between audio chunks (real time for 16 kHz audio). */
  pace: () => Promise<void>;
  readyMs: number;
  /** Wait for the final result after the audio has been streamed. */
  completionMs: number;
  tokenMs: number;
}

export const CHUNK_BYTES = 2_000;
export const CHUNK_MS = 62.5;
/** 16 kHz mono 16-bit PCM, up to 10 minutes (the app's longest recording). */
export const MAX_AUDIO_BYTES = 16_000 * 2 * 600;
export const MAX_TTS_TEXT = 1_000;
const TOKEN_URL = "https://asr.api.yating.tw/v1/token";
const ASR_URL = "https://asr.api.yating.tw/ws/v1/";
const TTS_URL = "https://tts.api.yating.tw/v2/speeches/short";

export const defaultDeps: Deps = {
  fetch: (input, init) => fetch(input, init),
  connect: async (url) => {
    const response = await fetch(url, { headers: { Upgrade: "websocket" } });
    const socket = response.webSocket;
    if (!socket) throw new Relay(502, "upstream_unreachable", `socket upgrade ${response.status}`);
    socket.accept();
    return socket as unknown as Socket;
  },
  pace: () => new Promise((resolve) => setTimeout(resolve, CHUNK_MS)),
  readyMs: 5_000,
  completionMs: 30_000,
  tokenMs: 10_000,
};

/** A failure answered with a fixed code; `log` is for the console only. */
class Relay extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly log: string,
    readonly partial?: string,
  ) {
    super(code);
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

const failure = (error: Relay) =>
  json(error.status, error.partial ? { error: error.code, partial: error.partial } : { error: error.code });

/** Constant-time comparison so the token cannot be guessed byte by byte. */
export function sameToken(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0 && expected.length > 0;
}

const billingPattern = /quota|balance|expire|insufficient|credit|payment/i;

/** Maps a failed Yating HTTP response to a fixed code (never forwards its body). */
export function upstreamFailure(status: number, body: string): Relay {
  if (status === 402 || billingPattern.test(body)) return new Relay(402, "quota", `yating ${status} billing`);
  if (status === 401 || status === 403) return new Relay(502, "upstream_auth", `yating ${status}`);
  if (status === 429) return new Relay(429, "upstream_rate_limit", "yating 429");
  if (status >= 500) return new Relay(502, "upstream_error", `yating ${status}`);
  return new Relay(502, "upstream_invalid", `yating ${status}`);
}

function timeout<T>(promise: Promise<T>, ms: number, error: () => Relay): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const expired = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(error()), ms);
  });
  return Promise.race([promise, expired]).finally(() => {
    if (timer !== null) clearTimeout(timer);
  });
}

async function yatingToken(env: Env, deps: Deps): Promise<string> {
  let response: Response;
  try {
    response = await timeout(
      deps.fetch(TOKEN_URL, {
        method: "POST",
        headers: { key: env.YATING_API_KEY, "content-type": "application/json" },
        body: JSON.stringify({ pipeline: "asr-zh-tw-std" }),
      }),
      deps.tokenMs,
      () => new Relay(504, "upstream_timeout", "token timeout"),
    );
  } catch (error) {
    if (error instanceof Relay) throw error;
    throw new Relay(502, "upstream_unreachable", "token fetch failed");
  }
  const text = await response.text();
  if (response.status !== 201) throw upstreamFailure(response.status, text);
  try {
    const body = JSON.parse(text) as { success?: boolean; auth_token?: string };
    if (body.success === true && typeof body.auth_token === "string") return body.auth_token;
  } catch {
    // fall through
  }
  throw new Relay(502, "upstream_invalid", "token body");
}

/** Messages from the socket, in order; null once it closed. */
function inbox(socket: Socket): () => Promise<string | null> {
  const queue: (string | null)[] = [];
  let waiting: ((value: string | null) => void) | undefined;
  const push = (value: string | null) => {
    if (waiting) {
      const resolve = waiting;
      waiting = undefined;
      resolve(value);
    } else {
      queue.push(value);
    }
  };
  socket.addEventListener("message", (event) => {
    const data = event.data;
    push(typeof data === "string" ? data : new TextDecoder().decode(data as ArrayBuffer));
  });
  socket.addEventListener("close", () => push(null));
  socket.addEventListener("error", () => push(null));
  return () => {
    if (queue.length > 0) return Promise.resolve(queue.shift()!);
    return new Promise((resolve) => (waiting = resolve));
  };
}

interface Transcript {
  full: string;
  current: string;
  sentences: number;
}

const partialOf = (t: Transcript) => (t.full + t.current).trim();
const tidy = (text: string) => text.replace(/^[，\s]+|[，\s]+$/g, "");

export function streamingMs(bytes: number): number {
  return Math.ceil(bytes / CHUNK_BYTES) * CHUNK_MS;
}

/** Streams `pcm` through Yating ASR and returns the recognized text. */
export async function recognize(pcm: Uint8Array, env: Env, deps: Deps): Promise<{ text: string; sentences: number }> {
  const token = await yatingToken(env, deps);
  let socket: Socket;
  try {
    socket = await deps.connect(`${ASR_URL}?token=${encodeURIComponent(token)}`);
  } catch (error) {
    if (error instanceof Relay) throw error;
    throw new Relay(502, "upstream_unreachable", "socket connect failed");
  }
  const next = inbox(socket);
  const transcript: Transcript = { full: "", current: "", sentences: 0 };
  let stopped = false;

  /** "ready", "eof" or "none" for one message; throws on errors and early close. */
  const handle = (message: string | null): "ready" | "eof" | "none" => {
    if (message === null) throw new Relay(502, "upstream_closed", "socket closed early", partialOf(transcript));
    let object: { status?: string; pipe?: { asr_sentence?: string; asr_final?: boolean; asr_eof?: boolean } };
    try {
      object = JSON.parse(message);
    } catch {
      throw new Relay(502, "upstream_invalid", "socket message");
    }
    if (object.status === "error") {
      throw billingPattern.test(message)
        ? new Relay(402, "quota", "socket billing")
        : new Relay(502, "upstream_error", "socket error status");
    }
    let event: "ready" | "eof" | "none" = object.status === "ok" ? "ready" : "none";
    const pipe = object.pipe;
    if (pipe) {
      if (typeof pipe.asr_sentence === "string") transcript.current = pipe.asr_sentence;
      if (pipe.asr_final === true) {
        transcript.full += transcript.current + "，";
        transcript.current = "";
        transcript.sentences += 1;
      }
      if (pipe.asr_eof === true) event = "eof";
    }
    return event;
  };

  try {
    await timeout(
      (async () => {
        while (handle(await next()) !== "ready") {}
      })(),
      deps.readyMs,
      () => new Relay(504, "upstream_timeout", "ready timeout"),
    );

    const sender = (async () => {
      for (let offset = 0; offset < pcm.length && !stopped; offset += CHUNK_BYTES) {
        const chunk = pcm.slice(offset, offset + CHUNK_BYTES);
        socket.send(chunk.buffer);
        await deps.pace();
      }
      if (!stopped) socket.send(new ArrayBuffer(0));
    })();
    sender.catch(() => {});

    await timeout(
      (async () => {
        while (handle(await next()) !== "eof") {}
      })(),
      streamingMs(pcm.length) + deps.completionMs,
      () => new Relay(504, "timeout", "completion timeout", partialOf(transcript)),
    );
  } finally {
    stopped = true;
    try {
      socket.close(1000, "done");
    } catch {
      // already closed
    }
  }
  return { text: tidy(partialOf(transcript)), sentences: transcript.sentences };
}

async function synthesize(request: Request, env: Env, deps: Deps): Promise<Response> {
  let input: { text?: unknown; language?: unknown };
  try {
    input = await request.json();
  } catch {
    return json(400, { error: "invalid" });
  }
  const text = input.text;
  if (typeof text !== "string" || text.trim() === "" || text.length > MAX_TTS_TEXT) return json(400, { error: "invalid" });
  if (input.language !== "taiwanese" && input.language !== "mandarin") return json(400, { error: "invalid" });
  const body = {
    input: { text, type: "text" },
    voice: {
      model: input.language === "taiwanese" ? "tai_female_1" : "zh_en_female_1",
      speed: 1.0,
      pitch: 1.0,
      energy: 1.0,
    },
    audioConfig: { encoding: "LINEAR16", sampleRate: "16K" },
  };
  let response: Response;
  try {
    response = await timeout(
      deps.fetch(TTS_URL, {
        method: "POST",
        headers: { key: env.YATING_API_KEY, "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
      30_000,
      () => new Relay(504, "upstream_timeout", "tts timeout"),
    );
  } catch (error) {
    throw error instanceof Relay ? error : new Relay(502, "upstream_unreachable", "tts fetch failed");
  }
  const raw = await response.text();
  if (response.status !== 200 && response.status !== 201) throw upstreamFailure(response.status, raw);
  let audioContent: unknown;
  try {
    audioContent = (JSON.parse(raw) as { audioContent?: unknown }).audioContent;
  } catch {
    // fall through
  }
  if (typeof audioContent !== "string" || audioContent === "") throw new Relay(502, "upstream_invalid", "tts body");
  return json(200, { audioContent });
}

export async function handle(request: Request, env: Env, deps: Deps = defaultDeps): Promise<Response> {
  const url = new URL(request.url);
  const route = `${request.method} ${url.pathname}`;
  if (url.pathname === "/health") return json(200, { ok: true });
  if (!["/v1/check", "/v1/transcribe", "/v1/speeches"].includes(url.pathname)) return json(404, { error: "notFound" });
  if (route !== "GET /v1/check" && route !== "POST /v1/transcribe" && route !== "POST /v1/speeches") {
    return json(405, { error: "method" });
  }
  if (!env.APP_TOKEN || !env.YATING_API_KEY) return json(500, { error: "misconfigured" });
  const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1] ?? "";
  if (!sameToken(bearer, env.APP_TOKEN)) return json(401, { error: "unauthorized" });

  if (env.SPEECH_RATE_LIMITER) {
    const key = request.headers.get("cf-connecting-ip") ?? "unknown";
    const { success } = await env.SPEECH_RATE_LIMITER.limit({ key });
    if (!success) return json(429, { error: "rate_limited" });
  }

  const started = Date.now();
  try {
    if (route === "GET /v1/check") {
      await yatingToken(env, deps);
      console.log(`check ok ms=${Date.now() - started}`);
      return json(200, { ok: true });
    }
    if (route === "POST /v1/speeches") {
      const response = await synthesize(request, env, deps);
      console.log(`speech ${response.status} ms=${Date.now() - started}`);
      return response;
    }
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (declared > MAX_AUDIO_BYTES) return json(413, { error: "too_large" });
    const pcm = new Uint8Array(await request.arrayBuffer());
    if (pcm.length > MAX_AUDIO_BYTES) return json(413, { error: "too_large" });
    if (pcm.length === 0 || pcm.length % 2 !== 0) return json(400, { error: "invalid_audio" });
    const result = await recognize(pcm, env, deps);
    console.log(`transcribe ok ms=${Date.now() - started} bytes=${pcm.length} sentences=${result.sentences}`);
    return json(200, result);
  } catch (error) {
    if (error instanceof Relay) {
      console.log(`${route} failed ${error.code} (${error.log}) ms=${Date.now() - started}`);
      return failure(error);
    }
    console.log(`${route} failed unexpected ms=${Date.now() - started}`);
    return json(500, { error: "internal" });
  }
}

export default {
  fetch: (request: Request, env: Env) => handle(request, env),
} satisfies ExportedHandler<Env>;
