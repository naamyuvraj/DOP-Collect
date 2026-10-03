"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Toggle } from "@/components/ui";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type Cfg = Record<string, any>;


export default function Config() {
  const [cfg, setCfg] = useState<Cfg>(() => peekCached<Cfg>("config") || {});
  const [saved, setSaved] = useState("");

  async function load() {
    const c = await fetch("/api/config", { cache: "no-store" }).then((r) => r.json());
    setCached("config", c);
    setCfg(c);
  }
  useEffect(() => {
    if (!isFresh("config")) load();
  }, []);

  async function save(key: string, value: any) {
    setCfg((c) => { const next = { ...c, [key]: value }; setCached("config", next); return next; });
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

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Feature flags">
          {[
            ["assistant_cloud", "AI cloud tier", "Master switch for the Groq assistant. Off = every install stays offline-only."],
            ["analytics_default", "Analytics default on", "New installs report anonymous usage unless the user opts out."],
            ["portal_submit", "Portal auto-submit", "Kill switch for making/paying lists on the DOP portal. Off = the “Submit on Portal” buttons are hidden on every install."],
            ["payments_enabled", "Subscriptions / paywall", "Master switch. On = agents whose plan expired are gated to the paywall. Off = everyone has full access (default)."],
            ["otp_required", "Phone verification", "Require phone verification at onboarding (1 phone ↔ 1 agent, max 2 devices). Off = no verification (default). Only turn on AFTER the app build with verification is live on phones."],
            ["allow_screenshots", "Allow screenshots", "On = agents can screenshot and screen-record the app (default), which is what makes “send me a picture of it” work. Off = Android blocks capture, casting and the recents thumbnail on every install. The portal login screen is always blocked either way. Applies on the app’s next launch."],
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
          {saved && <div className="text-positive text-xs font-semibold mt-2">Saved “{saved}”.</div>}
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

      <Card title="Announcement banner" className="mt-4">
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
