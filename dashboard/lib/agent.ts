// The DOP Collect admin analytics agent.
// ---------------------------------------------------------------------------
// A tool-calling loop over Groq. The agent is given a FIXED catalog of
// read-only, parameterised queries over the analytics views — never free-form
// SQL. That matters: the dashboard holds the service_role key, which bypasses
// RLS, so we never let a model author SQL. Each tool maps to a safe, bounded
// Supabase read. Memory (Maximem Synap) is layered in by the API route, not
// here: this module just answers a question given some recalled context.
// ---------------------------------------------------------------------------
import { admin, dbConfigured } from "./supabase";
import { ChatMessage, groqChat, ToolSpec } from "./groq";

// --- Tool catalog ----------------------------------------------------------

export const TOOLS: ToolSpec[] = [
  {
    type: "function",
    function: {
      name: "get_overview",
      description:
        "Top-line totals: installs, active devices (1d/7d/30d), total syncs, total AI queries, lifetime revenue (INR), and Groq key calls in the last 24h.",
      parameters: { type: "object", properties: {} },
    },
  },
  {
    type: "function",
    function: {
      name: "get_events_by_type",
      description:
        "Every event name with its total count and the number of distinct devices that fired it. Good for 'what are users doing'.",
      parameters: { type: "object", properties: {} },
    },
  },
  {
    type: "function",
    function: {
      name: "get_daily_active",
      description: "Daily active devices and daily event counts for the last N days (default 30).",
      parameters: {
        type: "object",
        properties: { days: { type: "integer", description: "How many recent days, 1-90." } },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "get_revenue_by_day",
      description: "Successful revenue (INR) and payment counts per day for the last N days (default 30).",
      parameters: {
        type: "object",
        properties: { days: { type: "integer", description: "How many recent days, 1-90." } },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "get_key_usage",
      description: "Per-Groq-key health: total calls, successful calls, and success percentage.",
      parameters: { type: "object", properties: {} },
    },
  },
  {
    type: "function",
    function: {
      name: "list_recent_events",
      description: "The most recent analytics events, newest first. Optionally filter by event name.",
      parameters: {
        type: "object",
        properties: {
          limit: { type: "integer", description: "1-50, default 15." },
          event: { type: "string", description: "Optional exact event name to filter by, e.g. sync_done." },
        },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "list_devices",
      description:
        "Installs (anonymous devices) with agent label, app version, and last-seen. Optional status filter: 'active' (seen in 7d) or 'inactive'.",
      parameters: {
        type: "object",
        properties: {
          limit: { type: "integer", description: "1-50, default 15." },
          status: { type: "string", enum: ["active", "inactive"], description: "Optional." },
        },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "list_payments",
      description: "Recent payments, newest first (amount, plan, provider, status).",
      parameters: {
        type: "object",
        properties: { limit: { type: "integer", description: "1-50, default 15." } },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "get_app_config",
      description:
        "Current remote app config the app reads at runtime: feature flags, announcement banner, force-update settings.",
      parameters: { type: "object", properties: {} },
    },
  },
];

// --- Tool executors --------------------------------------------------------

const clamp = (n: unknown, lo: number, hi: number, dflt: number) => {
  const v = Math.floor(Number(n));
  return Number.isFinite(v) ? Math.max(lo, Math.min(hi, v)) : dflt;
};

async function readView(name: string) {
  const { data, error } = await admin().from(name).select("*");
  if (error) return { error: error.message };
  return data || [];
}

async function execTool(name: string, args: Record<string, unknown>): Promise<unknown> {
  if (!dbConfigured()) return { error: "Supabase not configured." };
  const sb = admin();

  switch (name) {
    case "get_overview": {
      const rows = await readView("v_summary");
      return Array.isArray(rows) ? rows[0] ?? {} : rows;
    }
    case "get_events_by_type":
      return await readView("v_events_by_type");
    case "get_key_usage":
      return await readView("v_key_usage");
    case "get_daily_active": {
      const days = clamp(args.days, 1, 90, 30);
      const rows = await readView("v_daily_active");
      return Array.isArray(rows) ? rows.slice(-days) : rows;
    }
    case "get_revenue_by_day": {
      const days = clamp(args.days, 1, 90, 30);
      const rows = await readView("v_revenue_by_day");
      return Array.isArray(rows) ? rows.slice(-days) : rows;
    }
    case "list_recent_events": {
      const limit = clamp(args.limit, 1, 50, 15);
      let q = sb
        .from("events")
        .select("device_id,event,props,app_version,created_at")
        .order("created_at", { ascending: false })
        .limit(limit);
      if (typeof args.event === "string" && args.event.trim()) q = q.eq("event", args.event.trim());
      const { data, error } = await q;
      return error ? { error: error.message } : data || [];
    }
    case "list_devices": {
      const limit = clamp(args.limit, 1, 50, 15);
      const { data, error } = await sb
        .from("devices")
        .select("id,agent_name,app_version,platform,model,first_seen,last_seen")
        .order("last_seen", { ascending: false })
        .limit(200);
      if (error) return { error: error.message };
      const cutoff = Date.now() - 7 * 864e5;
      let rows = (data || []).map((d: any) => ({
        ...d,
        id: String(d.id).slice(0, 8),
        status: new Date(d.last_seen).getTime() >= cutoff ? "active" : "inactive",
      }));
      if (args.status === "active" || args.status === "inactive")
        rows = rows.filter((r) => r.status === args.status);
      return rows.slice(0, limit);
    }
    case "list_payments": {
      const limit = clamp(args.limit, 1, 50, 15);
      const { data, error } = await sb
        .from("payments")
        .select("device_id,amount,currency,plan,provider,status,created_at")
        .order("created_at", { ascending: false })
        .limit(limit);
      return error ? { error: error.message } : data || [];
    }
    case "get_app_config": {
      const { data, error } = await sb.from("app_config").select("key,value,updated_at");
      if (error) return { error: error.message };
      const map: Record<string, unknown> = {};
      for (const r of data || []) map[(r as any).key] = (r as any).value;
      return map;
    }
    default:
      return { error: `unknown tool ${name}` };
  }
}

// --- The loop --------------------------------------------------------------

function systemPrompt(memory: string): string {
  const today = new Date().toISOString().slice(0, 10);
  return [
    "You are the analytics assistant for the DOP Collect admin dashboard.",
    "DOP Collect is an Android app for an India Post recurring-deposit collection agent; this dashboard tracks the app's own usage across all installs.",
    `Today is ${today}.`,
    "",
    "Answer questions about installs, active users, events, syncs, AI-assistant usage, revenue, Groq key health, devices, payments, and app config.",
    "Use the provided tools to fetch real numbers — never invent figures. Call several tools if needed, then answer.",
    "The data is anonymous telemetry only: there is NO customer PII (no names, account numbers, or the questions end-users typed). If asked for that, say it isn't collected.",
    "Be concise and specific. Format money as ₹ with Indian digit grouping. Prefer a short sentence or a tight bulleted list. Round sensibly.",
    memory ? `\nWhat you already know about this admin (from memory):\n${memory}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

export type AgentAnswer = { answer: string; toolsUsed: string[]; error?: string };

export async function runAgent(question: string, memory = ""): Promise<AgentAnswer> {
  const messages: ChatMessage[] = [
    { role: "system", content: systemPrompt(memory) },
    { role: "user", content: question },
  ];
  const toolsUsed: string[] = [];

  for (let round = 0; round < 6; round++) {
    const { message, error } = await groqChat(messages, { tools: TOOLS, maxTokens: 900 });
    if (error || !message) return { answer: "", toolsUsed, error: error || "no response" };

    if (message.tool_calls?.length) {
      // Keep the assistant turn (with its tool_calls) then answer each call.
      messages.push({ role: "assistant", content: message.content ?? "", tool_calls: message.tool_calls });
      for (const tc of message.tool_calls) {
        let args: Record<string, unknown> = {};
        try {
          args = JSON.parse(tc.function.arguments || "{}");
        } catch {
          /* leave empty */
        }
        toolsUsed.push(tc.function.name);
        const result = await execTool(tc.function.name, args);
        messages.push({
          role: "tool",
          tool_call_id: tc.id,
          content: JSON.stringify(result).slice(0, 6000),
        });
      }
      continue; // let the model read the tool results
    }

    return { answer: (message.content || "").trim(), toolsUsed };
  }
  return { answer: "", toolsUsed, error: "hit tool-call limit without an answer" };
}
