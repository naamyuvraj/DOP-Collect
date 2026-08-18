-- Assistant model list (app_config.groq_models)
-- ---------------------------------------------------------------------------
-- The Groq models the assistant may use, in fallback order. Read live by BOTH
-- the dashboard agent (dashboard/lib/groq.ts) and the `groq` edge function, and
-- editable on the dashboard's API Keys page.
--
-- Why this is a row and not a constant: Groq decommissioned
-- llama-3.3-70b-versatile on 16 Aug 2026. The id began returning a hard 404 and
-- the assistant stopped answering, and fixing it meant editing four files,
-- redeploying the edge function and shipping an app update. Now it is one edit.
--
-- Safe to re-run. Both readers fall back to the same pair in code if this row is
-- missing, so seeding is a convenience, not a requirement.
--
-- Order is the fallback chain: strongest first, fastest second. Both are
-- reasoning models — they spend part of the token budget thinking, so callers
-- must not drop max_tokens below ~256 or the reply comes back empty.

insert into public.app_config (key, value) values
  ('groq_models', '["openai/gpt-oss-120b","openai/gpt-oss-20b"]'::jsonb)
on conflict (key) do nothing;

-- To change the list later, prefer the dashboard. By hand:
--   update public.app_config
--      set value = '["<primary>","<fallback>"]'::jsonb, updated_at = now()
--    where key = 'groq_models';
