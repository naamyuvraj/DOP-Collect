// Loads an edge function's real index.ts and hands back its request handler.
//
// The functions call Deno.serve(handler) at module scope, so we stub Deno.serve
// to capture the handler instead of binding a port. Supabase's client is
// swapped for the in-memory double via the import map in deno.json. Everything
// between — routing, rate limits, auth checks, queries — is the shipped code.
//
// Each function creates its client INSIDE the handler, so one import is enough:
// tests swap the database with useDb() and the next request picks it up.

import { type Db, useDb } from "./mock_supabase.ts";

export type Handler = (req: Request) => Promise<Response>;

export interface FetchCall { url: string; body: unknown }

/** Outbound HTTP (MSG91 / Razorpay) from the request under test. */
export let fetchCalls: FetchCall[] = [];
let fetchReply: (url: string, body: unknown) => { status: number; json: unknown } =
  () => ({ status: 200, json: { type: "success", request_id: "req_test" } });

globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  let body: unknown = null;
  try { body = init?.body ? JSON.parse(String(init.body)) : null; } catch { /* not json */ }
  fetchCalls.push({ url, body });
  const r = fetchReply(url, body);
  return Promise.resolve(
    new Response(JSON.stringify(r.json), {
      status: r.status,
      headers: { "Content-Type": "application/json" },
    }),
  );
}) as typeof fetch;

const handlers = new Map<string, Handler>();

/** Import a function once and capture its handler. */
export async function load(fn: "otp" | "pay" | "ingest" | "groq"): Promise<Handler> {
  const cached = handlers.get(fn);
  if (cached) return cached;

  let captured: Handler | null = null;
  const realServe = Deno.serve;
  // deno-lint-ignore no-explicit-any
  (Deno as any).serve = (h: Handler) => {
    captured = h;
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  };
  try {
    await import(`../functions/${fn}/index.ts`);
  } finally {
    // deno-lint-ignore no-explicit-any
    (Deno as any).serve = realServe;
  }
  if (!captured) throw new Error(`${fn}: Deno.serve was never called`);
  handlers.set(fn, captured);
  return captured;
}

/** Point the function at `db` and reset the outbound-HTTP log for one test. */
export function begin(
  db: Db,
  opts: {
    env?: Record<string, string>;
    reply?: (url: string, body: unknown) => { status: number; json: unknown };
  } = {},
) {
  useDb(db);
  fetchCalls = [];
  fetchReply = opts.reply ??
    (() => ({ status: 200, json: { type: "success", request_id: "req_test" } }));
  for (const [k, v] of Object.entries(opts.env ?? {})) Deno.env.set(k, v);
}

/** POST a JSON body at a handler and read the JSON back. */
export async function post(
  handler: Handler,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<{ status: number; json: Record<string, unknown> }> {
  const res = await handler(
    new Request("https://fn.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
    }),
  );
  const text = await res.text();
  let json: Record<string, unknown> = {};
  try { json = JSON.parse(text); } catch { json = { _raw: text }; }
  return { status: res.status, json };
}

/**
 * The OTP the function just handed to MSG91 — this is the test's "WhatsApp
 * inbox". Read out of the real outbound payload, never out of the database, so
 * the code being verified is the code a user would actually receive.
 */
export function otpFromWhatsApp(): string {
  const call = fetchCalls.find((c) => c.url.includes("msg91"));
  if (!call) throw new Error("no WhatsApp send was attempted");
  // deno-lint-ignore no-explicit-any
  const p = call.body as any;
  const code = p?.payload?.template?.to_and_components?.[0]?.components?.body_1?.value;
  if (!code) throw new Error("no OTP in the WhatsApp payload");
  return String(code);
}

export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export const BASE_ENV = {
  SUPABASE_URL: "https://test.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-test",
};
