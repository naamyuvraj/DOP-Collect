"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Bars } from "@/components/LazyCharts";
import { Card, Empty, Pill, Td, Th } from "@/components/ui";

type Key = {
  id: number;
  provider: string;
  label: string | null;
  key: string;
  enabled: boolean;
};
type Usage = { key_index: number; calls: number; ok_calls: number; ok_pct: number };

export default function Keys() {
  const [keys, setKeys] = useState<Key[]>([]);
  const [usage, setUsage] = useState<Usage[]>([]);
  const [form, setForm] = useState({ provider: "groq", label: "", key: "" });
  const [busy, setBusy] = useState(false);

  async function load() {
    const r = await fetch("/api/keys").then((r) => r.json());
    setKeys(r.keys || []);
    setUsage(r.usage || []);
  }
  useEffect(() => {
    load();
  }, []);

  async function add() {
    if (!form.key.trim()) return;
    setBusy(true);
    await fetch("/api/keys", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(form),
    });
    setForm({ provider: "groq", label: "", key: "" });
    setBusy(false);
    load();
  }
  async function toggle(id: number, enabled: boolean) {
    await fetch("/api/keys", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id, enabled }),
    });
    load();
  }
  async function remove(id: number) {
    await fetch("/api/keys", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id }),
    });
    load();
  }

  const usageView = usage.map((u) => ({ ...u, name: `Key ${u.key_index}` }));

  return (
    <>
      <PageHead
        title="API Keys"
        subtitle="Groq key health from live usage, plus a managed key store"
      />

      <div className="grid gap-3.5 lg:grid-cols-[1.3fr_1fr]">
        <Card title="Calls per key">
          {usageView.length ? (
            <Bars data={usageView} x="name" y="calls" horizontal height={200} />
          ) : (
            <Empty>No key calls recorded yet.</Empty>
          )}
        </Card>
        <Card title="Success rate">
          <div className="overflow-x-auto">
            <table className="w-full text-[13px]">
              <thead>
                <tr>
                  <Th>Key</Th>
                  <Th>Calls</Th>
                  <Th>OK %</Th>
                </tr>
              </thead>
              <tbody>
                {usage.map((u) => (
                  <tr key={u.key_index}>
                    <Td className="font-semibold">Key {u.key_index}</Td>
                    <Td>{u.calls}</Td>
                    <Td>
                      <Pill tone={u.ok_pct >= 90 ? "g" : u.ok_pct >= 60 ? "a" : "r"}>
                        {u.ok_pct ?? 0}%
                      </Pill>
                    </Td>
                  </tr>
                ))}
                {!usage.length && (
                  <tr><Td className="text-muted">No data.</Td></tr>
                )}
              </tbody>
            </table>
          </div>
        </Card>
      </div>

      <Card title="Managed keys" className="mt-3.5">
        <p className="text-muted text-xs mb-3">
          Stored server-side (service role only). These feed a future LLM proxy so
          you can rotate keys without shipping an app update.
        </p>
        <div className="flex flex-wrap gap-2 mb-4">
          <select
            className="input max-w-[130px]"
            value={form.provider}
            onChange={(e) => setForm({ ...form, provider: e.target.value })}
          >
            <option value="groq">groq</option>
            <option value="openai">openai</option>
          </select>
          <input
            className="input max-w-[170px]"
            placeholder="Label (optional)"
            value={form.label}
            onChange={(e) => setForm({ ...form, label: e.target.value })}
          />
          <input
            className="input flex-1 min-w-[220px] font-mono"
            placeholder="Paste key (gsk_…)"
            value={form.key}
            onChange={(e) => setForm({ ...form, key: e.target.value })}
          />
          <button className="btn" onClick={add} disabled={busy}>
            {busy ? "Adding…" : "Add key"}
          </button>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>Provider</Th>
                <Th>Label</Th>
                <Th>Key</Th>
                <Th>Enabled</Th>
                <Th></Th>
              </tr>
            </thead>
            <tbody>
              {keys.map((k) => (
                <tr key={k.id}>
                  <Td><Pill>{k.provider}</Pill></Td>
                  <Td className="font-semibold">{k.label || "—"}</Td>
                  <Td className="font-mono text-xs">{k.key}</Td>
                  <Td>
                    <button
                      onClick={() => toggle(k.id, !k.enabled)}
                      className={`pill ${k.enabled ? "bg-greenSoft text-green" : "bg-redSoft text-red"}`}
                    >
                      {k.enabled ? "enabled" : "disabled"}
                    </button>
                  </Td>
                  <Td>
                    <button
                      onClick={() => remove(k.id)}
                      className="text-red font-bold text-xs"
                    >
                      Delete
                    </button>
                  </Td>
                </tr>
              ))}
            </tbody>
          </table>
          {!keys.length && <Empty>No managed keys yet.</Empty>}
        </div>
      </Card>
    </>
  );
}
