"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Bars } from "@/components/LazyCharts";
import { Card, Empty, Pill, Skel, Table, Td, Th } from "@/components/ui";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type Key = {
  id: number;
  provider: string;
  label: string | null;
  key: string;
  enabled: boolean;
};
type Usage = { key_index: number; calls: number; ok_calls: number; ok_pct: number };
type ModelInfo = { id: string; context_window?: number; owned_by?: string };
type ModelsData = {
  selected: string[];
  available: ModelInfo[];
  defaults: string[];
  retired: string[];
  listError?: string | null;
};

export default function Keys() {
  const [keys, setKeys] = useState<Key[]>(() => peekCached<any>("keys")?.keys || []);
  const [usage, setUsage] = useState<Usage[]>(() => peekCached<any>("keys")?.usage || []);
  const [form, setForm] = useState({ provider: "groq", label: "", key: "" });
  const [busy, setBusy] = useState(false);
  const [md, setMd] = useState<ModelsData | null>(null);
  const [pick, setPick] = useState("");
  const [custom, setCustom] = useState("");
  const [note, setNote] = useState("");

  async function loadModels() {
    const r = await fetch("/api/models", { cache: "no-store" }).then((r) => r.json());
    setMd(r);
    setPick("");
  }
  useEffect(() => { loadModels(); }, []);

  function say(m: string) {
    setNote(m);
    setTimeout(() => setNote(""), 2200);
  }

  /** One writer for the list, so ordering, adding and removing can't disagree. */
  async function saveModels(models: string[], what: string) {
    const r = await fetch("/api/models", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ models }),
    }).then((r) => r.json());
    if (!r.ok) return say(r.error || "could not save");
    await loadModels();
    say(what);
  }

  const models = md?.selected ?? [];
  const addModel = (id: string) => {
    const v = id.trim();
    if (!v) return;
    if (models.includes(v)) return say(`${v} is already in the list`);
    saveModels([...models, v], `added ${v}`);
  };
  const removeModel = (id: string) =>
    models.length <= 1
      ? say("keep at least one — an empty list turns the assistant off")
      : saveModels(models.filter((m) => m !== id), `removed ${id}`);
  const move = (i: number, dir: -1 | 1) => {
    const j = i + dir;
    if (j < 0 || j >= models.length) return;
    const next = [...models];
    [next[i], next[j]] = [next[j], next[i]];
    saveModels(next, "order saved");
  };

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

      {/* Models. Kept next to the keys because they fail the same way: the
          assistant stops answering and the cause is a string somewhere. */}
      <Card
        title="Assistant models"
        className="mt-4"
        right={<span className="text-muted text-micro">tried top to bottom</span>}
      >
        <p className="text-muted text-xs mb-3">
          The fallback chain, strongest first. Both the dashboard assistant and the
          app&rsquo;s <code className="font-mono">groq</code> edge function read this list live, so a
          decommissioned model is fixed here — no redeploy, no app update. Groq retired{" "}
          <code className="font-mono">llama-3.3-70b-versatile</code> on 16 Aug 2026 and it now
          returns a hard 404; that outage is why this is a setting.
        </p>

        {md?.retired?.length ? (
          <div className="mb-3 rounded-lg border border-red/30 bg-red/[.14] px-3 py-2 text-body">
            <b>Not served by Groq any more:</b>{" "}
            <span className="font-mono">{md.retired.join(", ")}</span>. Remove them — every call
            to one is a wasted round trip before the fallback runs.
          </div>
        ) : null}
        {md?.listError ? (
          <div className="mb-3 text-amber text-xs font-medium">{md.listError}</div>
        ) : null}

        {!md ? (
          <div className="flex flex-col gap-2">{[0, 1].map((i) => <Skel key={i} className="h-10 w-full" />)}</div>
        ) : (
          <div className="flex flex-col gap-2">
            {models.map((m, i) => {
              const info = md.available.find((a) => a.id === m);
              const gone = md.retired.includes(m);
              return (
                <div key={m} className="flex items-center gap-2 rounded-lg border border-line px-3 py-2">
                  <span className="text-faint text-micro w-4 tabular-nums">{i + 1}</span>
                  <span className={`font-mono text-body ${gone ? "line-through text-muted" : ""}`}>{m}</span>
                  {i === 0 && !gone && <Pill tone="g">primary</Pill>}
                  {gone && <Pill tone="r">retired</Pill>}
                  {info?.context_window ? (
                    <span className="text-faint text-micro">
                      {Math.round(info.context_window / 1024)}k ctx
                      {info.owned_by ? ` · ${info.owned_by}` : ""}
                    </span>
                  ) : null}
                  <div className="ml-auto flex items-center gap-1">
                    <button className="btn btn-ghost py-1 px-2 text-xs" title="Try earlier"
                      disabled={i === 0} onClick={() => move(i, -1)}>&uarr;</button>
                    <button className="btn btn-ghost py-1 px-2 text-xs" title="Try later"
                      disabled={i === models.length - 1} onClick={() => move(i, 1)}>&darr;</button>
                    <button className="btn btn-ghost py-1 px-2 text-xs text-red" title="Remove"
                      onClick={() => removeModel(m)}>Remove</button>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2 mt-3 pt-3 border-t border-line">
          <select className="input max-w-[290px]" value={pick} onChange={(e) => setPick(e.target.value)}>
            <option value="">Add from Groq&rsquo;s live list…</option>
            {(md?.available || [])
              .filter((a) => !models.includes(a.id))
              .map((a) => (
                <option key={a.id} value={a.id}>
                  {a.id}
                  {a.context_window ? ` (${Math.round(a.context_window / 1024)}k)` : ""}
                </option>
              ))}
          </select>
          <button className="btn" disabled={!pick} onClick={() => addModel(pick)}>Add</button>

          {/* Free text as well: a model can be announced before it appears on
              /models, and this page should never be the thing blocking a fix. */}
          <input
            className="input max-w-[240px] font-mono"
            placeholder="or type an id…"
            value={custom}
            onChange={(e) => setCustom(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") { addModel(custom); setCustom(""); } }}
          />
          <button className="btn btn-ghost" disabled={!custom.trim()}
            onClick={() => { addModel(custom); setCustom(""); }}>Add id</button>

          {md && JSON.stringify(models) !== JSON.stringify(md.defaults) && (
            <button className="btn btn-ghost ml-auto"
              title={md.defaults.join(" → ")}
              onClick={() => saveModels(md.defaults, "reset to defaults")}>Reset to defaults</button>
          )}
        </div>
        {note && <div className="text-green text-xs font-medium mt-2">{note}</div>}
      </Card>

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
