"use client";
import { Suspense, useEffect, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Cubes, Redirecting } from "@/components/ui";

export default function Login() {
  return (
    <Suspense>
      <LoginForm />
    </Suspense>
  );
}

function LoginForm() {
  const [adminId, setAdminId] = useState("");
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  // "otp" once the password is accepted AND a WhatsApp code has gone out. When
  // the second factor isn't configured the server signs us straight in and this
  // never leaves "password".
  const [step, setStep] = useState<"password" | "otp">("password");
  const [hint, setHint] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  // Held from the moment the server says yes until the new route paints. Without
  // it the form just sits there looking like nothing happened, which is exactly
  // when someone presses the button a second time.
  const [redirecting, setRedirecting] = useState(false);
  const router = useRouter();
  const next = useSearchParams().get("next") || "/";

  const post = (payload: Record<string, unknown>) =>
    fetch("/api/auth", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      const r = await post(
        step === "password" ? { adminId, phone } : { otp: code },
      );
      const j = await r.json().catch(() => ({}));

      if (r.ok && j.step === "otp") {
        setStep("otp");
        setHint(j.hint || "");
        setCode("");
        return;
      }
      if (r.ok) {
        setRedirecting(true);
        return router.replace(next);
      }

      setErr(
        j.error ||
          (step === "password" ? "Wrong Admin ID." : "Wrong code."),
      );
      if (step === "otp") setCode("");
    } catch {
      setErr("No connection. Try again.");
    } finally {
      setBusy(false);
    }
  }

  // Auto-submit on the fourth digit, the way the app's verify screen does —
  // typing the last one and then hunting for a button is a step nobody wants.
  const submitRef = useRef(submit);
  submitRef.current = submit;
  useEffect(() => {
    if (step === "otp" && code.length === 4 && !busy && !redirecting) {
      submitRef.current(new Event("submit") as unknown as React.FormEvent);
    }
  }, [code, step, busy, redirecting]);

  async function resend() {
    setBusy(true);
    setErr("");
    try {
      const r = await post({ resend: true });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) setErr(j.error || "Could not send another code.");
      else setCode("");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen grid place-items-center px-6">
      {redirecting ? (
        <div className="card w-full max-w-sm p-7">
          <Redirecting />
        </div>
      ) : (
        <form
        onSubmit={submit}
        className="card w-full max-w-sm p-7 flex flex-col gap-4"
      >
        <div className="flex items-center gap-3">
          {/* Same placeholder as the sidebar had. The login screen is the first
              thing anyone sees, so it is the last place to leave a stand-in. */}
          <img src="/logo.png" alt="DOP Collect" width={80} height={80}
               className="w-20 h-20 object-contain" />
          <div>
            <div className="font-semibold text-lg leading-none">
              DOP Collect
            </div>
            <div className="text-muted text-xs mt-1">Admin dashboard</div>
          </div>
        </div>
        <input
          className="input"
          type="password"
          autoFocus={step === "password"}
          disabled={step === "otp"}
          placeholder="Admin ID"
          value={adminId}
          onChange={(e) => setAdminId(e.target.value)}
        />
        <input
          className="input font-mono"
          type="tel"
          inputMode="numeric"
          autoComplete="tel"
          maxLength={10}
          disabled={step === "otp"}
          placeholder="Registered mobile"
          value={phone}
          onChange={(e) => setPhone(e.target.value.replace(/\D/g, ""))}
        />

        {step === "otp" && (
          <>
            <p className="text-muted text-xs">
              Code sent on WhatsApp to {hint || "your number"}.
            </p>
            {/* Four boxes, but ONE real input laid over them.
                Four separate inputs mean focus juggling on every keystroke and
                they break paste and WhatsApp autofill — the browser fills the
                first box with all four digits and gives up. A single input keeps
                autocomplete="one-time-code" working; the boxes are just paint. */}
            <div className="relative">
              <div className="flex gap-2 justify-center">
                {[0, 1, 2, 3].map((i) => (
                  <div
                    key={i}
                    className={`w-12 h-14 rounded-[4px] border grid place-items-center
                      font-mono text-xl transition-colors
                      ${code.length === i ? "border-ink" : "border-line"}`}
                  >
                    {code[i] ?? ""}
                  </div>
                ))}
              </div>
              <input
                className="absolute inset-0 w-full h-full opacity-0"
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={4}
                autoFocus
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 4))}
              />
            </div>
          </>
        )}

        {err && <div className="text-red text-sm font-semibold">{err}</div>}

        {/* Step 1 sends a code, it does not sign you in — the button says so.
            Promising "Sign in" and then asking for a code reads as a failure. */}
        <button
          className="btn"
          disabled={
            busy ||
            (step === "password" ? !adminId || phone.length !== 10 : code.length < 4)
          }
        >
          {busy ? (
            <span className="inline-flex items-center gap-2.5">
              <Cubes className="!w-4 !h-4 !gap-[2px]" />
              {step === "otp" ? "Checking" : "Sending"}
            </span>
          ) : step === "otp" ? (
            "Login"
          ) : (
            "Send OTP"
          )}
        </button>

        {step === "otp" && (
          <button
            type="button"
            onClick={resend}
            disabled={busy}
            className="text-muted text-xs font-semibold"
          >
            Send another code
          </button>
        )}
      </form>
      )}
    </div>
  );
}
