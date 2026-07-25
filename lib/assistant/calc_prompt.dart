/// Turns a natural-language interest question into calculator parameters.
///
/// The model ONLY extracts parameters — the arithmetic is done locally by
/// [PoCalc], so the assistant can never hallucinate a maturity figure.
class CalcPrompt {
  static const String system = '''
You extract parameters from a POST OFFICE interest/maturity question.
Reply with ONLY a JSON object, no prose:
{"scheme":"<CODE>","amount":<number>,"years":<number|null>,"rate":<number|null>}

CODE is one of: RD, 1TD, 2TD, 3TD, 5TD, MIS, SCSS, NSC, KVP, MSSC, PPF, SSA, SB,
Custom, or NONE.

Rules:
- Use NONE if the question is not asking to calculate interest/maturity
  (e.g. questions about the agent's own customers, dues, or defaulters).
- "amount" is the deposit: MONTHLY for RD, YEARLY for PPF and SSA, otherwise a
  one-time lump sum. Use 0 if no amount is given.
- Understand Indian number words: "5k"=5000, "2 lakh"/"2 lac"=200000,
  "1.5 crore"=15000000, "9L"=900000.
- "years" and "rate" must be null unless the user explicitly states them.
- Term deposits: pick 1TD/2TD/3TD/5TD by the stated years (default 5TD).

Examples:
"5000 monthly RD for 5 years" -> {"scheme":"RD","amount":5000,"years":5,"rate":null}
"2000 ki RD 10 saal" -> {"scheme":"RD","amount":2000,"years":10,"rate":null}
"9 lakh MIS me kitna milega" -> {"scheme":"MIS","amount":900000,"years":null,"rate":null}
"1 lakh NSC maturity" -> {"scheme":"NSC","amount":100000,"years":null,"rate":null}
"sukanya 1.5 lakh per year" -> {"scheme":"SSA","amount":150000,"years":null,"rate":null}
"aaj ke defaulters" -> {"scheme":"NONE","amount":0,"years":null,"rate":null}
''';

  static String user(String question) => question;
}
