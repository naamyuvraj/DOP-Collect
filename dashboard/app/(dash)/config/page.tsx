"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card } from "@/components/ui";

type Cfg = Record<string, any>;

function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      onClick={() => onChange(!on)}
      className={`w-12 h-7 rounded-full transition relative ${on ? "bg-green" : "bg-line"}`}
    >
      <span
        className={`absolute top-1 w-5 h-5 rounded-full bg-white shadow transition-all ${on ? "left-6" : "left-1"}`}
      />
    </button>
  );
}

export default function Config() {
  const [cfg, setCfg] = useState<Cfg>({});
  const [saved, setSaved] = useState("");

  async function load() {
    setCfg(await fetch("/api/config").then((r) => r.json()));
  }
  useEffect(() => {
    load();
  }, []);

  async function save(key: string, value: any) {
    setCfg((c) => ({ ...c, [key]: value }));
    await fetch("/api/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, value }),
    });
    setSaved(key);
    setTimeout(() => setSaved(""), 1500);
  }

  const announcement = cfg.announcement || { text: "", enabled: false };
  const forceUpdate = cfg.force_update || { version: "", message: "", enabled: false };

  return (
    <>
      <PageHead
        title="App Config"
        subtitle="Remote controls read by every install (no app update needed)"
      />

      <div className="grid gap-3.5 lg:grid-cols-2">
        <Card title="Feature flags">
          {[
            ["assistant_cloud", "AI cloud tier", "Master switch for the Groq assistant. Off = every install stays offline-only."],
            ["analytics_default", "Analytics default on", "New installs report anonymous usage unless the user opts out."],
            ["portal_submit", "Portal auto-submit", "Kill switch for making/paying lists on the DOP portal. Off = the “Submit on Portal” buttons are hidden on every install."],
            ["payments_enabled", "Subscriptions / paywall", "Master switch. On = agents whose plan expired are gated to the paywall. Off = everyone has full access (default)."],
          ].map(([key, label, help]) => (
            <div key={key} className="flex items-center justify-between py-3 border-t border-line first:border-0">
              <div className="pr-4">
                <div className="font-semibold text-sm">{label}</div>
                <div className="text-muted text-xs">{help}</div>
              </div>
              <Toggle
                on={cfg[key] !== false}
                onChange={(v) => save(key, v)}
              />
            </div>
          ))}
          {saved && <div className="text-green text-xs font-semibold mt-2">Saved “{saved}”.</div>}
        </Card>

        <Card title="Force update">
          <p className="text-muted text-xs mb-3">
            Installs below this version get a blocking “please update” prompt.
          </p>
          <label className="lbl">Minimum version</label>
          <input
            className="input mt-1 mb-3"
            placeholder="e.g. 0.9.3+12"
            value={forceUpdate.version}
            onChange={(e) => setCfg({ ...cfg, force_update: { ...forceUpdate, version: e.target.value } })}
          />
          <label className="lbl">Message</label>
          <input
            className="input mt-1 mb-3"
            placeholder="Please update to continue"
            value={forceUpdate.message}
            onChange={(e) => setCfg({ ...cfg, force_update: { ...forceUpdate, message: e.target.value } })}
          />
          <div className="flex items-center justify-between">
            <span className="text-sm font-semibold">Enabled</span>
            <Toggle
              on={!!forceUpdate.enabled}
              onChange={(v) => save("force_update", { ...forceUpdate, enabled: v })}
            />
          </div>
          <button className="btn mt-3 w-full" onClick={() => save("force_update", forceUpdate)}>
            Save force-update
          </button>
        </Card>
      </div>

      <Card title="Announcement banner" className="mt-3.5">
        <p className="text-muted text-xs mb-3">
          Shown at the top of the app’s home screen.
        </p>
        <textarea
          className="input min-h-[80px]"
          placeholder="e.g. New: auto-fill captcha is live! Sync to try it."
          value={announcement.text}
          onChange={(e) => setCfg({ ...cfg, announcement: { ...announcement, text: e.target.value } })}
        />
        <div className="flex items-center justify-between mt-3">
          <div className="flex items-center gap-3">
            <span className="text-sm font-semibold">Show banner</span>
            <Toggle
              on={!!announcement.enabled}
              onChange={(v) => save("announcement", { ...announcement, enabled: v })}
            />
          </div>
          <button className="btn" onClick={() => save("announcement", announcement)}>
            Save announcement
          </button>
        </div>
      </Card>
    </>
  );
}
