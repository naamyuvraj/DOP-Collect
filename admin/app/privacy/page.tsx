// Public privacy policy — served at /privacy (allowlisted in middleware.ts).
// Keep in sync with docs/privacy.html. Linked from the Play Store listing.
export const metadata = {
  title: "DOP Collect — Privacy Policy",
};

const wrap: React.CSSProperties = {
  maxWidth: 760,
  margin: "0 auto",
  padding: "32px 20px 64px",
  font: '16px/1.6 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif',
  color: "#111",
  background: "#fff",
};

export default function Privacy() {
  return (
    <main style={wrap}>
      <h1 style={{ fontSize: "1.7rem", marginBottom: ".2em" }}>
        DOP Collect — Privacy Policy
      </h1>
      <p style={{ opacity: 0.7, fontSize: ".92rem" }}>Last updated: 11 August 2026</p>

      <p>
        DOP Collect (“the app”) is a productivity tool for India Post MPKBY
        Recurring Deposit collection agents. It helps an agent organise their own
        collection lists, generate reports, and log in to the official India Post
        agent portal. This policy explains what the app stores, what it sends, and
        to whom.
      </p>

      <h2>1. Data that stays on your device</h2>
      <p>
        The following is stored <b>only on your phone</b> and is never sent to us:
      </p>
      <ul>
        <li>
          Your customers’ names, account numbers, deposit amounts and dues — held
          in a local database that is <b>encrypted at rest (SQLCipher, AES-256)</b>.
        </li>
        <li>
          Your India Post agent portal login (Agent ID and password) — stored in
          the Android <b>Keystore</b>, used only to sign in to the official portal
          inside the app.
        </li>
      </ul>
      <p>
        We cannot see this data. It leaves your device only when <i>you</i> submit
        it to the official India Post portal or share a report you generate.
      </p>

      <h2>2. Data we collect</h2>
      <p>To run your account, secure it, and improve the app, we collect:</p>
      <ul>
        <li>
          <b>Account &amp; identity:</b> your name, India Post Agent ID, and (if
          phone verification is enabled) your mobile number.
        </li>
        <li>
          <b>Device &amp; usage:</b> a random device identifier, app version, your
          post-office region/SOL code, and anonymous usage events (e.g. “sync
          completed”) — never the contents of your customer data.
        </li>
        <li>
          <b>Payments:</b> if you subscribe, your plan and payment reference.
          Card/UPI details are handled entirely by our payment processor; we never
          see or store them.
        </li>
      </ul>
      <p>
        We do <b>not</b> collect your customers’ personal data on our servers.
      </p>

      <h2>3. How we use it</h2>
      <ul>
        <li>To provide the app and your subscription entitlement.</li>
        <li>
          To verify your phone number and limit each account to a small number of
          devices (security).
        </li>
        <li>To understand aggregate usage and fix problems.</li>
      </ul>
      <p>We do not sell your data or use it for advertising.</p>

      <h2>4. Service providers</h2>
      <p>
        We use trusted providers to run the service. They process data only to
        provide their function:
      </p>
      <ul>
        <li>
          <b>Supabase</b> — secure backend (database and functions).
        </li>
        <li>
          <b>Razorpay</b> — payment processing (handles all card/UPI data).
        </li>
        <li>
          <b>MSG91 / WhatsApp</b> — delivering your one-time verification code.
        </li>
        <li>
          <b>Groq</b> — powering the optional in-app assistant. In “offline only”
          mode, nothing you type leaves your phone.
        </li>
      </ul>

      <h2>5. Security</h2>
      <p>
        Local data is encrypted at rest; all network traffic uses HTTPS.
        Verification codes and session tokens are stored as hashes or in the
        Keystore. Screenshots of sensitive screens are blocked.
      </p>

      <h2>6. Data retention &amp; your rights</h2>
      <p>
        We keep account and usage data while your account is active. You can request
        a copy or deletion of the data associated with your Agent ID at any time by
        contacting us (below); we will action it within 30 days. Uninstalling the app
        removes all on-device data.
      </p>

      <h2>7. Children</h2>
      <p>
        The app is intended for use by adult India Post agents and is not directed at
        children.
      </p>

      <h2>8. Changes</h2>
      <p>
        We may update this policy; the “last updated” date will change. Continued use
        after an update means you accept the revised policy.
      </p>

      <h2>9. Contact</h2>
      <p>
        For any privacy request or question, contact:
        <br />
        <b>Email:</b>{" "}
        <a href="mailto:support.dop.collect@gmail.com">
          support.dop.collect@gmail.com
        </a>
      </p>
    </main>
  );
}
