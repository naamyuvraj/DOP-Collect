import { NextResponse } from "next/server";
import { isAuthed, adminIdSource } from "@/lib/auth";
import { adminOtpStatus } from "@/lib/adminOtp";

export const dynamic = "force-dynamic";

/**
 * The Supabase edge functions this project runs, whether each is answering, and
 * the exact command to redeploy one.
 *
 * The list is hand-written rather than read from the Management API: it changes
 * about twice a year, and reading it live would mean a personal access token in
 * the environment — a credential that outranks everything else this dashboard
 * holds — for a five-row table. Reachability IS live.
 */
type Fn = { slug: string; purpose: string; secrets: string[] };

const FUNCTIONS: Fn[] = [
  {
    slug: "otp",
    purpose: "WhatsApp OTP, the phone↔agent binding, and device sessions.",
    secrets: [
      "MSG91_AUTHKEY",
      "MSG91_WA_INTEGRATED_NUMBER",
      "MSG91_WA_TEMPLATE_NAME",
      "MSG91_WA_TEMPLATE_LANG",
    ],
  },
  {
    slug: "ingest",
    purpose: "The only writer for telemetry. Rate-limits, then writes as service role.",
    secrets: [],
  },
  {
    slug: "pay",
    purpose: "Subscription entitlement and the free trial.",
    secrets: ["RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET"],
  },
  {
    slug: "groq",
    purpose: "Assistant proxy. Keeps the Groq keys off the phone and rotates them.",
    secrets: [],
  },
  {
    slug: "razorpay-webhook",
    purpose: "Payment confirmations. Server-to-server, so 405 is its healthy answer.",
    secrets: ["RAZORPAY_WEBHOOK_SECRET"],
  },
];

/**
 * Project ref out of SUPABASE_URL, so it is configured in exactly one place.
 * https://ojorpmtptryldizogtkz.supabase.co -> ojorpmtptryldizogtkz
 */
function projectRef(url: string): string | null {
  return new URL(url).hostname.split(".")[0] || null;
}

/**
 * Is it deployed and answering?
 *
 * OPTIONS, because every function short-circuits it before touching the
 * database, the rate limiter or any secret — so this costs nothing and changes
 * nothing. ANY status means the function is running; only a transport failure
 * or timeout means it is not. razorpay-webhook answers 405 by design.
 */
async function probe(slug: string, base: string) {
  const started = Date.now();
  try {
    const res = await fetch(`${base}/functions/v1/${slug}`, {
      method: "OPTIONS",
      cache: "no-store",
      signal: AbortSignal.timeout(6000),
    });
    return { reachable: true, status: res.status, ms: Date.now() - started };
  } catch {
    return { reachable: false, status: null, ms: Date.now() - started };
  }
}

export async function GET() {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const base = process.env.SUPABASE_URL;
  const ref = base ? projectRef(base) : null;
  // `--use-api` is not optional: without it the bundler waits on Docker and hangs.
  const deploy = (slug: string) =>
    ref
      ? `supabase functions deploy ${slug} --project-ref ${ref} --use-api`
      : `supabase functions deploy ${slug} --use-api`;

  if (!base) {
    // Still hand back the manifest — knowing what SHOULD be deployed is useful
    // even when this dashboard cannot reach the project.
    return NextResponse.json({
      rows: FUNCTIONS.map((f) => ({ ...f, deploy: deploy(f.slug), probe: null })),
      auth: { ...adminOtpStatus(), adminIdSource: adminIdSource() },
    });
  }

  const rows = await Promise.all(
    FUNCTIONS.map(async (f) => ({
      ...f,
      deploy: deploy(f.slug),
      probe: await probe(f.slug, base),
    })),
  );
  // Redeploy everything, in one paste. The function name is OPTIONAL and
  // omitting it deploys them all — `supabase functions deploy --help` on the
  // installed CLI (2.20.12) documents exactly one `[Function name]`, so naming
  // all five would be relying on undocumented behaviour.
  const deployAll = `supabase functions deploy${ref ? ` --project-ref ${ref}` : ""} --use-api`;
  // Names and booleans only — never a value. Behind the admin gate like
  // everything else here.
  return NextResponse.json({
    rows,
    deployAll,
    auth: { ...adminOtpStatus(), adminIdSource: adminIdSource() },
  });
}
