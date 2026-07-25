import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { runAgent } from "@/lib/agent";
import { groqConfigured } from "@/lib/groq";
import { logExchange, recallContext, synapConfigured } from "@/lib/synap";

export const dynamic = "force-dynamic";

// POST { question } -> { answer, toolsUsed, memoryUsed }
// Flow: recall long-term memory (Synap) -> run the tool-calling agent (Groq)
// -> log the exchange back to Synap so it's remembered next time.
export async function POST(req: NextRequest) {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const { question } = await req.json().catch(() => ({ question: "" }));
  const q = typeof question === "string" ? question.trim() : "";
  if (!q) return NextResponse.json({ error: "empty question" }, { status: 400 });
  if (q.length > 1000) return NextResponse.json({ error: "question too long" }, { status: 400 });

  if (!(await groqConfigured())) {
    return NextResponse.json({
      answer:
        "No Groq API key is configured yet. Add one on the API Keys page (or set GROQ_KEYS in the dashboard env) to enable the assistant.",
      toolsUsed: [],
      memoryUsed: false,
    });
  }

  // 1. Recall anything Synap already knows for this admin.
  const memory = await recallContext(q).catch(() => "");

  // 2. Answer with the analytics tool-calling agent.
  const { answer, toolsUsed, error } = await runAgent(q, memory);
  if (error && !answer) {
    return NextResponse.json({ error: `assistant failed: ${error}` }, { status: 502 });
  }

  // 3. Remember this exchange (best-effort, non-blocking).
  if (answer) logExchange(q, answer);

  return NextResponse.json({
    answer,
    toolsUsed,
    memoryUsed: synapConfigured() && !!memory,
  });
}
