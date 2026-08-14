import { NextRequest, NextResponse } from "next/server";
import { revalidateTag, unstable_cache } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";
import { computeUsers } from "@/lib/users";

export const dynamic = "force-dynamic";
export type { UserRow } from "@/lib/users";

// Agent-level rows + totals for the Users tab. All the logic lives in lib/users
// (shared with the Overview so every number agrees). Short cache; telemetry has
// no write hook to bust the tag, so we lean on time — but the admin writes
// below DO bust it, so an edit shows up at once instead of up to 15s later.
const readUsers = unstable_cache(computeUsers, ["users-data"], { revalidate: 15, tags: ["users"] });

export async function GET() {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!dbConfigured()) return NextResponse.json({ rows: [], totals: {} });
  try {
    return NextResponse.json(await readUsers());
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}

/** The device ids named in the body, sanitised and capped. */
function idsFrom(body: unknown): string[] {
  const raw = (body as { deviceIds?: unknown })?.deviceIds;
  if (!Array.isArray(raw)) return [];
  return raw.map((s) => String(s).trim().slice(0, 64)).filter(Boolean).slice(0, 16);
}

const clip = (v: unknown, n: number) => {
  const s = String(v ?? "").trim().slice(0, n);
  return s.length ? s : null; // "" clears the field
};

/**
 * Correct an agent's details.
 *
 * An agent is a GROUP of device rows (one person, up to two phones, merged in
 * lib/users), so an edit has to land on every row in the group — patching only
 * the newest would leave the older one disagreeing, and the reader picks the
 * most recent NON-NULL value per field, so a stale row can resurface later.
 *
 * This is also the manual repair path for a number that never synced: the app
 * only reports a mobile when analytics are on, so an agent who opted out will
 * never populate it by themselves.
 */
export async function PATCH(req: NextRequest) {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!dbConfigured()) return NextResponse.json({ ok: false, error: "no database" }, { status: 503 });

  try {
    const body = await req.json().catch(() => ({}));
    const ids = idsFrom(body);
    if (!ids.length) return NextResponse.json({ ok: false, error: "deviceIds required" }, { status: 400 });

    const p = (body as { patch?: Record<string, unknown> }).patch ?? {};
    const row: Record<string, string | null> = {};
    // There is ONE name and it is `agent_name`. `devices.name` was the second,
    // retired name column and is dropped by admin/schema_one_name.sql — writing
    // it here after the drop would fail the whole patch with a 42703.
    if ("agent_name" in p) row.agent_name = clip(p.agent_name, 80);
    if ("agent_id" in p) row.agent_id = clip(p.agent_id, 64);
    if ("sol_id" in p) row.sol_id = clip(p.sol_id, 32);
    if ("mobile" in p) {
      const digits = String(p.mobile ?? "").replace(/\D/g, "").slice(-10);
      if (digits && digits.length !== 10) {
        return NextResponse.json(
          { ok: false, error: "mobile must be 10 digits" }, { status: 400 });
      }
      row.mobile = digits || null;
    }
    if (!Object.keys(row).length) {
      return NextResponse.json({ ok: false, error: "nothing to change" }, { status: 400 });
    }

    const { error } = await admin().from("devices").update(row).in("id", ids);
    if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 500 });

    revalidateTag("users");
    return NextResponse.json({ ok: true, updated: ids.length, fields: Object.keys(row) });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 500 });
  }
}

/**
 * Remove an agent: their installs, their telemetry, their sessions and the
 * phone/agent-id binding that reserves their identity.
 *
 * Deliberately NOT deleted: `payments` and `subscriptions`. Those are the money
 * trail — a deleted user must never take an accounting record with them, and if
 * the same agent id signs up again their entitlement is still theirs. Deleting
 * the `accounts` row is what frees the phone number and the agent id for reuse.
 *
 * Irreversible, so it needs an explicit confirm token rather than a stray POST.
 */
export async function DELETE(req: NextRequest) {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!dbConfigured()) return NextResponse.json({ ok: false, error: "no database" }, { status: 503 });

  try {
    const body = await req.json().catch(() => ({}));
    const ids = idsFrom(body);
    if (!ids.length) return NextResponse.json({ ok: false, error: "deviceIds required" }, { status: 400 });
    if ((body as { confirm?: string }).confirm !== "DELETE") {
      return NextResponse.json({ ok: false, error: "confirm required" }, { status: 400 });
    }

    const sb = admin();
    // The accounts these installs belong to, so the binding goes with them.
    const { data: devs } = await sb.from("devices").select("account_id").in("id", ids);
    const accountIds = [...new Set(
      ((devs as { account_id: string | null }[]) || [])
        .map((d) => d.account_id).filter((v): v is string => !!v),
    )];

    const removed: Record<string, string> = {};
    const step = async (what: string, run: () => Promise<{ error: unknown }>) => {
      const { error } = await run();
      if (error) removed[what] = `failed: ${(error as { message?: string }).message ?? error}`;
    };

    await step("events", () => sb.from("events").delete().in("device_id", ids) as never);
    await step("key_usage", () => sb.from("key_usage").delete().in("device_id", ids) as never);
    if (accountIds.length) {
      await step("sessions", () =>
        sb.from("device_sessions").delete().in("account_id", accountIds) as never);
    }
    await step("devices", () => sb.from("devices").delete().in("id", ids) as never);
    if (accountIds.length) {
      await step("accounts", () => sb.from("accounts").delete().in("id", accountIds) as never);
    }

    revalidateTag("users");
    const failures = Object.entries(removed);
    return NextResponse.json({
      ok: failures.length === 0,
      devices: ids.length,
      accounts: accountIds.length,
      // Named explicitly so the operator knows what was left behind on purpose.
      kept: ["payments", "subscriptions"],
      ...(failures.length ? { problems: Object.fromEntries(failures) } : {}),
    });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 500 });
  }
}
