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
  // One outer try/catch so this endpoint ALWAYS returns JSON. If it ever threw,
  // Next would return an HTML error page and the client's res.json() would blow
  // up as a misleading "network error" — which is exactly the bug we're fixing.
  try {
    if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

    const { question } = await req.json().catch(() => ({ question: "" }));
    const q = typeof question === "string" ? question.trim() : "";
    if (!q) return NextResponse.json({ error: "Please type a question." }, { status: 400 });
    if (q.length > 1000)
      return NextResponse.json({ error: "That question is too long." }, { status: 400 });

    if (!(await groqConfigured().catch(() => false))) {
      return NextResponse.json({
        answer:
          "No Groq API key is configured yet. Add one on the API Keys page (or set GROQ_KEYS in the dashboard env) to enable the assistant.",
        toolsUsed: [],
        memoryUsed: false,
      });
    }

    // 1. Recall anything Synap already knows for this admin (best-effort).
    const memory = await recallContext(q).catch(() => "");

    // 2. Answer with the analytics tool-calling agent (never throws).
    const { answer, toolsUsed, error } = await runAgent(q, memory);
    if (!answer) {
      return NextResponse.json(
        { error: `The assistant couldn't answer that. ${error ? `(${error})` : ""}`.trim() },
        { status: 200 } // 200 so the client shows the message, not a generic failure
      );
    }

    // 3. Remember this exchange (best-effort, non-blocking).
    logExchange(q, answer);

    return NextResponse.json({
      answer,
      toolsUsed,
      memoryUsed: synapConfigured() && !!memory,
    });
  } catch (e) {
    return NextResponse.json(
      { error: `Assistant error: ${e instanceof Error ? e.message : String(e)}` },
      { status: 200 }
    );
  }
}
