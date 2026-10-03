/**
 * One definition of "is this agent paying", because there were four.
 *
 * Overview said 1, Payments said 2, Plans said 0 and Regions said 2, for the
 * same two agents — and the truth was 0 paying, 2 on a free trial. Each tab had
 * grown its own rule:
 *
 *   Overview  status !== 'expired' && plan_code !== 'trial'
 *   Payments  status === 'active'                       (no trial rule at all)
 *   Plans     status !== 'expired' && plan_code !== 'trial'
 *   Regions   every subscriptions row
 *
 * Two assumptions behind those were simply wrong about the data:
 *
 * 1. "A trial row has status 'trial'." It does not — a live trial is stored
 *    `status: 'active'`, so Payments counted trials as paid subs and then
 *    reported "0 trial rows" beside them.
 * 2. "Not 'trial' means paid." A manual grant from the Fix-access buttons
 *    writes `plan_code: null` (see app/api/subscriptions/route.ts), and
 *    null !== 'trial', so a ₹0 goodwill grant read as a customer.
 *
 * So neither `status` nor the literal string 'trial' can answer it. The price
 * can: an agent is paying when their plan is one that costs money. That also
 * means a new free tier, or another null-plan row, is classified right without
 * anyone remembering to update a list of magic codes.
 */

export type PlanLike = { code: string; name?: string | null; price_inr: number };
export type SubLike = { plan_code?: string | null; status?: string | null };

/** The free tier every new agent starts on. */
export const TRIAL_CODE = "trial";

/**
 * A subscription row with no `plan_code` is a free grant, not an unknown — the
 * Fix-access buttons write exactly that. Reading it literally showed an agent
 * holding 60 days of access as plan "—", i.e. the one agent who looked like they
 * had no trial was on one. Resolve it to the free tier so every agent with
 * access says what they have.
 */
export function planCodeOf(s: SubLike): string {
  return s.plan_code ?? TRIAL_CODE;
}

/** Display name for a subscription's plan, falling back to the free tier. */
export function planLabel(
  s: SubLike & { plan_name?: string | null },
  plans: PlanLike[] = []
): string {
  if (s.plan_name) return s.plan_name;
  const code = planCodeOf(s);
  return plans.find((p) => p.code === code)?.name || code;
}

/** Codes of plans that actually charge. Everything else grants access for free. */
export function paidPlanCodes(plans: PlanLike[]): Set<string> {
  return new Set(
    plans.filter((p) => Number(p.price_inr) > 0).map((p) => p.code)
  );
}

/** Access of any kind — paid or free — as long as the period hasn't lapsed. */
export function hasAccess(s: SubLike): boolean {
  return !!s.status && s.status !== "expired";
}

/** Access that someone paid for. A plan-less row resolves to the free tier. */
export function isPaying(s: SubLike, paid: Set<string>): boolean {
  return hasAccess(s) && paid.has(planCodeOf(s));
}

/** Has access, but nobody paid for it: free trial, or a manual grant. */
export function isFreeAccess(s: SubLike, paid: Set<string>): boolean {
  return hasAccess(s) && !isPaying(s, paid);
}
