// API tests for the `otp` edge function, driving the real handler.
//
// Focus: S1 (account takeover via changePhone) and S5 (4-digit codes). The OTP
// is read back out of the outbound WhatsApp payload, so every verify below uses
// the code a real user would have received.

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, load, otpFromWhatsApp, post, sha256Hex } from "./harness.ts";

const ENV = {
  ...BASE_ENV,
  MSG91_AUTHKEY: "authkey-test",
  MSG91_WA_INTEGRATED_NUMBER: "919999999999",
  MSG91_WA_TEMPLATE_NAME: "otp_template",
};

const VICTIM_PHONE = "9810000001";
const ATTACKER_PHONE = "9820000002";
const VICTIM_AGENT = "AGENT-VICTIM-01";

const handler = await load("otp");

/** A db where the victim already owns VICTIM_AGENT on their own phone. */
async function seeded(): Promise<{ db: Db; accountId: string; victimToken: string }> {
  const db = newDb();
  const accountId = crypto.randomUUID();
  db.tables.accounts.push({
    id: accountId,
    phone_hash: await sha256Hex("91" + VICTIM_PHONE),
    agent_id: VICTIM_AGENT,
    disabled: false,
  });
  const victimToken = "victim-live-token";
  db.tables.device_sessions.push({
    id: crypto.randomUUID(),
    account_id: accountId,
    device_id: "victim-phone",
    token_hash: await sha256Hex(victimToken),
    revoked_at: null,
    created_at: new Date().toISOString(),
  });
  return { db, accountId, victimToken };
}

/** Send a code to `phone` and return it, as the recipient would read it. */
async function requestCode(phone: string, deviceId: string): Promise<string> {
  const send = await post(handler, { action: "send", phone, deviceId });
  assertEquals(send.json.ok, true, `send failed: ${JSON.stringify(send.json)}`);
  return otpFromWhatsApp();
}

const phoneHashOf = (p: string) => sha256Hex("91" + p);

// ---------------------------------------------------------------------------
// S1 — the takeover
// ---------------------------------------------------------------------------

Deno.test("S1: agent id alone cannot move an account to a new phone", async () => {
  const { db, accountId } = await seeded();
  begin(db, { env: ENV });

  // The attacker OTPs their OWN number, then claims the victim's agent id.
  const code = await requestCode(ATTACKER_PHONE, "attacker-phone");
  const res = await post(handler, {
    action: "verify",
    phone: ATTACKER_PHONE,
    otp: code,
    agentId: VICTIM_AGENT,
    deviceId: "attacker-phone",
    changePhone: true,
  });

  assertEquals(res.status, 403);
  assertEquals(res.json.code, "reauth_required");
  assertEquals(res.json.token, undefined, "no session may be issued");

  // The victim's binding is untouched.
  const acct = db.tables.accounts.find((a) => a.id === accountId)!;
  assertEquals(acct.phone_hash, await phoneHashOf(VICTIM_PHONE));
  assertEquals(acct.agent_id, VICTIM_AGENT);
});

Deno.test("S1: a session for a DIFFERENT account is not proof of ownership", async () => {
  const { db, accountId } = await seeded();
  // The attacker has a perfectly valid session — for their own account.
  const attackerAccount = crypto.randomUUID();
  db.tables.accounts.push({
    id: attackerAccount, phone_hash: await phoneHashOf("9830000003"),
    agent_id: "AGENT-ATTACKER", disabled: false,
  });
  db.tables.device_sessions.push({
    id: crypto.randomUUID(), account_id: attackerAccount, device_id: "attacker-phone",
    token_hash: await sha256Hex("attacker-own-token"), revoked_at: null,
    created_at: new Date().toISOString(),
  });
  begin(db, { env: ENV });

  const code = await requestCode(ATTACKER_PHONE, "attacker-phone");
  const res = await post(handler, {
    action: "verify", phone: ATTACKER_PHONE, otp: code, agentId: VICTIM_AGENT,
    deviceId: "attacker-phone", changePhone: true, token: "attacker-own-token",
  });

  assertEquals(res.status, 403);
  assertEquals(res.json.code, "reauth_required");
  const acct = db.tables.accounts.find((a) => a.id === accountId)!;
  assertEquals(acct.phone_hash, await phoneHashOf(VICTIM_PHONE));
});

Deno.test("S1: a REVOKED session is not proof of ownership", async () => {
  const { db, accountId, victimToken } = await seeded();
  // e.g. this device was kicked by the 2-device limit.
  db.tables.device_sessions[0].revoked_at = new Date().toISOString();
  db.tables.device_sessions[0].revoked_reason = "device_limit";
  begin(db, { env: ENV });

  const code = await requestCode(ATTACKER_PHONE, "old-phone");
  const res = await post(handler, {
    action: "verify", phone: ATTACKER_PHONE, otp: code, agentId: VICTIM_AGENT,
    deviceId: "old-phone", changePhone: true, token: victimToken,
  });

  assertEquals(res.status, 403);
  assertEquals(res.json.code, "reauth_required");
  const acct = db.tables.accounts.find((a) => a.id === accountId)!;
  assertEquals(acct.phone_hash, await phoneHashOf(VICTIM_PHONE));
});

Deno.test("S1: the real owner CAN still change their number", async () => {
  const { db, accountId, victimToken } = await seeded();
  begin(db, { env: ENV });

  const newPhone = "9840000004";
  const code = await requestCode(newPhone, "victim-phone");
  const res = await post(handler, {
    action: "verify", phone: newPhone, otp: code, agentId: VICTIM_AGENT,
    deviceId: "victim-phone", changePhone: true, token: victimToken,
  });

  assertEquals(res.status, 200);
  assertEquals(res.json.ok, true);
  assert(typeof res.json.token === "string" && (res.json.token as string).length > 0);

  // Same account row, now on the new number — the binding MOVED, not forked.
  assertEquals(res.json.accountId, accountId);
  const acct = db.tables.accounts.find((a) => a.id === accountId)!;
  assertEquals(acct.phone_hash, await phoneHashOf(newPhone));
  assertEquals(acct.agent_id, VICTIM_AGENT);
  assertEquals(db.tables.accounts.filter((a) => a.agent_id === VICTIM_AGENT).length, 1);
});

// ---------------------------------------------------------------------------
// Regressions the fix must not have broken
// ---------------------------------------------------------------------------

Deno.test("without changePhone, a taken agent id is still refused", async () => {
  const { db } = await seeded();
  begin(db, { env: ENV });
  const code = await requestCode(ATTACKER_PHONE, "attacker-phone");
  const res = await post(handler, {
    action: "verify", phone: ATTACKER_PHONE, otp: code,
    agentId: VICTIM_AGENT, deviceId: "attacker-phone",
  });
  assertEquals(res.status, 409);
  assertEquals(res.json.code, "already_linked");
  assertEquals(res.json.detail, "agent");
});

Deno.test("a first-time agent verifies and gets a session", async () => {
  const db = newDb();
  begin(db, { env: ENV });
  const code = await requestCode("9850000005", "fresh-phone");
  const res = await post(handler, {
    action: "verify", phone: "9850000005", otp: code,
    agentId: "AGENT-NEW-01", deviceId: "fresh-phone",
  });
  assertEquals(res.json.ok, true);
  assertEquals(db.tables.accounts.length, 1);
  assertEquals(db.tables.accounts[0].agent_id, "AGENT-NEW-01");
  assertEquals(db.tables.device_sessions.length, 1);
});

Deno.test("a wrong code is refused and burns an attempt", async () => {
  const db = newDb();
  begin(db, { env: ENV });
  const real = await requestCode("9860000006", "d1");
  const wrong = real === "1111" ? "2222" : "1111";
  const res = await post(handler, {
    action: "verify", phone: "9860000006", otp: wrong, agentId: "A1", deviceId: "d1",
  });
  assertEquals(res.status, 401);
  assertEquals(res.json.code, "invalid_otp");
  assertEquals(db.tables.otp_codes[0].attempts, 1);
});

Deno.test("a used code cannot be replayed", async () => {
  const db = newDb();
  begin(db, { env: ENV });
  const code = await requestCode("9870000007", "d1");
  const first = await post(handler, {
    action: "verify", phone: "9870000007", otp: code, agentId: "A2", deviceId: "d1",
  });
  assertEquals(first.json.ok, true);
  const replay = await post(handler, {
    action: "verify", phone: "9870000007", otp: code, agentId: "A2", deviceId: "d2",
  });
  assertEquals(replay.status, 401);
  assertEquals(replay.json.code, "expired");
});

// ---------------------------------------------------------------------------
// S5 — 4 digits, and no longer steerable from app_config
// ---------------------------------------------------------------------------

Deno.test("S5: the delivered code is 4 digits", async () => {
  const db = newDb();
  begin(db, { env: ENV });
  const code = await requestCode("9880000008", "d1");
  assertEquals(code.length, 4);
  assert(/^\d{4}$/.test(code), `not 4 digits: ${code}`);
});

Deno.test("S5: app_config cannot lengthen the code and lock users out", async () => {
  const db = newDb();
  // The footgun: an admin sets digits=6 with no app release.
  db.tables.app_config.push({ key: "otp_limits", value: { digits: 6 } });
  begin(db, { env: ENV });
  const code = await requestCode("9890000009", "d1");
  assertEquals(code.length, 4, "config must not change the code length");

  // And the 4-digit code the app can actually type still verifies.
  const res = await post(handler, {
    action: "verify", phone: "9890000009", otp: code, agentId: "A3", deviceId: "d1",
  });
  assertEquals(res.json.ok, true);
});

Deno.test("codes differ between sends (not a fixed or predictable value)", async () => {
  const seen = new Set<string>();
  for (let i = 0; i < 12; i++) {
    const db = newDb();
    begin(db, { env: ENV });
    seen.add(await requestCode("98100000" + (10 + i), "d" + i));
  }
  assertNotEquals(seen.size, 1, "every code was identical");
  assert(seen.size >= 6, `only ${seen.size} distinct codes in 12 sends`);
});

// ---------------------------------------------------------------------------
// bind_agent — filling in the agent id the "Log in" tab could not supply
// ---------------------------------------------------------------------------

/** An account verified by phone only, as the "Log in" tab leaves it. */
async function unbound(phone: string): Promise<{ db: Db; accountId: string; token: string }> {
  const db = newDb();
  const accountId = crypto.randomUUID();
  db.tables.accounts.push({
    id: accountId,
    phone_hash: await sha256Hex("91" + phone),
    agent_id: null,
    disabled: false,
  });
  const token = "unbound-live-token";
  db.tables.device_sessions.push({
    id: crypto.randomUUID(),
    account_id: accountId,
    device_id: "new-phone",
    token_hash: await sha256Hex(token),
    revoked_at: null,
    created_at: new Date().toISOString(),
  });
  return { db, accountId, token };
}

Deno.test("bind_agent fills a null agent id for the session's own account", async () => {
  const { db, accountId, token } = await unbound("9830000003");
  begin(db);
  const r = await post(handler, { action: "bind_agent", token, agentId: "AGENT-NEW-01" });
  assertEquals(r.json.ok, true);
  assertEquals(r.json.code, "bound");
  assertEquals(db.tables.accounts.find((a) => a.id === accountId)!.agent_id, "AGENT-NEW-01");
});

Deno.test("bind_agent is idempotent for the same id", async () => {
  const { db, token } = await unbound("9830000004");
  begin(db);
  await post(handler, { action: "bind_agent", token, agentId: "AGENT-NEW-02" });
  const again = await post(handler, { action: "bind_agent", token, agentId: "AGENT-NEW-02" });
  assertEquals(again.json.ok, true);
  assertEquals(again.json.code, "already_bound");
});

Deno.test("bind_agent never rewrites an agent id already on the account", async () => {
  const { db, victimToken, accountId } = await seeded();
  begin(db);
  const r = await post(handler, { action: "bind_agent", token: victimToken, agentId: "AGENT-OTHER" });
  assertEquals(r.json.ok, false);
  assertEquals(r.json.code, "agent_mismatch");
  assertEquals(db.tables.accounts.find((a) => a.id === accountId)!.agent_id, VICTIM_AGENT);
});

Deno.test("bind_agent refuses an agent id another account already owns", async () => {
  // The victim owns VICTIM_AGENT; a second, unbound account tries to claim it.
  const { db } = await seeded();
  const otherId = crypto.randomUUID();
  db.tables.accounts.push({
    id: otherId,
    phone_hash: await sha256Hex("91" + ATTACKER_PHONE),
    agent_id: null,
    disabled: false,
  });
  const otherToken = "other-live-token";
  db.tables.device_sessions.push({
    id: crypto.randomUUID(),
    account_id: otherId,
    device_id: "other-phone",
    token_hash: await sha256Hex(otherToken),
    revoked_at: null,
    created_at: new Date().toISOString(),
  });
  begin(db);
  const r = await post(handler, { action: "bind_agent", token: otherToken, agentId: VICTIM_AGENT });
  assertEquals(r.json.ok, false);
  assertEquals(r.json.code, "already_linked");
  assertEquals(r.json.detail, "agent");
  assertEquals(db.tables.accounts.find((a) => a.id === otherId)!.agent_id, null);
});

Deno.test("bind_agent needs a live session — a bare agent id is not proof", async () => {
  const { db } = await unbound("9830000005");
  begin(db);
  const r = await post(handler, { action: "bind_agent", token: "", agentId: "AGENT-NEW-03" });
  assertEquals(r.json.ok, false);
  assertEquals(r.json.code, "no_session");
  assertEquals(db.tables.accounts[0].agent_id, null);
});

Deno.test("bind_agent rejects a REVOKED session", async () => {
  const { db, token } = await unbound("9830000006");
  db.tables.device_sessions[0].revoked_at = new Date().toISOString();
  begin(db);
  const r = await post(handler, { action: "bind_agent", token, agentId: "AGENT-NEW-04" });
  assertEquals(r.json.ok, false);
  assertEquals(r.json.code, "no_session");
  assertEquals(db.tables.accounts[0].agent_id, null);
});

Deno.test("bind_agent needs an agent id", async () => {
  const { db, token } = await unbound("9830000007");
  begin(db);
  const r = await post(handler, { action: "bind_agent", token, agentId: "   " });
  assertEquals(r.json.ok, false);
  assertEquals(r.json.code, "bad_agent");
});
