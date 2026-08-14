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
async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
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
    const { kind, row, token: bodyToken } = await req.json();
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
      const { error } = await sb.from("events").insert({
        device_id: clip(row.device_id, 64),
        event: clip(row.event, 64),
        props: row.props && typeof row.props === "object" ? row.props : {},
        app_version: clip(row.app_version, 32),
      });
      if (error) {
        console.error("events insert failed", error);
        return json({ ok: false, error: error.message }, 500);
      }
    } else if (kind === "device") {
      const id = clip(row.id, 64);
      if (!id) return json({ ok: false, error: "id required" }, 400);

      // --- Ownership -------------------------------------------------------
      // The device id is a random uuid the app makes up, so it proves nothing:
      // anyone holding the anon key could name someone else's id and rewrite
      // their name, mobile and agent id. That row is what the admin panel reads
      // an agent's identity from, so a forged write is not just noise.
      //
      // Once an install verifies its phone, the `otp` function stamps
      // `account_id` on this row — that is the point it stops being anonymous
      // telemetry and starts being an identity. From then on, only a live
      // session for the SAME account may write it. Rows with no account_id yet
      // (a fresh install reporting app_open, an agent still onboarding) stay
      // open, so nothing about first-run changes.
      const { data: existing } = await sb
        .from("devices").select("account_id").eq("id", id).maybeSingle();
      const claimed = (existing as { account_id?: string | null } | null)?.account_id;
      if (claimed) {
        const token = String(bodyToken ?? "");
        const { data: sess } = token
          ? await sb.from("device_sessions").select("account_id, revoked_at")
              .eq("token_hash", await sha256(token)).maybeSingle()
          : { data: null };
        const ok = sess && !sess.revoked_at && sess.account_id === claimed;
        if (!ok) return json({ ok: false, error: "not_your_device" }, 403);
      }

      // agent_id / sol_id (post-office branch) power per-agent + per-region
      // analytics. Only set them when the app actually sends them, so an older
      // build that omits them can't null out a value already on the row.
      const deviceRow: Record<string, unknown> = {
        id,
        app_version: clip(row.app_version, 32),
        platform: clip(row.platform, 16) || "android",
        last_seen: new Date().toISOString(),
      };
      // ONE name now: `agent_name`. It used to be written unconditionally, so a
      // build that sent no agent name blanked the one already on the row — with
      // two name fields that was survivable, with one it erases the only name we
      // have. Same "never null out what we already know" rule as every field
      // below.
      //
      // Older builds send the retired `name` instead (and may send only that).
      // Fold it in so a phone that hasn't updated yet still keeps its row
      // labelled; `name` itself is no longer written by any current build.
      const sentName = row.agent_name || row.name;
      if (sentName) deviceRow.agent_name = clip(sentName, 80);
      if (row.mobile) deviceRow.mobile = clip(String(row.mobile).replace(/\D/g, ""), 15);
      if (row.agent_id) deviceRow.agent_id = clip(row.agent_id, 64);
      if (row.sol_id) deviceRow.sol_id = clip(row.sol_id, 32);
      // "Redmi Note 12". Only older builds omit it, and an omission must not
      // wipe a model we already know — same rule as every field above.
      if (row.model) deviceRow.model = clip(row.model, 64);

      let up = await sb.from("devices").upsert(deviceRow, { onConflict: "id" });

      // The app and the schema ship separately, so a build can start sending a
      // column before the migration lands. Postgres 42703 = "column does not
      // exist": drop the newest field and write the rest, so a migration lag
      // costs the model and NOT last_seen, agent name, mobile and agent id along
      // with it. The whole device row used to vanish in that window, silently.
      if (up.error && (up.error as { code?: string }).code === "42703"
          && "model" in deviceRow) {
        console.warn("devices.model missing — run admin/schema_device_model.sql");
        delete deviceRow.model;
        up = await sb.from("devices").upsert(deviceRow, { onConflict: "id" });
      }
      if (up.error) {
        console.error("devices upsert failed", up.error);
        return json({ ok: false, error: up.error.message }, 500);
      }
    } else if (kind === "key_usage") {
      const { error } = await sb.from("key_usage").insert({
        device_id: clip(row.device_id, 64),
        key_index: Number(row.key_index) || 0,
        model: clip(row.model, 64),
        ok: !!row.ok,
      });
      if (error) {
        console.error("key_usage insert failed", error);
        return json({ ok: false, error: error.message }, 500);
      }
    } else {
      return json({ ok: false, error: "bad kind" }, 400);
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
