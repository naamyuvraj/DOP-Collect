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
/**
 * Fallback order, used only when `app_config.groq_models` is unset.
 *
 * The list lives in app_config so a decommission is a dashboard edit rather
 * than a redeploy — which is the lesson from llama-3.3-70b-versatile, whose
 * retirement returned a hard 404 and took the assistant down with it. Manage it
 * on the API Keys page.
 *
 * Strongest first, fast one as the fallback. Both are reasoning models: they
 * spend part of the token budget thinking, so a small max_tokens comes back
 * with empty content rather than an error.
 */
export const DEFAULT_MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];

export const MODELS_CONFIG_KEY = "groq_models";

let modelCache: { at: number; models: string[] } | null = null;

/** Configured preference order, cached briefly so a chat turn isn't N queries. */
export async function loadModels(): Promise<string[]> {
  if (modelCache && Date.now() - modelCache.at < 30_000) return modelCache.models;
  let models = DEFAULT_MODELS;
  if (dbConfigured()) {
    const { data } = await admin()
      .from("app_config")
      .select("value")
      .eq("key", MODELS_CONFIG_KEY)
      .maybeSingle();
    const v = data?.value;
    const list = Array.isArray(v) ? v : Array.isArray(v?.models) ? v.models : null;
    const clean = (list || []).map((m: unknown) => String(m).trim()).filter(Boolean);
    if (clean.length) models = clean;
  }
  modelCache = { at: Date.now(), models };
  return models;
}

/** Drop the cache after a write, so a saved change takes effect immediately. */
export const clearModelCache = () => { modelCache = null; };

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

  for (const model of await loadModels()) {
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
