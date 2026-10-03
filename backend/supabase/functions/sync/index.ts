// Supabase Edge Function: sync
// ---------------------------------------------------------------------------
// Two-way sync of the agent's book — accounts, the collections ledger, saved
// lists — between his devices. This is what gives the desktop app something to
// show: until now nothing an agent would miss existed on the server.
//
// One call does a push and a pull, in that order, because a client that has
// just written wants the merged result in the same round trip.
//
//   POST { token, cursor?, push?, limit? }
//     ->  { ok, pull: {accounts,collections,lots}, cursor, more, pushed }
//
// WHAT THIS FUNCTION IS AND IS NOT
// --------------------------------
// It is the authority on WHOSE book is being touched, and nothing else. The
// account id comes from the device session, never from the request body — a
// client cannot name someone else's book. Everything after that (last-write-
// wins, cursor paging, in-batch dedupe) is in backend/schema/schema_book.sql, because
// each of those has to be atomic with the write and cannot be done safely from
// here. See the header of that file.
//
// NOT ENFORCED HERE, DELIBERATELY:
//   * Play Integrity. The `ingest` function can demand it because only the
//     Android app calls it. The desktop web app has no attestation to offer, so
//     gating sync on it would lock the browser out by design.
//
// The 2-device limit is not this function's job either: it is enforced at
// `verify` time in the otp function, and a device kicked by it has its session
// revoked — which lands here as `no_session` on the very next sync.
//
// Deploy:
//   supabase functions deploy sync --project-ref ojorpmtptryldizogtkz --use-api
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
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Rows accepted per table per request. */
const MAX_PUSH = 2000;
/** Rows returned per table per request. The client loops until `more` is false. */
const DEFAULT_PULL = 1000;
const MAX_PULL = 5000;

const EPOCH = "1970-01-01T00:00:00.000Z";

type Cursor = { t: string; k: string };
const cleanCursor = (c: unknown): Cursor => {
  const o = (c ?? {}) as Record<string, unknown>;
  const t = typeof o.t === "string" && o.t ? o.t : EPOCH;
  const k = typeof o.k === "string" ? o.k.slice(0, 128) : "";
  // A malformed timestamp would make Postgres throw on every sync forever, and
  // the client has no way to recover a cursor it can't parse either. Fall back
  // to a full re-pull instead: expensive once, correct always.
  return { t: Number.isFinite(Date.parse(t)) ? t : EPOCH, k };
};

const TABLES = ["accounts", "collections", "lots"] as const;
type Table = (typeof TABLES)[number];

/** The key column each table pages on — must match the pull RPC's ORDER BY. */
const PAGE_KEY: Record<Table, string> = {
  accounts: "account_number",
  collections: "uid",
  lots: "uid",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "post_only" }, 405);

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const body = await req.json().catch(() => ({}));
    const token = String(body.token || "");
    if (!token) return json({ ok: false, code: "no_session" }, 403);

    // ---- Whose book? ------------------------------------------------------
    // The session row supplies BOTH the account id and the device id. Taking
    // the device id from the session rather than the body matters: it is what
    // the echo guard keys on, and a client that could name any device id could
    // suppress another device's pull by impersonating it.
    const { data: session } = await sb
      .from("device_sessions")
      .select("id, account_id, device_id, revoked_at, revoked_reason")
      .eq("token_hash", await sha256(token))
      .maybeSingle();

    if (!session) return json({ ok: false, code: "no_session" }, 403);
    if (session.revoked_at) {
      return json(
        { ok: false, code: "no_session", reason: session.revoked_reason || "revoked" },
        403,
      );
    }

    const accountId = session.account_id as string;
    const device = String(session.device_id || "").slice(0, 64);

    // A disabled agent keeps a live session (so the app can still explain
    // itself) but must not move data either way.
    const { data: acct } = await sb
      .from("accounts").select("disabled").eq("id", accountId).maybeSingle();
    if (!acct) return json({ ok: false, code: "no_session" }, 403);
    if (acct.disabled) return json({ ok: false, code: "disabled" }, 403);

    // ---- Rate limit -------------------------------------------------------
    // Same helper the ingest function uses. Generous: a first sync of a large
    // book is many calls in a row, and that must never be mistaken for abuse.
    const bump = async (k: string, s: number): Promise<number> =>
      ((await sb.rpc("bump_rate", { p_device: k, p_window_secs: s })).data as number) ?? 0;
    if ((await bump(`sync:${device}`, 60)) > 240) {
      return json({ ok: false, code: "rate" }, 429);
    }

    // ---- Push -------------------------------------------------------------
    // Order matters. Push first so the caller's own writes are already merged
    // before the pull runs, and a device that made an edit sees the settled
    // result in the same round trip instead of on the next one.
    const push = (body.push ?? {}) as Record<string, unknown>;
    const pushed: Record<Table, number> = { accounts: 0, collections: 0, lots: 0 };

    for (const table of TABLES) {
      const rows = push[table];
      if (!Array.isArray(rows) || rows.length === 0) continue;
      if (rows.length > MAX_PUSH) {
        return json(
          { ok: false, code: "too_many", table, max: MAX_PUSH, sent: rows.length },
          413,
        );
      }
      const { data, error } = await sb.rpc(`book_push_${table}`, {
        p_account_id: accountId,
        p_rows: rows,
        p_device: device,
      });
      if (error) {
        console.error(`push ${table} failed`, error.message);
        return json({ ok: false, code: "push_failed", table }, 500);
      }
      pushed[table] = (data as number) ?? 0;
    }

    // ---- Pull -------------------------------------------------------------
    // Anything that is not a positive number means "not specified". Clamping
    // instead would turn a stray -1 into a page size of ONE, and a real ledger
    // would then need tens of thousands of round trips to drain — slow enough
    // to look like sync is broken, with nothing in the logs to say why.
    const wanted = Number(body.limit);
    const limit = Number.isFinite(wanted) && wanted > 0
      ? Math.min(Math.trunc(wanted), MAX_PULL)
      : DEFAULT_PULL;
    const inCursor = (body.cursor ?? {}) as Record<string, unknown>;

    const pull: Record<Table, unknown[]> = { accounts: [], collections: [], lots: [] };
    const outCursor: Record<Table, Cursor> = {
      accounts: cleanCursor(inCursor.accounts),
      collections: cleanCursor(inCursor.collections),
      lots: cleanCursor(inCursor.lots),
    };
    // True when at least one table filled its page — the client should call
    // again straight away rather than wait for the next sync interval.
    let more = false;

    for (const table of TABLES) {
      const cur = outCursor[table];
      const { data, error } = await sb.rpc(`book_pull_${table}`, {
        p_account_id: accountId,
        p_since: cur.t,
        p_key: cur.k,
        p_limit: limit,
        p_device: device,
      });
      if (error) {
        console.error(`pull ${table} failed`, error.message);
        return json({ ok: false, code: "pull_failed", table }, 500);
      }
      const rows = (data as Record<string, unknown>[]) ?? [];
      pull[table] = rows;

      // Advance the cursor to the LAST row of the page, not to now(): the rows
      // beyond this page may share its timestamp, and only the (timestamp, key)
      // pair distinguishes them. The RPC's ORDER BY guarantees the last row is
      // the furthest along.
      if (rows.length > 0) {
        const last = rows[rows.length - 1];
        outCursor[table] = {
          t: String(last.updated_at),
          k: String(last[PAGE_KEY[table]] ?? ""),
        };
      }
      if (rows.length >= limit) more = true;
    }

    // Sync is the most reliable signal that a device is alive — more so than
    // the app-open heartbeat, which a backgrounded phone never sends.
    await sb.from("device_sessions")
      .update({ last_seen: new Date().toISOString() })
      .eq("id", session.id);

    return json({ ok: true, pull, cursor: outCursor, more, pushed });
  } catch (e) {
    console.error("sync failed", e);
    return json({ ok: false, code: "error" }, 500);
  }
});
