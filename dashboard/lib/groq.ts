// Server-side Groq chat, with the same key store the app uses.
// ---------------------------------------------------------------------------
// Keys come from the managed `app_keys` table (provider=groq, enabled) — the
// exact set the Supabase edge function and the API-Keys page manage — so the
// dashboard agent needs no new secret. We rotate across keys and fall back
// across models on rate-limit/auth/5xx, and log each attempt to `key_usage`
// so it shows up on the Keys page. Env fallback (GROQ_KEYS / GROQ_KEY_1..4)
// covers local dev before any key is added to the DB.
// ---------------------------------------------------------------------------
import { admin, dbConfigured } from "./supabase";

const API = "https://api.groq.com/openai/v1/chat/completions";
export const MODELS = ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"];

export type ChatMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
};
export type ToolCall = {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
};
export type ToolSpec = {
  type: "function";
  function: { name: string; description: string; parameters: Record<string, unknown> };
};

async function loadKeys(): Promise<string[]> {
  if (dbConfigured()) {
    const { data } = await admin()
      .from("app_keys")
      .select("key")
      .eq("provider", "groq")
      .eq("enabled", true)
      .order("id");
    const keys = (data || []).map((r: { key: string }) => r.key).filter(Boolean);
    if (keys.length) return keys;
  }
  // Dev fallback: GROQ_KEYS="a,b,c" or GROQ_KEY_1..GROQ_KEY_4.
  const csv = (process.env.GROQ_KEYS || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (csv.length) return csv;
  return [1, 2, 3, 4]
    .map((i) => process.env[`GROQ_KEY_${i}`])
    .filter((k): k is string => !!k);
}

function logUsage(keyIndex: number, model: string, ok: boolean) {
  if (!dbConfigured()) return;
  admin().from("key_usage").insert({ key_index: keyIndex, model, ok }).then(() => {});
}

export const groqConfigured = async () => (await loadKeys()).length > 0;

export type GroqResult = { message?: ChatMessage; error?: string };

/** One chat-completions round trip, rotating keys/models on failure. */
export async function groqChat(
  messages: ChatMessage[],
  opts: {
    tools?: ToolSpec[];
    toolChoice?: "auto" | "none";
    temperature?: number;
    maxTokens?: number;
    timeoutMs?: number;
  } = {}
): Promise<GroqResult> {
  const keys = await loadKeys();
  if (!keys.length) return { error: "no active Groq keys" };
  const errors: string[] = [];

  for (const model of MODELS) {
    for (let i = 0; i < keys.length; i++) {
      let resp: Response;
      // Hard per-call timeout so one slow/hung key can't run us into a platform
      // request timeout (which would return HTML and read as a "network error").
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 20000);
      try {
        resp = await fetch(API, {
          method: "POST",
          signal: ctrl.signal,
          headers: {
            Authorization: `Bearer ${keys[i]}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            model,
            temperature: opts.temperature ?? 0,
            max_tokens: opts.maxTokens ?? 900,
            messages,
            ...(opts.tools ? { tools: opts.tools, tool_choice: opts.toolChoice ?? "auto" } : {}),
          }),
        });
      } catch (e) {
        errors.push(`key#${i} ${ctrl.signal.aborted ? "timeout" : "network"}: ${e}`);
        continue;
      } finally {
        clearTimeout(timer);
      }
      logUsage(i, model, resp.ok);

      if (resp.ok) {
        let body: any;
        try {
          body = await resp.json();
        } catch (e) {
          errors.push(`key#${i}/${model} bad JSON: ${e}`);
          continue; // treat a malformed 200 like a soft failure -> rotate
        }
        return { message: body?.choices?.[0]?.message as ChatMessage };
      }
      if ([429, 401, 403].includes(resp.status) || resp.status >= 500) {
        errors.push(`key#${i}/${model} -> ${resp.status}`);
        continue; // rotate key
      }
      errors.push(`key#${i}/${model} -> ${resp.status}`);
      break; // request-level problem -> next model
    }
  }
  return { error: `all keys/models failed: ${errors.join("; ")}` };
}
