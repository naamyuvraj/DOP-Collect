import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, Pill, Td, Th } from "@/components/ui";
import { getPlans, getSubscriptions, getSummary, recent } from "@/lib/data";
import { inr, num, when } from "@/lib/format";

export const revalidate = 60; // ISR: instant repeat loads, data ≤60s stale.

type Payment = {
  id: number;
  device_id: string;
  amount: number;
  currency: string;
  plan: string | null;
  provider: string | null;
  status: string;
  created_at: string;
  /**
   * Who paid, and the provider's reference. `pay` has always written both, and
   * the query already selects *, but neither was rendered — so an agent ringing
   * about a charge could not be matched to a row without opening the database.
   */
  agent_id: string | null;
  ref: string | null;
};

const tone = (s: string) => (s === "active" ? "g" : s === "trial" ? "b" : "r");

export default async function Payments() {
  const [s, pays, subs, plans] = await Promise.all([
    getSummary(),
    recent<Payment>("payments", "*", 100),
    getSubscriptions(),
    getPlans(),
  ]);
  const ok = pays.filter((p) => p.status === "success");
  const mrr = ok
    .filter(
      (p) => new Date(p.created_at).getTime() > Date.now() - 30 * 864e5
    )
    .reduce((a, p) => a + Number(p.amount), 0);
  // REAL subscription rows only — this page is about money that moved, and
  // getSubscriptions reads v_subscriptions directly.
  //
  // That makes these numbers legitimately smaller than the Plans and Overview
  // tabs, which include the trial `pay` derives at read time without writing a
  // row. Two tabs quoting different trial counts is not a bug in either, but it
  // reads as one, so the tile says which it is instead of leaving it implied.
  const active = subs.filter((x) => x.status === "active").length;
  const trialing = subs.filter((x) => x.status === "trial").length;

  return (
    <>
      <PageHead title="Payments" subtitle="Subscriptions, revenue & transactions" />
      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-5">
        <Kpi label="Total revenue" value={inr(s.revenue)} focal />
        <Kpi label="Last 30 days" value={inr(mrr)} />
        <Kpi label="Paid subs" value={num(active)}
             sub={`${num(trialing)} trial rows`} />
        <Kpi label="Successful" value={num(ok.length)} />
        <Kpi label="Transactions" value={num(pays.length)} />
      </div>

      <Card title="Plans" className="mt-3.5">
        <div className="flex flex-wrap gap-2.5">
          {plans.map((p) => (
            <div key={p.code} className="rounded-xl border border-line px-4 py-3">
              <div className="font-extrabold text-sm">{p.name}</div>
              <div className="text-muted text-xs">
                {p.price_inr > 0 ? inr(p.price_inr) : "Free"} · {p.duration_days}d
                {p.active ? "" : " · inactive"}
              </div>
            </div>
          ))}
          {!plans.length && <Empty>Run schema_payments.sql to seed plans.</Empty>}
        </div>
      </Card>

      <Card title="Subscribers" className="mt-3.5">
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>Agent ID</Th>
                <Th>Plan</Th>
                <Th>Status</Th>
                <Th>Days left</Th>
                <Th>Renews / ends</Th>
              </tr>
            </thead>
            <tbody>
              {subs.map((x) => (
                <tr key={x.agent_id}>
                  <Td className="font-mono text-xs">{x.agent_id}</Td>
                  <Td className="font-semibold">{x.plan_name || x.plan_code || "—"}</Td>
                  <Td><Pill tone={tone(x.status)}>{x.status}</Pill></Td>
                  <Td className="font-mono">{num(x.days_left)}</Td>
                  <Td className="text-muted whitespace-nowrap">{when(x.current_period_end)}</Td>
                </tr>
              ))}
            </tbody>
          </table>
          {!subs.length && <Empty>No subscribers yet.</Empty>}
        </div>
      </Card>

      <Card title="Transactions" className="mt-3.5">
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>When</Th>
                <Th>Agent ID</Th>
                <Th>Plan</Th>
                <Th>Provider</Th>
                <Th>Reference</Th>
                <Th>Amount</Th>
                <Th>Status</Th>
              </tr>
            </thead>
            <tbody>
              {pays.map((p) => (
                <tr key={p.id}>
                  <Td className="text-muted whitespace-nowrap">{when(p.created_at)}</Td>
                  {/* The two columns support actually needs: who paid, and the
                      reference to quote back to the provider. */}
                  <Td className="font-mono text-xs">{p.agent_id || "—"}</Td>
                  <Td className="font-semibold">{p.plan || "—"}</Td>
                  <Td className="text-muted">{p.provider || "—"}</Td>
                  <Td className="font-mono text-xs text-muted">{p.ref || "—"}</Td>
                  <Td className="font-bold font-mono">{inr(p.amount)}</Td>
                  <Td>
                    <Pill tone={p.status === "success" ? "g" : p.status === "failed" ? "r" : "a"}>
                      {p.status}
                    </Pill>
                  </Td>
                </tr>
              ))}
            </tbody>
          </table>
          {!pays.length && (
            <Empty>No payments yet — wire a provider to start selling.</Empty>
          )}
        </div>
      </Card>
    </>
  );
}
