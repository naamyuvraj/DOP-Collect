// Supabase Edge Function: ingest
// ---------------------------------------------------------------------------
// The ONLY writer for telemetry. The app used to INSERT straight into
// events/devices/key_usage with the public anon key — anyone who extracts that
// key from the APK could spam or forge rows. Now the app posts here, this
// function rate-limits (per device + per IP) and writes with the service role,
// and the anon INSERT policies are dropped (see admin/schema_harden.sql). Net:
// the anon key can no longer write anything directly.
//
// Optional Play Integrity gate: when app_config.require_integrity = true, calls
// must carry a valid x-integrity-token (enabled with the Play Store release).
//
// Deploy:
//   supabase functions deploy ingest --project-ref ojorpmtptryldizogtkz
// ---------------------------------------------------------------------------
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-device-id, x-integrity-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
const clip = (v: unknown, n: number) =>
  typeof v === "string" ? v.slice(0, n) : v;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  try {
    const { kind, row } = await req.json();
    if (!row || typeof row !== "object") return json({ ok: false }, 400);

    const device =
      (req.headers.get("x-device-id") || row.device_id || row.id || "anon")
        .toString()
        .slice(0, 64);
    const ip =
      (req.headers.get("x-forwarded-for") || "noip").split(",")[0].trim();

    // Optional Play Integrity enforcement (dormant until the flag is on).
    const { data: intCfg } = await sb
      .from("app_config").select("value").eq("key", "require_integrity").maybeSingle();
    if (intCfg?.value === true) {
      // Verification lands with the Play Store release (needs a linked GCP
      // service account). Until then, if the flag is on we fail closed.
      const token = req.headers.get("x-integrity-token");
      if (!token) return json({ ok: false, error: "integrity_required" }, 403);
    }

    // Generous rate limits: never drops a real agent, blocks floods.
    const bump = async (k: string, s: number): Promise<number> =>
      ((await sb.rpc("bump_rate", { p_device: k, p_window_secs: s })).data as number) ?? 0;
    if ((await bump(device, 60)) > 300) return json({ ok: false, error: "rate" }, 429);
    if ((await bump(`${device}:d`, 86400)) > 5000) return json({ ok: false, error: "rate" }, 429);
    if ((await bump(`ip:${ip}`, 3600)) > 3000) return json({ ok: false, error: "rate" }, 429);

    if (kind === "event") {
      await sb.from("events").insert({
        device_id: clip(row.device_id, 64),
        event: clip(row.event, 64),
        props: row.props && typeof row.props === "object" ? row.props : {},
        app_version: clip(row.app_version, 32),
      });
    } else if (kind === "device") {
      // agent_id / sol_id (post-office branch) power per-agent + per-region
      // analytics. Only set them when the app actually sends them, so an older
      // build that omits them can't null out a value already on the row.
      const deviceRow: Record<string, unknown> = {
        id: clip(row.id, 64),
        agent_name: clip(row.agent_name, 80),
        app_version: clip(row.app_version, 32),
        platform: clip(row.platform, 16) || "android",
        last_seen: new Date().toISOString(),
      };
      if (row.name) deviceRow.name = clip(row.name, 80);
      if (row.mobile) deviceRow.mobile = clip(String(row.mobile).replace(/\D/g, ""), 15);
      if (row.agent_id) deviceRow.agent_id = clip(row.agent_id, 64);
      if (row.sol_id) deviceRow.sol_id = clip(row.sol_id, 32);
      await sb.from("devices").upsert(deviceRow, { onConflict: "id" });
    } else if (kind === "key_usage") {
      await sb.from("key_usage").insert({
        device_id: clip(row.device_id, 64),
        key_index: Number(row.key_index) || 0,
        model: clip(row.model, 64),
        ok: !!row.ok,
      });
    } else {
      return json({ ok: false, error: "bad kind" }, 400);
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
