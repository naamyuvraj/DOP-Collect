"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Bars } from "@/components/LazyCharts";
import { Card, Empty, Pill, Table, Td, Th } from "@/components/ui";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type Key = {
  id: number;
  provider: string;
  label: string | null;
  key: string;
  enabled: boolean;
};
type Usage = { key_index: number; calls: number; ok_calls: number; ok_pct: number };

export default function Keys() {
  const [keys, setKeys] = useState<Key[]>(() => peekCached<any>("keys")?.keys || []);
  const [usage, setUsage] = useState<Usage[]>(() => peekCached<any>("keys")?.usage || []);
  const [form, setForm] = useState({ provider: "groq", label: "", key: "" });
  const [busy, setBusy] = useState(false);

  async function load() {
    const r = await fetch("/api/keys").then((r) => r.json());
    setCached("keys", r);
    setKeys(r.keys || []);
    setUsage(r.usage || []);
  }
  useEffect(() => {
    if (!isFresh("keys")) load();
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

      <div className="grid gap-4 lg:grid-cols-[1.3fr_1fr]">
        <Card title="Calls per key">
          {usageView.length ? (
            <Bars data={usageView} x="name" y="calls" horizontal height={200} />
          ) : (
            <Empty action="Add a key below, then ask the Assistant something — calls show up within the minute.">
              No key calls yet
            </Empty>
          )}
        </Card>
        <Card title="Success rate">
          <Table>
            <thead>
              <tr>
                <Th>Key</Th>
                <Th num>Calls</Th>
                <Th num>OK %</Th>
              </tr>
            </thead>
            <tbody>
              {usage.map((u) => (
                <tr key={u.key_index}>
                  <Td className="font-semibold">Key {u.key_index}</Td>
                  <Td num>{u.calls}</Td>
                  <Td num>
                    <Pill tone={u.ok_pct >= 90 ? "g" : u.ok_pct >= 60 ? "a" : "r"}>
                      {u.ok_pct ?? 0}%
                    </Pill>
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
          {!usage.length && (
            <Empty action="Rotation health appears once the Assistant has run a query.">
              No calls to rate yet
            </Empty>
          )}
        </Card>
      </div>

      <Card title="Managed keys" className="mt-4">
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

        <Table>
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
                      className={`pill ${k.enabled ? "bg-green/[.18] text-[#6FD6A6]" : "bg-red/[.20] text-[#F3A5A5]"}`}
                    >
                      {k.enabled ? "enabled" : "disabled"}
                    </button>
                  </Td>
                  <Td>
                    <button
                      onClick={() => remove(k.id)}
                      className="text-red font-semibold text-xs"
                    >
                      Delete
                    </button>
                  </Td>
                </tr>
              ))}
          </tbody>
        </Table>
        {!keys.length && (
          <Empty action="Paste a Groq key into the field above and press Add key.">
            No managed keys stored
          </Empty>
        )}
      </Card>
    </>
  );
}
