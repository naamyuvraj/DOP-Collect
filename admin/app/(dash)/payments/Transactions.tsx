"use client";
import { useMemo } from "react";
import { Empty, Pill, Table, Td, Th } from "@/components/ui";
import { inr, when } from "@/lib/format";
import { usePersisted } from "@/lib/uiState";

export type Payment = {
  id: number;
  device_id: string | null;
  amount: number;
  currency: string | null;
  plan: string | null;
  plan_code: string | null;
  provider: string | null;
  status: string;
  created_at: string;
  agent_id: string | null;
  ref: string | null;
  order_id: string | null;
};

/**
 * A row is a real payment if money actually moved. Trials and the ₹0 manual
 * grants written by the Fix-access buttons are bookkeeping, not revenue, and
 * they were burying the handful of rows anyone actually needs to look up.
 */
const isReal = (p: Payment) =>
  Number(p.amount) > 0 && p.provider !== "manual" && p.plan_code !== "trial" && p.plan !== "trial";

const money = (p: Payment) =>
  p.currency && p.currency !== "INR" ? `${p.currency} ${Number(p.amount).toLocaleString("en-IN")}` : inr(p.amount);

export default function Transactions({ pays }: { pays: Payment[] }) {
  const [scope, setScope] = usePersisted<"real" | "all" | "manual">("payments.scope", "real");

  const counts = useMemo(() => {
    const real = pays.filter(isReal).length;
    return { real, manual: pays.length - real, all: pays.length };
  }, [pays]);

  const view = useMemo(
    () => (scope === "all" ? pays : scope === "real" ? pays.filter(isReal) : pays.filter((p) => !isReal(p))),
    [pays, scope]
  );

  const TABS: [typeof scope, string, number][] = [
    ["real", "Payments", counts.real],
    ["manual", "Trials & manual", counts.manual],
    ["all", "All", counts.all],
  ];

  return (
    <>
      <div className="flex flex-wrap items-center gap-2 mb-4 pb-4 border-b border-line">
        <div className="inline-flex rounded-[4px] border border-line overflow-hidden">
          {TABS.map(([k, label, n]) => (
            <button
              key={k}
              onClick={() => setScope(k)}
              className={`text-meta px-3 py-2 transition ${
                scope === k ? "bg-ink text-canvas font-medium" : "bg-card text-muted hover:bg-canvas hover:text-ink"
              }`}
            >
              {label} <span className="tabular-nums opacity-70">{n}</span>
            </button>
          ))}
        </div>
      </div>

      <Table>
        <thead>
          <tr>
            <Th num>Txn</Th>
            <Th>When</Th>
            <Th>Agent ID</Th>
            <Th>Plan</Th>
            <Th>Provider</Th>
            <Th>Order ID</Th>
            <Th>Reference</Th>
            <Th num>Amount</Th>
            <Th>Status</Th>
          </tr>
        </thead>
        <tbody>
          {view.map((p) => (
            <tr key={p.id}>
              {/* The id support quotes back. It is the only handle that is short
                  enough to read down a phone line. */}
              <Td num className="font-mono text-meta text-muted">#{p.id}</Td>
              <Td className="text-muted whitespace-nowrap">{when(p.created_at)}</Td>
              <Td className="font-mono text-meta">{p.agent_id || "—"}</Td>
              <Td className="font-medium">{p.plan || p.plan_code || "—"}</Td>
              <Td className="text-muted">{p.provider || "—"}</Td>
              <Td className="font-mono text-meta text-muted">{p.order_id || "—"}</Td>
              <Td className="font-mono text-meta text-muted">{p.ref || "—"}</Td>
              <Td num className="font-semibold">{money(p)}</Td>
              <Td>
                <Pill tone={p.status === "success" ? "g" : p.status === "failed" ? "r" : "b"}>
                  {p.status}
                </Pill>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>

      {!view.length && (
        scope === "real" ? (
          <Empty action="Every row so far is a trial or a manual grant — no money has moved yet.">
            No real payments
          </Empty>
        ) : (
          <Empty action="Wire a payment provider, then switch payments on under Plans.">
            Nothing recorded yet
          </Empty>
        )
      )}
    </>
  );
}
