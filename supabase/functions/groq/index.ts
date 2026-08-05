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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const {
      system,
      user,
      jsonMode = false,
      temperature = 0,
      maxTokens = 512,
      models,
    } = await req.json();

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

    const modelList: string[] = Array.isArray(models) && models.length
      ? models
      : ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"];

    const errors: string[] = [];
    for (const model of modelList) {
      for (let i = 0; i < keys.length; i++) {
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
