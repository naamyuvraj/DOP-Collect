// S3 / S4 — the two ways the public anon key could be turned against us.
//
// S3: `groq` is an LLM relay billed to our keys. The anon key ships inside the
//     APK and `x-device-id` is whatever the caller says, so the per-device caps
//     never bound anything. A device session is the one credential here that
//     cannot be minted for free.
// S4: `devices` rows are keyed by a uuid the app invents, so anyone could
//     rewrite a real agent's name, mobile and agent id — the exact fields the
//     admin panel reads an agent's identity from.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, fetchCalls, load, post, sha256Hex } from "./harness.ts";

const TOKEN = "live-session-token";
const OTHER_TOKEN = "someone-elses-token";

async function seeded(
  { otpRequired = true, paymentsEnabled = false } = {},
): Promise<Db> {
  const db = newDb();
  const account = "acct-1";
  const other = "acct-2";
  db.tables.accounts.push(
    { id: account, agent_id: "AGENT-1", phone_hash: "h1", disabled: false },
    { id: other, agent_id: "AGENT-2", phone_hash: "h2", disabled: false },
  );
  db.tables.device_sessions.push(
    {
      id: "s1", account_id: account, device_id: "dev-mine",
      token_hash: await sha256Hex(TOKEN), revoked_at: null,
    },
    {
      id: "s2", account_id: other, device_id: "dev-theirs",
      token_hash: await sha256Hex(OTHER_TOKEN), revoked_at: null,
    },
  );
  db.tables.app_config.push(
    { key: "otp_required", value: otpRequired },
    { key: "payments_enabled", value: paymentsEnabled },
  );
  return db;
}

// ---------------------------------------------------------------------------
// S3 — the LLM relay
// ---------------------------------------------------------------------------

const groq = await load("groq");
const ask = (extra: Record<string, unknown> = {}) => ({
  system: "you are a helpful assistant",
  user: "hello",
  ...extra,
});

/** A Groq-shaped completion, so the proxy's success path runs. */
const groqReply = () => ({
  status: 200,
  json: { choices: [{ message: { content: "{}" } }] },
});

function withKeys(db: Db) {
  db.tables.app_keys = [{ id: 1, provider: "groq", key: "gsk_test", enabled: true }];
  return db;
}

Deno.test("S3: with OTP required, an unverified caller gets no inference", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  const res = await post(groq, ask()); // no token — an extracted anon key

  assertEquals(res.status, 401);
  assertEquals(res.json.error, "verification_required");
  assertEquals(fetchCalls.length, 0, "Groq must never be called");
});

Deno.test("S3: a revoked session is not a session", async () => {
  const db = withKeys(await seeded());
  db.tables.device_sessions[0].revoked_at = new Date().toISOString();
  begin(db, { env: BASE_ENV, reply: groqReply });

  const res = await post(groq, ask({ token: TOKEN }));
  assertEquals(res.status, 401);
  assertEquals(fetchCalls.length, 0);
});

Deno.test("S3: a verified agent is served", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  const res = await post(groq, ask({ token: TOKEN }));
  assertEquals(res.status, 200);
  assertEquals(res.json.content, "{}");
  assertEquals(fetchCalls.length, 1);
});

Deno.test("S3: with OTP off, the gate stands down rather than killing the assistant",
  async () => {
    const db = withKeys(await seeded({ otpRequired: false }));
    begin(db, { env: BASE_ENV, reply: groqReply });

    const res = await post(groq, ask()); // no token, and none exists to give
    assertEquals(res.status, 200);
    assertEquals(fetchCalls.length, 1);
  });

Deno.test("S3: an off-menu model is refused, not relayed", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  await post(groq, ask({ token: TOKEN, models: ["some-enormous-expensive-model"] }));

  assertEquals(fetchCalls.length, 1);
  const sent = fetchCalls[0].body as { model: string };
  assert(
    sent.model === "openai/gpt-oss-120b",
    `fell back to the default, got ${sent.model}`,
  );
});

Deno.test("S3: a permitted model preference is still honoured", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  await post(groq, ask({ token: TOKEN, models: ["openai/gpt-oss-20b"] }));

  assertEquals((fetchCalls[0].body as { model: string }).model, "openai/gpt-oss-20b");
});

Deno.test("S3: output length is capped no matter what is asked for", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  await post(groq, ask({ token: TOKEN, maxTokens: 500000 }));

  const sent = fetchCalls[0].body as { max_tokens: number };
  assertEquals(sent.max_tokens, 1024);
});

Deno.test("S3: an enormous prompt is truncated, not forwarded whole", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  await post(groq, {
    system: "s".repeat(200_000),
    user: "u".repeat(200_000),
    token: TOKEN,
  });

  const sent = fetchCalls[0].body as { messages: { content: string }[] };
  assertEquals(sent.messages[0].content.length, 12000);
  assertEquals(sent.messages[1].content.length, 4000);
});

Deno.test("S3: an empty prompt is rejected before any key is spent", async () => {
  const db = withKeys(await seeded());
  begin(db, { env: BASE_ENV, reply: groqReply });

  const res = await post(groq, { system: "", user: "", token: TOKEN });
  assertEquals(res.status, 400);
  assertEquals(fetchCalls.length, 0);
});

// ---------------------------------------------------------------------------
// S4 — rewriting someone else's device row
// ---------------------------------------------------------------------------

const ingest = await load("ingest");

const deviceRow = (over: Record<string, unknown> = {}) => ({
  kind: "device",
  row: {
    id: "dev-mine", name: "Real Agent", mobile: "9810000001",
    agent_id: "AGENT-1", sol_id: "SOL1", app_version: "0.9.50+24",
    ...over,
  },
});

Deno.test("S4: a verified agent's row cannot be rewritten by a stranger", async () => {
  const db = await seeded();
  // The row as it stands after the agent verified their phone.
  db.tables.devices.push({
    id: "dev-mine", account_id: "acct-1", name: "Real Agent",
    mobile: "9810000001", agent_id: "AGENT-1",
  });
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, deviceRow({
    name: "Impostor", mobile: "9990000000", agent_id: "AGENT-STOLEN",
  })); // no token

  assertEquals(res.status, 403);
  assertEquals(res.json.error, "not_your_device");
  const row = db.tables.devices.find((d) => d.id === "dev-mine")!;
  assertEquals(row.name, "Real Agent");
  assertEquals(row.mobile, "9810000001");
  assertEquals(row.agent_id, "AGENT-1");
});

Deno.test("S4: another agent's valid token is not a key to this row", async () => {
  const db = await seeded();
  db.tables.devices.push({ id: "dev-mine", account_id: "acct-1", name: "Real Agent" });
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, {
    ...deviceRow({ name: "Impostor" }),
    token: OTHER_TOKEN,
  });

  assertEquals(res.status, 403);
  assertEquals(db.tables.devices[0].name, "Real Agent");
});

Deno.test("S4: the owner can still update their own row", async () => {
  const db = await seeded();
  db.tables.devices.push({ id: "dev-mine", account_id: "acct-1", name: "Old Name" });
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, { ...deviceRow({ name: "New Name" }), token: TOKEN });

  assertEquals(res.json.ok, true);
  assertEquals(db.tables.devices[0].name, "New Name");
});

Deno.test("S4: a fresh install with no claim yet still reports normally", async () => {
  // Nothing to protect before verification — first-run telemetry is unchanged.
  const db = await seeded();
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, deviceRow({ id: "dev-brand-new" }));

  assertEquals(res.json.ok, true);
  assertEquals(db.tables.devices.length, 1);
});

Deno.test("S4: an unclaimed row is still open (agent mid-onboarding)", async () => {
  const db = await seeded();
  db.tables.devices.push({ id: "dev-mine", account_id: null, name: "Half done" });
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, deviceRow({ name: "Finished" }));
  assertEquals(res.json.ok, true);
  assertEquals(db.tables.devices[0].name, "Finished");
});

Deno.test("S4: plain events are unaffected — they carry no identity", async () => {
  const db = await seeded();
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, {
    kind: "event",
    row: { device_id: "dev-mine", event: "app_open", props: {} },
  });
  assertEquals(res.json.ok, true);
  assertEquals(db.tables.events.length, 1);
});

// ---------------------------------------------------------------------------
// A failed write must never report success
// ---------------------------------------------------------------------------

Deno.test("a write that fails is reported, not swallowed", async () => {
  const db = await seeded();
  db.failWrite = {
    table: "devices",
    op: "upsert",
    error: { code: "23502", message: 'null value in column "platform"' },
  };
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, deviceRow({ id: "dev-new" }));

  assertEquals(res.status, 500);
  assertEquals(res.json.ok, false);
  assert(String(res.json.error).includes("platform"));
});

Deno.test("a missing model column costs the model, not the whole row", async () => {
  // The app and the schema deploy separately, so a build can send `model`
  // before the migration lands. That used to fail the entire upsert — and
  // report ok — so last_seen, name and mobile silently stopped updating too.
  const db = await seeded();
  db.failWrite = {
    table: "devices",
    op: "upsert",
    error: { code: "42703", message: 'column "model" does not exist' },
  };
  begin(db, { env: BASE_ENV });

  const res = await post(ingest, deviceRow({ id: "dev-new", model: "Redmi Note 12" }));

  assertEquals(res.json.ok, true, "the rest of the row must still land");
  const saved = db.tables.devices.find((d) => d.id === "dev-new");
  assert(saved, "row should exist");
  assertEquals(saved!.name, "Real Agent");
  assertEquals(saved!.mobile, "9810000001");
  assertEquals(saved!.model, undefined, "dropped, because the column is not there");
});

Deno.test("when the column DOES exist the model is stored", async () => {
  const db = await seeded();
  begin(db, { env: BASE_ENV });
  await post(ingest, deviceRow({ id: "dev-new", model: "Redmi Note 12" }));
  assertEquals(db.tables.devices.find((d) => d.id === "dev-new")!.model,
    "Redmi Note 12");
});

Deno.test("an older build that sends no model does not wipe a known one", async () => {
  const db = await seeded();
  db.tables.devices.push({ id: "dev-old", account_id: null, model: "Pixel 7" });
  begin(db, { env: BASE_ENV });
  await post(ingest, { kind: "device", row: { id: "dev-old", name: "X" } });
  assertEquals(db.tables.devices[0].model, "Pixel 7");
});

Deno.test("S4: a device write with no id is refused", async () => {
  const db = await seeded();
  begin(db, { env: BASE_ENV });
  const res = await post(ingest, { kind: "device", row: { name: "nobody" } });
  assertEquals(res.status, 400);
});
