// Supabase Edge Function: groq
// ---------------------------------------------------------------------------
// LLM proxy so the app carries NO Groq keys. Keys live in the `app_keys` table
// (managed from the admin dashboard) and are used here, server-side. The app
// calls this function with the public anon key; this function rotates the real
// Groq keys, logs usage, and returns only the completion text.
//
// Deploy:
//   supabase functions deploy groq --project-ref ojorpmtptryldizogtkz
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
// ---------------------------------------------------------------------------
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * The only models this proxy will ever call, cheapest-capable first.
 *
 * `models` arrives in the request body, so without this an anon-key holder
 * could name any model Groq offers — including one that costs many times what
 * the app actually needs — and bill it to these keys. The client may still
 * express a PREFERENCE (it orders them by task), but only from this set;
 * anything else is dropped rather than rejected, so an app build that learns a
 * new model id degrades to the default instead of breaking.
 */
const FALLBACK_MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];

/**
 * The allow-list is DATA, read from `app_config.groq_models` and managed on the
 * dashboard's API Keys page. Hardcoding it here is what turned Groq's retirement
 * of llama-3.3-70b-versatile into an outage: the id 404'd and could only be
 * changed by redeploying this function and shipping an app update.
 *
 * Cached in module scope, which on Deno Deploy means per warm instance — a
 * change is picked up within a minute or so without a deploy. FALLBACK_MODELS
 * covers a cold start racing the config read, or the key being absent.
 */
let modelCache: { at: number; models: string[] } | null = null;

/** Round-robin start, seeded per instance so cold starts don't all pick key 0. */
let keyCursor = Math.floor(Math.random() * 1000);

async function loadModels(
  sb: ReturnType<typeof createClient>,
): Promise<string[]> {
  if (modelCache && Date.now() - modelCache.at < 60_000) return modelCache.models;
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "groq_models").maybeSingle();
    const v = (data as { value?: unknown } | null)?.value;
    const list = Array.isArray(v)
      ? v
      : Array.isArray((v as { models?: unknown[] } | null)?.models)
      ? (v as { models: unknown[] }).models
      : null;
    const clean = (list || []).map((m) => String(m).trim()).filter(Boolean);
    const models = clean.length ? clean : FALLBACK_MODELS;
    modelCache = { at: Date.now(), models };
    return models;
  } catch {
    return FALLBACK_MODELS;
  }
}

/** Ceilings on one call, so a single request can't be made arbitrarily costly. */
const MAX_OUTPUT_TOKENS = 1024; // the app's largest real ask is 700
const MAX_SYSTEM_CHARS = 12000; // the schema prompt is the biggest, ~4k
const MAX_USER_CHARS = 4000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const body = await req.json();
    const {
      jsonMode = false,
      temperature = 0,
      models,
      token,
    } = body;

    // Clamp the cost levers. Every one of these is client-supplied, and each is
    // a way to turn one request into a large bill.
    const system = String(body.system ?? "").slice(0, MAX_SYSTEM_CHARS);
    const user = String(body.user ?? "").slice(0, MAX_USER_CHARS);
    const maxTokens = Math.min(
      MAX_OUTPUT_TOKENS,
      // Floor of 256: gpt-oss are reasoning models and spend part of the
      // budget thinking, so a tiny ceiling returns empty content, not an error.
      Math.max(256, Number(body.maxTokens) || 512),
    );
    if (!system || !user) return json({ error: "empty prompt" }, 400);

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // --- Play Integrity gate (dormant until the flag is on) ----------------
    // When app_config.require_integrity = true, calls must carry a genuine-app
    // token (wired with the Play Store release). Fail closed while enabled.
    const { data: intCfg } = await sb
      .from("app_config").select("value").eq("key", "require_integrity").maybeSingle();
    if (intCfg?.value === true && !req.headers.get("x-integrity-token"))
      return json({ error: "integrity_required" }, 403);

    // --- Who is calling? ----------------------------------------------------
    // Resolved once and reused by both gates below.
    const session = token
      ? (await sb.from("device_sessions").select("account_id, revoked_at")
          .eq("token_hash", await sha256(String(token))).maybeSingle()).data
      : null;
    const liveSession = session && !session.revoked_at ? session : null;

    // --- Genuine-caller gate -------------------------------------------------
    // This is the expensive endpoint: the anon key ships inside the APK, so
    // anyone who pulls it out gets an LLM relay billed to these keys, and the
    // per-device caps don't bind because `x-device-id` is whatever the caller
    // says it is. The only thing here that can't be minted for free is a device
    // session — it costs a real WhatsApp OTP on a real number to obtain, is
    // rate-limited, and is revocable.
    //
    // Tied to `otp_required` rather than switched on unconditionally: when that
    // flag is on, every legitimate install already holds a session, so demanding
    // one costs real users nothing. If OTP is ever turned off, nobody has one
    // and this correctly falls back to the rate limits alone rather than taking
    // the assistant down with it.
    const { data: otpCfg } = await sb
      .from("app_config").select("value").eq("key", "otp_required").maybeSingle();
    if (otpCfg?.value === true && !liveSession)
      return json({ error: "verification_required" }, 401);

    // --- Entitlement (dormant until app_config.payments_enabled is on) ------
    // The app's paywall is a CLIENT gate. It fails open on purpose — locking a
    // paying agent out mid-collection-round because the data dropped is a worse
    // failure than a few free calls — and its cached status sits in
    // SharedPreferences, so clearing app data or simply staying offline hands
    // the UI back. This function is the paid capability that actually costs
    // money to serve, so it checks entitlement HERE, where none of that reaches.
    //
    // Deliberately narrow: it refuses only an agent we can POSITIVELY identify
    // as expired. Identity comes from the device session token, exactly as in
    // `pay` — no token, an unknown or revoked one, or no subscription row at all
    // all mean "we don't know who this is", and we allow. That is the same
    // ordering constraint `pay` documents: otp_required must be ON before
    // payments_enabled, or no device has a session for any of this to read.
    const { data: payCfg } = await sb
      .from("app_config").select("value").eq("key", "payments_enabled").maybeSingle();
    if (payCfg?.value === true && liveSession) {
      {
        const { data: acct } = await sb
          .from("accounts").select("agent_id, disabled").eq("id", liveSession.account_id)
          .maybeSingle();
        const agentId = acct?.disabled ? "" : String(acct?.agent_id ?? "").trim();
        if (agentId) {
          const { data: sub } = await sb
            .from("subscriptions").select("current_period_end").eq("agent_id", agentId)
            .maybeSingle();
          if (sub && new Date(sub.current_period_end).getTime() <= Date.now())
            return json({ error: "subscription_expired" }, 402);
        }
      }
    }

    // --- Rate limiting (abuse guard) ---------------------------------------
    // The app authenticates with the public anon key, so anyone who extracts it
    // could otherwise drain the Groq quota. Cap per device (per-minute + daily)
    // and per IP (hourly backstop, in case device ids are spoofed/rotated).
    // Limits are read from app_config.groq_limits so they're tunable from the
    // dashboard without redeploying.
    const device = (req.headers.get("x-device-id") || "anon").slice(0, 64);
    const ip =
      (req.headers.get("x-forwarded-for") || "noip").split(",")[0].trim();

    const { data: cfg } = await sb
      .from("app_config")
      .select("value")
      .eq("key", "groq_limits")
      .maybeSingle();
    const L = (cfg?.value as Record<string, number>) || {};
    const perMin = L.perMin ?? 20;
    const perDay = L.perDay ?? 600;
    const perIpHour = L.perIpHour ?? 400;

    const bump = async (key: string, secs: number) => {
      const { data } = await sb.rpc("bump_rate", {
        p_device: key,
        p_window_secs: secs,
      });
      return (data as number) ?? 0;
    };
    if ((await bump(device, 60)) > perMin)
      return json({ error: "rate_limited", scope: "minute" }, 429);
    if ((await bump(`${device}:d`, 86400)) > perDay)
      return json({ error: "rate_limited", scope: "day" }, 429);
    if ((await bump(`ip:${ip}`, 3600)) > perIpHour)
      return json({ error: "rate_limited", scope: "ip" }, 429);

    const { data: rows } = await sb
      .from("app_keys")
      .select("key")
      .eq("provider", "groq")
      .eq("enabled", true)
      .order("id");
    const keys: string[] = (rows || []).map((r: { key: string }) => r.key);
    if (!keys.length) return json({ error: "no active keys" }, 503);

    // Honour the client's ordering, but only across models we allow. The
    // allow-list comes from app_config, so an app build that still names a
    // retired id degrades to the configured default instead of 404-ing.
    const allowed = await loadModels(sb);
    const asked: string[] = Array.isArray(models) ? models.map(String) : [];
    const permitted = asked.filter((m) => allowed.includes(m));
    const modelList: string[] = permitted.length ? permitted : allowed;

    const errors: string[] = [];
    for (const model of modelList) {
      // Spread the load. Starting at 0 every time meant key #0 absorbed every
      // request and the other three sat idle — and Groq's free-tier limit is per
      // key, so that rate-limited four times sooner than necessary.
      const start = keyCursor++ % keys.length;
      for (let n = 0; n < keys.length; n++) {
        const i = (start + n) % keys.length;
        let resp: Response;
        try {
          resp = await fetch(
            "https://api.groq.com/openai/v1/chat/completions",
            {
              method: "POST",
              headers: {
                Authorization: `Bearer ${keys[i]}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                model,
                temperature,
                max_tokens: maxTokens,
                ...(jsonMode ? { response_format: { type: "json_object" } } : {}),
                messages: [
                  { role: "system", content: system },
                  { role: "user", content: user },
                ],
              }),
            }
          );
        } catch (e) {
          errors.push(`key#${i} network: ${e}`);
          continue;
        }

        // Fire-and-forget usage log (key rotation dashboard).
        sb.from("key_usage")
          .insert({ key_index: i, model, ok: resp.ok })
          .then(() => {});

        if (resp.ok) {
          const body = await resp.json();
          const content = body?.choices?.[0]?.message?.content ?? "";
          return json({ content });
        }
        if (
          resp.status === 429 ||
          resp.status === 401 ||
          resp.status === 403 ||
          resp.status >= 500
        ) {
          errors.push(`key#${i}/${model} -> ${resp.status}`);
          continue; // rotate to next key
        }
        errors.push(`key#${i}/${model} -> ${resp.status}`);
        break; // request problem -> next model
      }
    }
    return json({ error: "all keys/models failed", detail: errors }, 502);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
