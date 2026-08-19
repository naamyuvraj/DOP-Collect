// Supabase Edge Function: otp  (WhatsApp channel via MSG91)
// ---------------------------------------------------------------------------
// WhatsApp OTP proxy + identity/session authority. The app carries NO MSG91 auth
// key — it lives here as a secret. This function:
//   * send / resend a 4-digit OTP over WhatsApp (MSG91 template message)
//   * verify it (we generate + store + check the code — MSG91 only DELIVERS the
//     WhatsApp template; it does not verify WhatsApp OTPs, unlike SMS)
//   * binds one phone <-> one DOP agent id (1:1)
//   * issues a device session token and enforces MAX 2 devices per account
//     (a 3rd verify kicks the oldest — "session out")
//   * session_check heartbeat + logout
//   * bind_agent — fill in an agent id the "Log in" tab could not supply at
//     verify time (session token proves ownership; only ever fills a null)
//
// Only a SHA-256 hash of the phone AND of the code is ever stored; the raw phone
// only transits to MSG91 for delivery.
//
// Secrets (supabase secrets set ...):
//   MSG91_AUTHKEY                – MSG91 auth key
//   MSG91_WA_INTEGRATED_NUMBER   – your WhatsApp business number, digits only
//   MSG91_WA_TEMPLATE_NAME       – approved template name (body var = the OTP)
//   MSG91_WA_TEMPLATE_LANG       – template language code (e.g. en_US / en)
//   MSG91_WA_NAMESPACE           – (optional) template namespace, if your account uses one
//   MSG91_WA_HAS_BUTTON          – (optional) "true" if it's an auth template with a copy-code button
//   SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy:
//   supabase functions deploy otp --project-ref ojorpmtptryldizogtkz --use-api
// ---------------------------------------------------------------------------
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-integrity-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const WA_SEND =
  "https://api.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/";

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randomToken(bytes = 32): string {
  const a = new Uint8Array(bytes);
  crypto.getRandomValues(a);
  return [...a].map((b) => b.toString(16).padStart(2, "0")).join("");
}
/** Constant-time hex-string compare (don't leak the code hash via timing). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
/** Salted hash of a code so a leak of otp_codes can't be brute-forced offline. */
const codeHash = (salt: string, phone: string, otp: string) =>
  sha256(`${salt}:${phone}:${otp}`);

/**
 * How many digits an OTP has. FIXED, deliberately not read from app_config:
 * the app's verify screen sizes its input boxes with a matching constant and
 * auto-submits on the last digit, so raising this server-side alone would send
 * every user a code they physically could not finish typing — a config change
 * with no deploy and no way for the user to recover. Change it here and in
 * `OtpVerifyScreen.codeLength` together, then ship.
 */
const OTP_DIGITS = 4;
/** Cryptographically-random numeric OTP (rejection sampling => no modulo bias). */
function genOtp(len = 6): string {
  let out = "";
  const buf = new Uint8Array(1);
  while (out.length < len) {
    crypto.getRandomValues(buf);
    if (buf[0] < 250) out += (buf[0] % 10).toString(); // 250 = 25*10, unbiased
  }
  return out;
}
/** India: keep last 10 digits, prefix 91. */
function normPhone(raw: string): string {
  const ten = (raw || "").replace(/\D/g, "").slice(-10);
  return "91" + ten;
}

interface WaCfg {
  number: string;
  template: string;
  lang: string;
  namespace: string;
  hasButton: boolean;
}

/** Deliver the OTP as a WhatsApp template message (body variable = the code). */
async function sendWhatsApp(
  authkey: string, cfg: WaCfg, phone12: string, otp: string,
): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const components: Record<string, unknown> = {
    body_1: { type: "text", value: otp },
  };
  // Meta authentication templates carry the code in a copy-code button too.
  if (cfg.hasButton) {
    components.button_1 = { subtype: "url", type: "text", value: otp };
  }
  const payload = {
    integrated_number: cfg.number,
    content_type: "template",
    payload: {
      messaging_product: "whatsapp",
      type: "template",
      template: {
        name: cfg.template,
        language: { code: cfg.lang, policy: "deterministic" },
        ...(cfg.namespace ? { namespace: cfg.namespace } : {}),
        to_and_components: [{ to: [phone12], components }],
      },
    },
  };
  const resp = await fetch(WA_SEND, {
    method: "POST",
    headers: { "Content-Type": "application/json", authkey },
    body: JSON.stringify(payload),
  });
  const data = await resp.json().catch(() => ({}));
  // MSG91 WhatsApp bulk API signals failure a few different ways depending on
  // the error; treat only a clean 2xx with no error marker as success.
  const d = data as { type?: string; status?: string; hasError?: boolean };
  const looksError =
    d?.type === "error" || d?.status === "error" || d?.hasError === true;
  return { ok: resp.ok && !looksError, status: resp.status, data: data as Record<string, unknown> };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const authkey = Deno.env.get("MSG91_AUTHKEY") || "";
  const wa: WaCfg = {
    number: Deno.env.get("MSG91_WA_INTEGRATED_NUMBER") || "",
    template: Deno.env.get("MSG91_WA_TEMPLATE_NAME") || "",
    lang: Deno.env.get("MSG91_WA_TEMPLATE_LANG") || "en_US",
    namespace: Deno.env.get("MSG91_WA_NAMESPACE") || "",
    hasButton: (Deno.env.get("MSG91_WA_HAS_BUTTON") || "").toLowerCase() === "true",
  };
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Tunable limits from app_config.otp_limits (no redeploy to change).
  const { data: cfgRow } = await sb
    .from("app_config").select("value").eq("key", "otp_limits").maybeSingle();
  const L = (cfgRow?.value as Record<string, number>) || {};
  const cooldown = L.cooldown ?? 30;
  const maxSendPerHour = L.maxSendPerHour ?? 5;     // per PHONE / hour
  const maxIpPerHour = L.maxIpPerHour ?? 30;        // per IP / hour (all phones)
  const maxDevicePerHour = L.maxDevicePerHour ?? 10; // per DEVICE / hour
  const ttl = L.ttl ?? 600;                 // code lifetime, seconds
  const maxAttempts = L.maxAttempts ?? 5;   // wrong tries before burn
  const { data: mdRow } = await sb
    .from("app_config").select("value").eq("key", "max_devices").maybeSingle();
  // How many phones one account may be signed in on at once. The app reads the
  // same app_config key to word its copy, so this number and what the agent is
  // told stay in step — change it in one place and both move.
  const maxDevices = Number(mdRow?.value ?? 3) || 3;

  const bump = async (key: string, secs: number): Promise<number> => {
    const { data } = await sb.rpc("bump_rate", { p_device: key, p_window_secs: secs });
    return (data as number) ?? 0;
  };
  /**
   * True only when `token` is a LIVE device session belonging to `accountId`.
   *
   * This is what stands between "I control this new phone" and "I am the owner
   * of this account". Without it, `changePhone` accepted an agent id as proof
   * of identity — and agent ids are printed on receipts, so anyone could point
   * a stranger's account at their own number and lock the real agent out.
   */
  const sessionOwns = async (token: string, accountId: string): Promise<boolean> => {
    if (!token) return false;
    const { data } = await sb
      .from("device_sessions")
      .select("account_id, revoked_at")
      .eq("token_hash", await sha256(token))
      .maybeSingle();
    return !!data && !data.revoked_at && data.account_id === accountId;
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

    // ---- bind_agent: attach a DOP agent id to an already-verified account --
    //
    // The "Log in" tab verifies a phone BEFORE the DOP agent id has been typed
    // in (onboarding_login._login reads Credentials, which is empty on a fresh
    // phone, then collects the id afterwards via ensureDopLogin). So `verify`
    // took the `else if (!accountId)` branch and created an account keyed on the
    // phone alone, with agent_id null — and nothing ever filled it in.
    //
    // The consequences were not cosmetic. `accounts.agent_id` is what makes the
    // binding 1:1, so a null one means the `already_linked` check below can
    // never fire for that account, and the same agent id can be verified from
    // any number of different mobiles — each getting its own account and its own
    // full max_devices budget. The device limit stopped constraining the agent
    // at all.
    //
    // Proof of ownership is the session token, exactly as in `changePhone`: the
    // agent id is printed on receipts, so it is not a secret and cannot be the
    // thing that authorises the write.
    //
    // Deliberately NOT destructive. It only fills a null, and refuses when the
    // account already carries a different id or when another account already
    // owns this one. Repairing the accounts that are ALREADY split is a data
    // decision for a human, not something a background call should do.
    if (action === "bind_agent") {
      const agentId = String(body.agentId || "").trim().slice(0, 64);
      if (!agentId) return json({ ok: false, code: "bad_agent" }, 400);

      const { data: s } = await sb
        .from("device_sessions")
        .select("account_id, revoked_at")
        .eq("token_hash", await sha256(String(body.token || "")))
        .maybeSingle();
      if (!s || s.revoked_at || !s.account_id)
        return json({ ok: false, code: "no_session" }, 403);

      const { data: acct } = await sb
        .from("accounts").select("id, agent_id, disabled").eq("id", s.account_id).maybeSingle();
      if (!acct) return json({ ok: false, code: "no_session" }, 403);
      if (acct.disabled) return json({ ok: false, code: "account_disabled" }, 403);
      if (acct.agent_id) {
        // Already settled. Same id is a no-op; a different one is a genuine
        // conflict the app must not paper over by rewriting the binding.
        return acct.agent_id === agentId
          ? json({ ok: true, code: "already_bound" })
          : json({ ok: false, code: "agent_mismatch" }, 409);
      }

      const { data: taken } = await sb
        .from("accounts").select("id").eq("agent_id", agentId).maybeSingle();
      if (taken && taken.id !== acct.id)
        return json({ ok: false, code: "already_linked", detail: "agent" }, 409);

      const { error } = await sb
        .from("accounts").update({ agent_id: agentId }).eq("id", acct.id);
      // accounts.agent_id is UNIQUE, so two phones binding the same id at once
      // race here. 23505 = unique_violation: the other one won, which is the
      // same outcome as the pre-check above.
      if (error) {
        return (error as { code?: string }).code === "23505"
          ? json({ ok: false, code: "already_linked", detail: "agent" }, 409)
          : json({ ok: false, code: "bind_failed" }, 500);
      }
      return json({ ok: true, code: "bound" });
    }

    // ---- send / resend / verify: need a phone -----------------------------
    const phone = normPhone(body.phone);
    if (phone.length !== 12) return json({ ok: false, code: "bad_phone" }, 400);
    const phoneHash = await sha256(phone);
    const deviceId = String(body.deviceId || "").slice(0, 64);
    const ip = (req.headers.get("x-forwarded-for") || "noip").split(",")[0].trim();

    // Play Integrity gate (dormant until app_config.require_integrity=true),
    // matching pay/groq/ingest. Fails closed once enabled.
    const { data: intCfg } = await sb
      .from("app_config").select("value").eq("key", "require_integrity").maybeSingle();
    if (intCfg?.value === true && !req.headers.get("x-integrity-token"))
      return json({ ok: false, code: "integrity_required" }, 403);

    if (action === "send" || action === "resend") {
      if (!authkey || !wa.number || !wa.template) {
        logReq(deviceId, phoneHash, action, "not_configured");
        return json({ ok: false, code: "not_configured" }, 503);
      }
      // Abuse/cost guard. Per-phone cooldown + hourly cap, PLUS per-IP and
      // per-device hourly caps across ALL phones — without the latter two, an
      // anon-key holder could enumerate phone numbers and spam paid WhatsApp
      // OTPs to strangers (5/phone/hr each).
      //
      // Each refusal is logged as well as returned. These rows are how the
      // dashboard's OTP page can say how many paid WhatsApp messages the limits
      // stopped — an unlogged 429 is a saving nobody can see, and the caps are
      // tunable from that same page, so the number is what tells you whether a
      // cap is set too loose (spend climbing) or too tight (real agents stuck).
      if ((await bump(`otpcd:${phoneHash}`, cooldown)) > 1) {
        logReq(deviceId, phoneHash, action, "cooldown");
        return json({ ok: false, code: "cooldown", cooldown }, 429);
      }
      if ((await bump(`otp:${phoneHash}`, 3600)) > maxSendPerHour) {
        logReq(deviceId, phoneHash, action, "rate_limited");
        return json({ ok: false, code: "rate_limited" }, 429);
      }
      if ((await bump(`otpip:${ip}`, 3600)) > maxIpPerHour) {
        logReq(deviceId, phoneHash, action, "rate_limited");
        return json({ ok: false, code: "rate_limited" }, 429);
      }
      if (deviceId && (await bump(`otpdev:${deviceId}`, 3600)) > maxDevicePerHour) {
        logReq(deviceId, phoneHash, action, "rate_limited");
        return json({ ok: false, code: "rate_limited" }, 429);
      }

      // Generate + store (SALTED hash only — a leak of otp_codes can't be
      // brute-forced offline), then deliver over WhatsApp.
      const otp = genOtp(OTP_DIGITS);
      const salt = randomToken(16);
      await sb.from("otp_codes").upsert({
        phone_hash: phoneHash,
        otp_hash: await codeHash(salt, phone, otp),
        salt,
        expires_at: new Date(Date.now() + ttl * 1000).toISOString(),
        attempts: 0,
        created_at: new Date().toISOString(),
      }, { onConflict: "phone_hash" });

      const send = await sendWhatsApp(authkey, wa, phone, otp);
      const reqId = (send.data as { request_id?: string })?.request_id;
      logReq(deviceId, phoneHash, action, send.ok ? "ok" : "provider_error", reqId);
      if (!send.ok)
        return json({
          ok: false, code: "provider_down",
          message: (send.data as { message?: string })?.message ?? "",
        }, 502);
      return json({ ok: true, cooldown });
    }

    if (action === "verify") {
      const otp = String(body.otp || "").replace(/\D/g, "");
      const agentId = String(body.agentId || "").trim();

      const { data: code } = await sb
        .from("otp_codes").select("*").eq("phone_hash", phoneHash).maybeSingle();
      if (!code) {
        logReq(deviceId, phoneHash, "verify", "expired");
        return json({ ok: false, code: "expired" }, 401); // none pending
      }
      if (new Date(code.expires_at).getTime() < Date.now()) {
        await sb.from("otp_codes").delete().eq("phone_hash", phoneHash);
        logReq(deviceId, phoneHash, "verify", "expired");
        return json({ ok: false, code: "expired" }, 401);
      }
      if ((code.attempts ?? 0) >= maxAttempts) {
        await sb.from("otp_codes").delete().eq("phone_hash", phoneHash);
        logReq(deviceId, phoneHash, "verify", "too_many_attempts");
        return json({ ok: false, code: "too_many_attempts" }, 429);
      }
      const expect = await codeHash(String(code.salt ?? ""), phone, otp);
      if (!timingSafeEqual(expect, String(code.otp_hash ?? ""))) {
        await sb.from("otp_codes")
          .update({ attempts: (code.attempts ?? 0) + 1 }).eq("phone_hash", phoneHash);
        logReq(deviceId, phoneHash, "verify", "invalid");
        return json({ ok: false, code: "invalid_otp" }, 401);
      }
      // Correct — consume the code so it can't be replayed.
      await sb.from("otp_codes").delete().eq("phone_hash", phoneHash);

      // --- 1:1 bind phone <-> agent id (with optional phone change) -------
      // Normal verify keeps the pair immutable. When the app sends
      // changePhone=true (the "update mobile number" flow), the SAME agent may
      // move to a new number — but only on TWO proofs, not one: the OTP just
      // verified above shows they control the new number, and a live device
      // session for the existing account shows they are the current owner. An
      // agent id alone is not a secret and must never be enough. Still refuses
      // a number that belongs to a DIFFERENT agent.
      const changePhone = body.changePhone === true;
      const { data: byPhone } = await sb
        .from("accounts").select("id, agent_id, disabled").eq("phone_hash", phoneHash).maybeSingle();
      if (byPhone?.disabled) return json({ ok: false, code: "account_disabled" }, 403);
      if (agentId && byPhone?.agent_id && byPhone.agent_id !== agentId)
        return json({ ok: false, code: "already_linked", detail: "phone" }, 409);

      let accountId: string | undefined = byPhone?.id;
      if (agentId) {
        const { data: byAgent } = await sb
          .from("accounts").select("id, phone_hash").eq("agent_id", agentId).maybeSingle();
        if (byAgent && byAgent.phone_hash !== phoneHash) {
          if (!changePhone)
            return json({ ok: false, code: "already_linked", detail: "agent" }, 409);
          // Prove ownership of the binding being moved. A caller who only knows
          // the agent id gets the same answer as a stranger.
          if (!(await sessionOwns(String(body.token || ""), String(byAgent.id)))) {
            logReq(deviceId, phoneHash, "verify", "reauth_required");
            return json({ ok: false, code: "reauth_required" }, 403);
          }
          // Phone change: free any orphan row on the new number, then move this
          // agent's binding to it. Device sessions stay (account id unchanged).
          if (byPhone) await sb.from("accounts").delete().eq("id", byPhone.id);
          await sb.from("accounts").update({ phone_hash: phoneHash }).eq("id", byAgent.id);
          accountId = byAgent.id;
        } else if (byAgent) {
          accountId = byAgent.id; // re-verifying the same pair
        } else if (byPhone) {
          if (!byPhone.agent_id)
            await sb.from("accounts").update({ agent_id: agentId }).eq("id", byPhone.id);
          accountId = byPhone.id;
        } else {
          const { data: ins } = await sb.from("accounts")
            .insert({ phone_hash: phoneHash, agent_id: agentId }).select("id").single();
          accountId = ins!.id;
        }
      } else if (!accountId) {
        const { data: ins } = await sb.from("accounts")
          .insert({ phone_hash: phoneHash }).select("id").single();
        accountId = ins!.id;
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

      // Mark this install as verified + link it to the account, so the admin
      // dashboard can track only properly-verified users (phone_verified was a
      // dead column before this).
      if (deviceId) {
        await sb.from("devices")
          .update({ phone_verified: true, account_id: accountId })
          .eq("id", deviceId);
      }

      logReq(deviceId, phoneHash, "verify", "ok");
      return json({ ok: true, token, accountId });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
