// DOP Agent ID parser.
// ---------------------------------------------------------------------------
// A DOP (India Post) agent id from Finacle (menu HDSAMM) is:
//     MI  +  <SOL ID>  +  <5-digit sequence>
// e.g. MI + 8472350100 + 00005  ->  MI847235010000005
// - Prefix "MI" is mandatory.
// - SOL ID = the attached post office's Service Outlet ID (the branch / region).
// - Last 5 chars are the sequential suffix.
// - Spaces and dots are INVALID inside the id.
// Our subscriptions sometimes store it namespaced as "DOP.MI…"; we strip that.
// The SOL ID is what we group by to see which branches/regions use the app.

export type ParsedAgent = {
  valid: boolean;
  raw: string;
  normalized: string; // the cleaned MI… core we parsed
  solId: string; // branch / region key ("" if invalid)
  seq: string; // 5-digit sequence ("" if invalid)
  reason?: string;
};

export function parseAgentId(input: string | null | undefined): ParsedAgent {
  const raw = (input ?? "").toString();
  // Uppercase, drop surrounding whitespace, and peel an optional "DOP." / "DOP"
  // namespace that our own records add in front of the official id.
  let core = raw.trim().toUpperCase().replace(/^DOP[\s.]*/, "");

  const base = { raw, normalized: core, solId: "", seq: "" };

  if (!core.startsWith("MI"))
    return { ...base, valid: false, reason: "must start with MI" };
  if (/[\s.]/.test(core))
    return { ...base, valid: false, reason: "spaces and dots are not allowed" };
  if (!/^MI[A-Z0-9]+$/.test(core))
    return { ...base, valid: false, reason: "must be alphanumeric" };

  const body = core.slice(2); // after "MI": SOL ID + 5-digit sequence
  if (body.length < 6)
    return { ...base, valid: false, reason: "too short (need SOL ID + 5 digits)" };

  const seq = body.slice(-5);
  const solId = body.slice(0, -5);
  if (!/^\d{5}$/.test(seq))
    return { ...base, valid: false, reason: "last 5 chars must be digits" };
  if (!solId)
    return { ...base, valid: false, reason: "missing SOL ID" };

  return { valid: true, raw, normalized: core, solId, seq };
}

/** Just the SOL ID (branch/region key), or "" if the id can't be parsed. */
export const solOf = (agentId: string | null | undefined): string =>
  parseAgentId(agentId).solId;
