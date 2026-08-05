// Supabase Edge Function: otp
// ---------------------------------------------------------------------------
// MSG91 OTP proxy + identity/session authority. The app carries NO MSG91 auth
// key — it lives here as a secret. This function:
//   * send / resend / verify a phone OTP via MSG91 v5 (control.msg91.com)
//   * binds one phone <-> one DOP agent id (1:1)
//   * issues a device session token and enforces MAX 2 devices per account
//     (a 3rd verify kicks the oldest — "session out")
//   * session_check heartbeat + logout
//
// The app calls this with the public anon key; the raw phone only transits to
// MSG91, and only a SHA-256 hash is stored.
//
// Secrets (supabase secrets set ...):
//   MSG91_AUTHKEY, MSG91_TEMPLATE_ID, MSG91_SENDER (optional)
//   SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy:
//   supabase functions deploy otp --project-ref ojorpmtptryldizogtkz
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

const MSG91 = "https://control.msg91.com/api/v5/otp";

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randomToken(): string {
  const a = new Uint8Array(32);
  crypto.getRandomValues(a);
  return [...a].map((b) => b.toString(16).padStart(2, "0")).join("");
}
/** India: keep last 10 digits, prefix 91. */
function normPhone(raw: string): string {
  const ten = (raw || "").replace(/\D/g, "").slice(-10);
  return "91" + ten;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const authkey = Deno.env.get("MSG91_AUTHKEY") || "";
  const templateId = Deno.env.get("MSG91_TEMPLATE_ID") || "";
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Tunable limits from app_config.otp_limits (no redeploy to change).
  const { data: cfgRow } = await sb
    .from("app_config").select("value").eq("key", "otp_limits").maybeSingle();
  const L = (cfgRow?.value as Record<string, number>) || {};
  const cooldown = L.cooldown ?? 30;
  const maxSendPerHour = L.maxSendPerHour ?? 5;
  const { data: mdRow } = await sb
    .from("app_config").select("value").eq("key", "max_devices").maybeSingle();
  const maxDevices = Number(mdRow?.value ?? 2) || 2;

  const bump = async (key: string, secs: number): Promise<number> => {
    const { data } = await sb.rpc("bump_rate", { p_device: key, p_window_secs: secs });
    return (data as number) ?? 0;
  };
  const logReq = (deviceId: string, phoneHash: string, action: string, status: string, reqId?: string) =>
    sb.from("otp_requests")
      .insert({ device_id: deviceId, phone_hash: phoneHash, action, status, req_id: reqId ?? null })
      .then(() => {});

  try {
    const body = await req.json();
    const action = String(body.action || "");

    // ---- session_check (heartbeat) & logout: no phone needed ---------------
    if (action === "session_check" || action === "logout") {
      const tokenHash = await sha256(String(body.token || ""));
      const { data: s } = await sb
        .from("device_sessions")
        .select("id, revoked_at, revoked_reason")
        .eq("token_hash", tokenHash)
        .maybeSingle();
      if (action === "logout") {
        if (s) await sb.from("device_sessions")
          .update({ revoked_at: new Date().toISOString(), revoked_reason: "logout" })
          .eq("id", s.id);
        return json({ ok: true });
      }
      if (!s) return json({ ok: false, reason: "unknown" });
      if (s.revoked_at) return json({ ok: false, reason: s.revoked_reason || "revoked" });
      await sb.from("device_sessions")
        .update({ last_seen: new Date().toISOString() }).eq("id", s.id);
      return json({ ok: true });
    }

    // ---- send / resend / verify: need a phone -----------------------------
    const phone = normPhone(body.phone);
    if (phone.length !== 12) return json({ ok: false, code: "bad_phone" }, 400);
    const phoneHash = await sha256(phone);
    const deviceId = String(body.deviceId || "").slice(0, 64);

    if (action === "send" || action === "resend") {
      if (!authkey || !templateId)
        return json({ ok: false, code: "not_configured" }, 503);
      // Resend cooldown + hourly cap (abuse/cost guard).
      if ((await bump(`otpcd:${phoneHash}`, cooldown)) > 1)
        return json({ ok: false, code: "cooldown", cooldown }, 429);
      if ((await bump(`otp:${phoneHash}`, 3600)) > maxSendPerHour)
        return json({ ok: false, code: "rate_limited" }, 429);

      let url: string, resp: Response;
      if (action === "send") {
        url = `${MSG91}?template_id=${encodeURIComponent(templateId)}&mobile=${phone}&otp_length=6&otp_expiry=10`;
      } else {
        const via = body.via === "voice" ? "voice" : "text";
        url = `${MSG91}/retry?mobile=${phone}&retrytype=${via}`;
      }
      resp = await fetch(url, { method: "POST", headers: { authkey } });
      const data = await resp.json().catch(() => ({}));
      const ok = resp.ok && data?.type !== "error";
      logReq(deviceId, phoneHash, action, ok ? "ok" : "provider_error", data?.request_id);
      if (!ok)
        return json({ ok: false, code: "provider_down", message: data?.message ?? "" }, 502);
      return json({ ok: true, reqId: data?.request_id ?? null, cooldown });
    }

    if (action === "verify") {
      if (!authkey) return json({ ok: false, code: "not_configured" }, 503);
      const otp = String(body.otp || "").replace(/\D/g, "");
      const agentId = String(body.agentId || "").trim();

      const vResp = await fetch(`${MSG91}/verify?mobile=${phone}&otp=${otp}`, {
        method: "GET", headers: { authkey },
      });
      const vData = await vResp.json().catch(() => ({}));
      const verified = vResp.ok && vData?.type === "success";
      if (!verified) {
        const expired = String(vData?.message || "").toLowerCase().includes("expire");
        logReq(deviceId, phoneHash, "verify", expired ? "expired" : "invalid");
        return json({ ok: false, code: expired ? "expired" : "invalid_otp" }, 401);
      }

      // --- 1:1 bind phone <-> agent id -----------------------------------
      const { data: byPhone } = await sb
        .from("accounts").select("id, agent_id, disabled").eq("phone_hash", phoneHash).maybeSingle();
      if (byPhone?.disabled) return json({ ok: false, code: "account_disabled" }, 403);
      if (agentId) {
        const { data: byAgent } = await sb
          .from("accounts").select("id, phone_hash").eq("agent_id", agentId).maybeSingle();
        if (byAgent && byAgent.phone_hash !== phoneHash)
          return json({ ok: false, code: "already_linked", detail: "agent" }, 409);
        if (byPhone && byPhone.agent_id && byPhone.agent_id !== agentId)
          return json({ ok: false, code: "already_linked", detail: "phone" }, 409);
      }

      let accountId = byPhone?.id as string | undefined;
      if (!accountId) {
        const { data: ins } = await sb.from("accounts")
          .insert({ phone_hash: phoneHash, agent_id: agentId || null })
          .select("id").single();
        accountId = ins!.id;
      } else if (agentId && !byPhone!.agent_id) {
        await sb.from("accounts").update({ agent_id: agentId }).eq("id", accountId);
      }

      // --- device session + 2-device enforcement -------------------------
      const token = randomToken();
      const tokenHash = await sha256(token);
      await sb.from("device_sessions").upsert(
        {
          account_id: accountId, device_id: deviceId, token_hash: tokenHash,
          app_version: String(body.appVersion || ""),
          created_at: new Date().toISOString(), last_seen: new Date().toISOString(),
          revoked_at: null, revoked_reason: null,
        },
        { onConflict: "account_id,device_id" }
      );
      // Keep only the newest `maxDevices` live sessions; kick the oldest.
      const { data: live } = await sb.from("device_sessions")
        .select("id, created_at").eq("account_id", accountId).is("revoked_at", null)
        .order("created_at", { ascending: false });
      const excess = (live || []).slice(maxDevices);
      if (excess.length)
        await sb.from("device_sessions")
          .update({ revoked_at: new Date().toISOString(), revoked_reason: "device_limit" })
          .in("id", excess.map((r) => r.id));

      logReq(deviceId, phoneHash, "verify", "ok");
      return json({ ok: true, token, accountId });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
