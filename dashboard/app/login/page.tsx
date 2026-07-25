"use client";
import { Suspense, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

export default function Login() {
  return (
    <Suspense>
      <LoginForm />
    </Suspense>
  );
}

function LoginForm() {
  const [pw, setPw] = useState("");
  const [err, setErr] = useState(false);
  const [busy, setBusy] = useState(false);
  const router = useRouter();
  const next = useSearchParams().get("next") || "/";

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(false);
    const r = await fetch("/api/auth", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password: pw }),
    });
    setBusy(false);
    if (r.ok) router.replace(next);
    else setErr(true);
  }

  return (
    <div className="min-h-screen grid place-items-center px-6">
      <form
        onSubmit={submit}
        className="card w-full max-w-sm p-7 flex flex-col gap-4"
      >
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-2xl bg-ink text-white grid place-items-center font-extrabold text-lg">
            ₹
          </div>
          <div>
            <div className="font-extrabold text-lg leading-none">
              DOP Collect
            </div>
            <div className="text-muted text-xs mt-1">Admin dashboard</div>
          </div>
        </div>
        <input
          className="input"
          type="password"
          autoFocus
          placeholder="Password"
          value={pw}
          onChange={(e) => setPw(e.target.value)}
        />
        {err && (
          <div className="text-red text-sm font-semibold">
            Wrong password.
          </div>
        )}
        <button className="btn" disabled={busy}>
          {busy ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </div>
  );
}
