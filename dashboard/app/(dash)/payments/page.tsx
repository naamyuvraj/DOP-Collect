import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, Pill, Td, Th } from "@/components/ui";
import { getSummary, recent } from "@/lib/data";
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
};

export default async function Payments() {
  const [s, pays] = await Promise.all([
    getSummary(),
    recent<Payment>("payments", "*", 100),
  ]);
  const ok = pays.filter((p) => p.status === "success");
  const mrr = ok
    .filter(
      (p) => new Date(p.created_at).getTime() > Date.now() - 30 * 864e5
    )
    .reduce((a, p) => a + Number(p.amount), 0);

  return (
    <>
      <PageHead title="Payments" subtitle="Revenue & transactions" />
      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-4">
        <Kpi label="Total revenue" value={inr(s.revenue)} focal />
        <Kpi label="Last 30 days" value={inr(mrr)} />
        <Kpi label="Successful" value={num(ok.length)} />
        <Kpi label="Transactions" value={num(pays.length)} />
      </div>

      <Card title="Transactions" className="mt-3.5">
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>When</Th>
                <Th>Plan</Th>
                <Th>Provider</Th>
                <Th>Amount</Th>
                <Th>Status</Th>
              </tr>
            </thead>
            <tbody>
              {pays.map((p) => (
                <tr key={p.id}>
                  <Td className="text-muted whitespace-nowrap">{when(p.created_at)}</Td>
                  <Td className="font-semibold">{p.plan || "—"}</Td>
                  <Td className="text-muted">{p.provider || "—"}</Td>
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
