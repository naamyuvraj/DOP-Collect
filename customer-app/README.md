# Customer app — not started

Placeholder. Nothing here yet.

The agent app (`app/`) is for the MPKBY collection agent: it drives the DOP
portal, holds the book, and records cash taken at the door. This directory is
for the app the agent's **customers** would use — seeing their own RD account,
what is due, and what they have paid.

Before any of it is written, two things in the existing system have to be
settled, because a customer app depends on both:

1. **The privacy policy is currently false.** `app/lib/screens/privacy_screen.dart`
   still promises the book never leaves the phone, which stopped being true when
   Supabase sync shipped. A customer-facing product cannot be built on top of a
   promise the agent app is already breaking. See `docs/audits/SECURITY_AUDIT.md`.

2. **A customer has no identity in the system yet.** `book_accounts` is scoped by
   `account_id` — the AGENT's Supabase account. There is no per-customer row, no
   auth, and no way for a customer to prove which RD account is theirs. That is a
   schema and auth design job, not a UI job. See `backend/schema/schema_book.sql`.
