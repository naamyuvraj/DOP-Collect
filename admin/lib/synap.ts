// Maximem Synap — hosted agent memory, reached over its MCP HTTP endpoint.
// ---------------------------------------------------------------------------
// Synap keeps long-term memory about the admin using this dashboard: what they
// asked before, numbers they care about, preferences. We `recall` before the
// agent answers and `log` the exchange after, so the assistant carries context
// across sessions. This is a tiny JSON-RPC client — no MCP SDK needed. The
// server speaks Server-Sent-Events (`event: message\ndata: {json}`), which we
// parse out below. All calls are best-effort: memory must never break a reply.
// ---------------------------------------------------------------------------

const URL_ = () => process.env.SYNAP_MCP_URL || "https://synap-mcp.maximem.ai/mcp";
const TOKEN = () => process.env.SYNAP_TOKEN || "";

export const synapConfigured = () => !!TOKEN();

// A single, stable identity for the admin who runs this dashboard, so their
// memory stays scoped to them (Synap separates memory per user_id).
export const SYNAP_USER = process.env.SYNAP_USER_ID || "dop-admin";

type RpcResult = { content?: { type: string; text?: string }[]; isError?: boolean };

async function call(name: string, args: Record<string, unknown>, timeoutMs = 8000): Promise<string> {
  if (!synapConfigured()) return "";
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(URL_(), {
      method: "POST",
      signal: ctrl.signal,
      headers: {
        Authorization: `Bearer ${TOKEN()}`,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name, arguments: args },
      }),
    });
    const raw = await res.text();
    return extractText(raw);
  } catch (e) {
    console.error("synap", name, String(e));
    return "";
  } finally {
    clearTimeout(t);
  }
}

// The body may be an SSE stream (one or more `data: {json}` lines) or plain
// JSON. Pull the last JSON-RPC frame and return its concatenated text content.
function extractText(raw: string): string {
  const frames: string[] = [];
  for (const line of raw.split("\n")) {
    const s = line.startsWith("data:") ? line.slice(5).trim() : line.trim();
    if (s.startsWith("{")) frames.push(s);
  }
  const last = frames[frames.length - 1] ?? raw.trim();
  try {
    const parsed = JSON.parse(last);
    const result: RpcResult | undefined = parsed?.result;
    if (result?.content) {
      return result.content.map((c) => c.text || "").join("\n").trim();
    }
    if (parsed?.error) return "";
  } catch {
    /* ignore */
  }
  return "";
}

/** Recall anything Synap already knows that's relevant to `query`. */
export async function recallContext(query: string, maxResults = 6): Promise<string> {
  const text = await call("recall_context", {
    query,
    user_id: SYNAP_USER,
    max_results: maxResults,
  });
  if (!text || /nothing remembered/i.test(text)) return "";
  return text;
}

/** Log the just-completed exchange so Synap can remember what matters. */
export async function logExchange(userMessage: string, assistantMessage: string): Promise<void> {
  // Fire-and-forget: never make the user wait on the write.
  void call("log_exchange", {
    user_message: userMessage,
    assistant_message: assistantMessage,
    user_id: SYNAP_USER,
  });
}
