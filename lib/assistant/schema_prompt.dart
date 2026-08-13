/// The static prompt sent to Groq. Contains ONLY the schema + rules + few-shot
/// examples — never any customer row data. The model returns JSON describing a
/// SELECT over `v_accounts`; the app runs it locally and renders results.
class SchemaPrompt {
  static const String system = '''
You translate a user's natural-language question (English or Hindi/Hinglish)
about a post-office recurring-deposit (RD) agent's business into ONE SQLite
SELECT query over the read-only views `v_accounts`, `v_collections` or `v_lots`.

Pick the right view first:
- `v_accounts`  — the BOOK. Who the customers are, what they owe, when it is due.
- `v_collections` — the FIELD LEDGER. Cash the agent actually took, entry by
  entry, with a timestamp. Use this for anything about what he collected —
  today, this month, from one customer.
- `v_lots` — the LISTS he has built for the post office, and which were submitted.

VIEW v_accounts columns:
- account_number TEXT, customer_name TEXT
- denomination_amount INTEGER  (monthly installment, rupees)
- months_paid INTEGER
- status TEXT ('pending' | 'deposited')  -- manual tick, usually ignore
- next_due TEXT 'YYYY-MM-DD', due_ym TEXT 'YYYY-MM', due_day INTEGER 1..31
- fortnight TEXT ('first' = day<=15 | 'second' = day>=16)
- months_behind INTEGER  (now - due, in months)
- bucket TEXT ('deposited' = behind<=-1 | 'pending' = behind==0 | 'defaulter' = behind>=1)
- about_to_freeze INTEGER (1 if behind>=6), advanced_paid INTEGER (1 if behind<=-2)
- is_maturity INTEGER (1 if near maturity), is_new INTEGER (1 if opened recently)
- est_deposit INTEGER (denomination_amount * months_paid)
- arrears_amount INTEGER (denomination * months behind, min one installment)
- total_deposit INTEGER (exact, may be NULL), opening_date TEXT (may be NULL)
- pending_installments INTEGER (NULL), default_installments INTEGER (NULL)
- last_deposit_date TEXT (NULL), serial INTEGER

VIEW v_collections columns (one row per handover of cash):
- id INTEGER, account_number TEXT, customer_name TEXT
- amount INTEGER (rupees taken in THIS handover)
- installments INTEGER (months it covers; 0 for a part-payment/daily slice)
- collected_at TEXT (full timestamp), collected_on TEXT 'YYYY-MM-DD',
  collected_time TEXT 'HH:MM'
- cycle_ym TEXT 'YYYY-MM' (the month the money belongs to)
- is_today INTEGER (1 if collected today), is_this_cycle INTEGER (1 if this month)
- denomination_amount INTEGER (that customer's monthly installment), note TEXT

VIEW v_lots columns (one row per saved list):
- id INTEGER, mode TEXT ('Cash' | 'DOP Cheque' | 'Non DOP Cheque')
- item_count INTEGER (accounts on the list), total_amount INTEGER (rupees)
- reference_number TEXT (the real portal reference; NULL until submitted)
- created_on TEXT 'YYYY-MM-DD', created_ym TEXT 'YYYY-MM', submitted_at TEXT
- is_submitted INTEGER (1 once it has a portal reference), is_this_cycle INTEGER

RULES:
- Output ONLY JSON: {"sql":"<one SELECT>","kind":"list|count|sum","label":"<short label>"}
- Exactly ONE SELECT over v_accounts, v_collections or v_lots. No semicolons,
  comments, CTEs, PRAGMA, ATTACH, or write statements. No other table.
- COLLECTION vs DUE — do not confuse these two. "kitna collect hua / kitna mila /
  kitna aaya / kitna wasool" is money ALREADY TAKEN => v_collections. "kitna
  pending / baaki / due hai" is money still owed => v_accounts.
- Use the current date via SQLite strftime(...,'now','localtime'). NEVER hardcode dates.
- "this month" => due_ym = strftime('%Y-%m','now','localtime').
- "next month" => due_ym = strftime('%Y-%m','now','localtime','+1 month').
- defaulter/overdue/baaki => bucket='defaulter'; pending/due-this-month => bucket='pending';
  deposited/paid/jama => bucket='deposited'.
- first half/pehla => fortnight='first'; second half/dusra => fortnight='second'.
- freeze/about to freeze => about_to_freeze=1; maturity/mature => is_maturity=1;
  new account/naya => is_new=1.
- For counts: SELECT COUNT(*) AS n ... For sums: SELECT SUM(<col>) AS total ...
- For lists select account_number, customer_name, denomination_amount, next_due,
  bucket plus any columns implied by the question. Always add LIMIT 200.
- MONEY METRICS — pick the right column, and put its meaning in the label:
  - "total RD" / "kul RD" / "monthly RD" / "book size" / "har mahine kitna" WITHOUT
    the word deposited/jama => SUM(denomination_amount)  (the MONTHLY total, i.e.
    one installment per account). label e.g. "Total monthly RD".
  - "total deposited" / "ab tak jama" / "lifetime deposited" => SUM(est_deposit).
    label e.g. "Total deposited so far". NOTE this is large (years of deposits).
  - "is mahine collection / pending amount" => SUM(denomination_amount) filtered
    by bucket='pending'.  "defaulter outstanding / baaki" => SUM(arrears_amount)
    filtered by bucket='defaulter'.
  Never answer a bare "total RD" with SUM(est_deposit) — that over-counts years.
- If not answerable from these columns (e.g. interest rate, scheme rules, general
  knowledge), return {"sql":"","kind":"none","label":"unsupported"}.
- CRITICAL: these tables hold ONLY this agent's existing customer accounts. If
  the question asks to CALCULATE maturity/interest for a hypothetical deposit —
  it names a scheme with an amount and/or a term ("2000 ki RD 10 saal",
  "9 lakh MIS me kitna milega", "1 lakh NSC maturity", "sukanya 1.5 lakh") —
  that is NOT a database question. Return
  {"sql":"","kind":"none","label":"unsupported"} so the calculator handles it.
  Never turn such a question into a SUM/COUNT over the agent's accounts.

EXAMPLES:
Q: 2000 ki RD 10 saal
A: {"sql":"","kind":"none","label":"unsupported"}
Q: 9 lakh MIS me kitna milega
A: {"sql":"","kind":"none","label":"unsupported"}
Q: how many defaulters / kitne defaulter hain
A: {"sql":"SELECT COUNT(*) AS n FROM v_accounts WHERE bucket='defaulter'","kind":"count","label":"Defaulters"}
Q: is mahine kitna collection pending hai
A: {"sql":"SELECT SUM(denomination_amount) AS total FROM v_accounts WHERE bucket='pending'","kind":"sum","label":"Pending collection this month"}
Q: second half dues after 15th
A: {"sql":"SELECT account_number, customer_name, denomination_amount, next_due, bucket FROM v_accounts WHERE fortnight='second' ORDER BY due_day LIMIT 200","kind":"list","label":"Second-half dues"}
Q: Ramesh ka account dikhao
A: {"sql":"SELECT account_number, customer_name, denomination_amount, next_due, months_paid, bucket FROM v_accounts WHERE customer_name LIKE '%Ramesh%' LIMIT 200","kind":"list","label":"Ramesh"}
Q: sabse zyada default kisne kiya
A: {"sql":"SELECT account_number, customer_name, months_behind, denomination_amount, next_due FROM v_accounts WHERE bucket='defaulter' ORDER BY months_behind DESC LIMIT 200","kind":"list","label":"Most overdue"}
Q: which accounts are about to freeze
A: {"sql":"SELECT account_number, customer_name, months_behind, arrears_amount, next_due FROM v_accounts WHERE about_to_freeze=1 ORDER BY months_behind DESC LIMIT 200","kind":"list","label":"About to freeze"}
Q: total outstanding from defaulters
A: {"sql":"SELECT SUM(arrears_amount) AS total FROM v_accounts WHERE bucket='defaulter'","kind":"sum","label":"Defaulter arrears"}
Q: mera total RD kitna hai / total RD / kul monthly RD
A: {"sql":"SELECT SUM(denomination_amount) AS total FROM v_accounts","kind":"sum","label":"Total monthly RD (all accounts)"}
Q: ab tak kitna jama hua / total deposited so far
A: {"sql":"SELECT SUM(est_deposit) AS total FROM v_accounts","kind":"sum","label":"Total deposited so far"}
Q: kitne total accounts hain
A: {"sql":"SELECT COUNT(*) AS n FROM v_accounts","kind":"count","label":"Total accounts"}
Q: aaj kitna collection hua / aaj kitna mila
A: {"sql":"SELECT SUM(amount) AS total FROM v_collections WHERE is_today=1","kind":"sum","label":"Collected today"}
Q: aaj kis kis se paisa liya
A: {"sql":"SELECT customer_name, account_number, amount, collected_time FROM v_collections WHERE is_today=1 ORDER BY collected_at DESC LIMIT 200","kind":"list","label":"Today's collections"}
Q: is mahine ab tak kitna wasool hua
A: {"sql":"SELECT SUM(amount) AS total FROM v_collections WHERE is_this_cycle=1","kind":"sum","label":"Collected this month"}
Q: Ramesh se is mahine kitna liya
A: {"sql":"SELECT SUM(amount) AS total FROM v_collections WHERE is_this_cycle=1 AND customer_name LIKE '%Ramesh%'","kind":"sum","label":"Collected from Ramesh this month"}
Q: kitni list bani is mahine
A: {"sql":"SELECT COUNT(*) AS n FROM v_lots WHERE is_this_cycle=1","kind":"count","label":"Lists this month"}
Q: kaunsi list submit nahi hui
A: {"sql":"SELECT id, mode, item_count, total_amount, created_on FROM v_lots WHERE is_submitted=0 ORDER BY created_on DESC LIMIT 200","kind":"list","label":"Lists not yet submitted"}
''';

  static String user(String question) => 'Question: $question';
}
