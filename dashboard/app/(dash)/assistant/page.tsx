"use client";
import PageHead from "@/components/PageHead";
import { Pill } from "@/components/ui";
import { useEffect, useRef, useState } from "react";

type Msg = {
  role: "user" | "assistant";
  text: string;
  toolsUsed?: string[];
  memoryUsed?: boolean;
  error?: boolean;
};

const SUGGESTIONS = [
  "How many installs and active users do we have?",
  "What are people doing in the app this week?",
  "How healthy are the Groq keys?",
  "Total revenue so far, and recent payments?",
  "Which installs went inactive?",
  "What's the current app config?",
];

export default function AssistantPage() {
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [msgs, busy]);

  async function ask(question: string) {
    const text = question.trim();
    if (!text || busy) return;
    setQ("");
    setMsgs((m) => [...m, { role: "user", text }]);
    setBusy(true);
    try {
      const res = await fetch("/api/agent", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question: text }),
      });
      const data = await res.json().catch(() => ({ error: "The server returned an unreadable response." }));
      if (data.error || !data.answer) {
        setMsgs((m) => [
          ...m,
          { role: "assistant", text: data.error || "No answer was produced.", error: true },
        ]);
      } else {
        setMsgs((m) => [
          ...m,
          { role: "assistant", text: data.answer, toolsUsed: data.toolsUsed, memoryUsed: data.memoryUsed },
        ]);
      }
    } catch {
      setMsgs((m) => [...m, { role: "assistant", text: "Network error — is the dashboard reachable?", error: true }]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <PageHead
        title="Assistant"
        subtitle="Ask about installs, usage, revenue & key health — answered from live data"
        right={
          msgs.length ? (
            <button className="btn btn-ghost" onClick={() => setMsgs([])}>
              Clear
            </button>
          ) : null
        }
      />

      <div className="card p-0 flex flex-col" style={{ height: "calc(100vh - 190px)", minHeight: 460 }}>
        {/* Conversation */}
        <div className="flex-1 overflow-y-auto px-5 py-5">
          {!msgs.length ? (
            <div className="h-full flex flex-col items-center justify-center text-center">
              <div className="w-12 h-12 rounded-2xl bg-focal grid place-items-center text-2xl mb-3">✦</div>
              <div className="font-extrabold text-lg">Ask about your app</div>
              <p className="text-muted text-sm mt-1 max-w-md">
                I read the live analytics — installs, activity, revenue, key usage — and remember what
                you care about across sessions.
              </p>
              <div className="flex flex-wrap gap-2 justify-center mt-5 max-w-2xl">
                {SUGGESTIONS.map((s) => (
                  <button
                    key={s}
                    onClick={() => ask(s)}
                    className="text-[13px] font-semibold rounded-xl border border-line bg-white px-3 py-2 hover:border-green transition"
                  >
                    {s}
                  </button>
                ))}
              </div>
            </div>
          ) : (
            <div className="flex flex-col gap-4 max-w-3xl mx-auto">
              {msgs.map((m, i) => (
                <Bubble key={i} m={m} />
              ))}
              {busy && (
                <div className="self-start">
                  <div className="bg-white border border-line rounded-2xl rounded-tl-sm px-4 py-2.5 text-sm text-muted">
                    <span className="inline-flex gap-1">
                      <Dot /> <Dot d={0.15} /> <Dot d={0.3} />
                    </span>
                  </div>
                </div>
              )}
              <div ref={endRef} />
            </div>
          )}
        </div>

        {/* Composer */}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            ask(q);
          }}
          className="border-t border-line p-3 flex gap-2"
        >
          <input
            className="input flex-1"
            placeholder="Ask about installs, activity, revenue, keys…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            disabled={busy}
            autoFocus
          />
          <button className="btn" disabled={busy || !q.trim()} type="submit">
            {busy ? "…" : "Ask"}
          </button>
        </form>
      </div>
    </>
  );
}

function Bubble({ m }: { m: Msg }) {
  if (m.role === "user") {
    return (
      <div className="self-end max-w-[85%]">
        <div className="bg-ink text-white rounded-2xl rounded-tr-sm px-4 py-2.5 text-sm whitespace-pre-wrap">
          {m.text}
        </div>
      </div>
    );
  }
  return (
    <div className="self-start max-w-[85%]">
      <div
        className={`rounded-2xl rounded-tl-sm px-4 py-3 text-sm whitespace-pre-wrap leading-relaxed border ${
          m.error ? "bg-redSoft border-redSoft text-red" : "bg-white border-line"
        }`}
      >
        {m.text || "…"}
      </div>
      {(m.memoryUsed || (m.toolsUsed && m.toolsUsed.length > 0)) && (
        <div className="flex flex-wrap items-center gap-1.5 mt-1.5 pl-1">
          {m.memoryUsed && <Pill tone="a">memory</Pill>}
          {m.toolsUsed?.map((t, i) => (
            <Pill key={i} tone="g">
              {t}
            </Pill>
          ))}
        </div>
      )}
    </div>
  );
}

function Dot({ d = 0 }: { d?: number }) {
  return (
    <span
      className="w-1.5 h-1.5 rounded-full bg-faint inline-block animate-bounce"
      style={{ animationDelay: `${d}s` }}
    />
  );
}
