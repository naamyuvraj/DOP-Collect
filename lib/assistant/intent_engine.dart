import 'answer.dart';

/// A matched local intent: the SQL to run, how to render it, and a label.
class IntentMatch {
  const IntentMatch(this.sql, this.kind, this.label, {this.isSearch = false});
  final String sql;
  final AnswerKind kind;
  final String label;

  /// True for customer name/account lookups. If one of these finds nothing we
  /// fall through to the cloud instead of answering "kuch nahi mila" — the text
  /// probably wasn't a customer name at all.
  final bool isSearch;
}

class _Intent {
  const _Intent(this.test, this.sql, this.kind, this.label);
  final bool Function(String q) test;
  final String sql;
  final AnswerKind kind;
  final String label;
}

/// Deterministic keyword/regex -> canned SQL over `v_accounts`. Answers the
/// ~common daily questions with ZERO internet and zero latency. English +
/// Hindi/Hinglish synonyms. First match wins, so order specific before generic.
///
/// Name lookups are handled locally too (see [_nameLookup]) so a customer's
/// name never leaves the device for the common "X ka account" case.
class IntentEngine {
  /// Keyword test with a LEADING word boundary.
  ///
  /// Plain `contains` was matching inside words — "ac**count**" made every
  /// "<name> ka account" question return the total account count, and
  /// "over**due**"/"un**paid**" hit the wrong buckets. A leading boundary fixes
  /// that while still allowing plurals/suffixes ("defaulter" matches
  /// "defaulters").
  static bool _has(String q, List<String> anyOf) => anyOf.any(
      (w) => RegExp('(?<![a-z])${RegExp.escape(w)}').hasMatch(q));

  static const _listCols =
      'account_number, customer_name, denomination_amount, next_due, months_paid, bucket';

  static final List<_Intent> _intents = <_Intent>[
    // --- Counts (check before list synonyms so "kitne defaulter" counts) ---
    _Intent(
      (q) =>
          _has(q, ['kitne', 'how many', 'count', 'number of', 'total', 'कितने', 'कितना']) &&
          _has(q, ['defaulter', 'default', 'overdue', 'baaki', 'baki', 'डिफॉल्टर', 'डिफाल्टर', 'बकाया', 'बाकी']),
      "SELECT COUNT(*) AS n FROM v_accounts WHERE bucket='defaulter'",
      AnswerKind.count,
      'Defaulter count',
    ),
    _Intent(
      (q) =>
          _has(q, ['kitne', 'how many', 'count', 'कितने', 'कितना']) &&
          _has(q, ['account', 'customer', 'khata', 'total', 'खाता', 'खाते', 'अकाउंट', 'ग्राहक']),
      'SELECT COUNT(*) AS n FROM v_accounts',
      AnswerKind.count,
      'Total accounts',
    ),
    // --- Sums / collection amount ---
    _Intent(
      (q) =>
          _has(q, ['collection', 'amount', 'paisa', 'rupaye', 'rupees', 'kitna', 'total', 'कलेक्शन', 'राशि', 'पैसा', 'रुपये', 'रुपए']) &&
          _has(q, ['pending', 'baki', 'baaki', 'due', 'is mahine', 'this month', 'पेंडिंग', 'बाकी', 'बकाया', 'इस महीने', 'महीने', 'आज']),
      "SELECT SUM(denomination_amount) AS total FROM v_accounts WHERE bucket='pending'",
      AnswerKind.sum,
      'Pending collection this month',
    ),
    _Intent(
      (q) =>
          _has(q, ['outstanding', 'arrears', 'vasooli', 'recovery', 'बकाया', 'वसूली', 'आउटस्टैंडिंग']) ||
          (_has(q, ['total', 'kitna', 'कुल', 'कितना']) &&
              _has(q, ['defaulter', 'overdue', 'baaki', 'डिफॉल्टर', 'बकाया'])),
      "SELECT SUM(arrears_amount) AS total FROM v_accounts WHERE bucket='defaulter'",
      AnswerKind.sum,
      'Defaulter arrears',
    ),
    // --- Lists by bucket ---
    _Intent(
      (q) => _has(q, ['defaulter', 'default', 'overdue', 'baaki', 'nahi diya', 'not paid', 'डिफॉल्टर', 'डिफाल्टर', 'बकाया', 'नहीं दिया']),
      "SELECT $_listCols, months_behind FROM v_accounts "
      "WHERE bucket='defaulter' ORDER BY months_behind DESC LIMIT 200",
      AnswerKind.list,
      'Defaulters',
    ),
    _Intent(
      (q) => _has(q, ['about to freeze', 'freeze', 'jamne', 'block ho', 'फ्रीज', 'जमने', 'ब्लॉक']),
      "SELECT $_listCols, months_behind FROM v_accounts "
      "WHERE about_to_freeze=1 ORDER BY months_behind DESC LIMIT 200",
      AnswerKind.list,
      'About to freeze',
    ),
    _Intent(
      (q) => _has(q, ['deposited', 'paid', 'jama', 'collected', 'जमा', 'भुगतान', 'डिपॉजिट']),
      "SELECT $_listCols FROM v_accounts WHERE bucket='deposited' "
      "ORDER BY next_due LIMIT 200",
      AnswerKind.list,
      'Deposited',
    ),
    _Intent(
      (q) => _has(q, ['maturity', 'mature', 'matured', 'poora ho', 'complete', 'मैच्योरिटी', 'मैच्योर', 'परिपक्व', 'पूरा']),
      "SELECT $_listCols, pending_installments FROM v_accounts "
      "WHERE is_maturity=1 ORDER BY months_paid DESC LIMIT 200",
      AnswerKind.list,
      'Nearing maturity',
    ),
    _Intent(
      (q) => _has(q, ['new account', 'naya', 'naye', 'recently opened', 'new customer', 'नया', 'नये', 'नए', 'नई', 'नया खाता']),
      "SELECT $_listCols, opening_date FROM v_accounts "
      "WHERE is_new=1 ORDER BY opening_date DESC LIMIT 200",
      AnswerKind.list,
      'New accounts',
    ),
    // --- Fortnight ---
    _Intent(
      (q) => _has(q, ['first half', 'pehla', 'pehle', '1st half', 'before 15', 'पहली', 'पहला', 'पहली छमाही']),
      "SELECT $_listCols FROM v_accounts WHERE fortnight='first' "
      "ORDER BY due_day LIMIT 200",
      AnswerKind.list,
      'First-half dues',
    ),
    _Intent(
      (q) => _has(q, ['second half', 'dusra', 'doosra', '2nd half', 'after 15', 'दूसरी', 'दूसरा', 'दूसरी छमाही']),
      "SELECT $_listCols FROM v_accounts WHERE fortnight='second' "
      "ORDER BY due_day LIMIT 200",
      AnswerKind.list,
      'Second-half dues',
    ),
    // --- Pending this month (generic, after the specific amount rule) ---
    _Intent(
      (q) => _has(q, ['pending', 'due this month', 'is mahine', 'baki', 'पेंडिंग', 'बाकी', 'इस महीने']),
      "SELECT $_listCols FROM v_accounts WHERE bucket='pending' "
      "ORDER BY due_day LIMIT 200",
      AnswerKind.list,
      'Pending this month',
    ),
  ];

  /// Returns a matched intent, a local customer lookup, or null (=> try cloud).
  ///
  /// Account-number and name lookups run BEFORE the keyword intents so a
  /// customer called e.g. "Naya" can't be swallowed by the "new accounts" rule.
  static IntentMatch? match(String question) {
    final q = question.toLowerCase().trim();
    final byNumber = _accountLookup(q);
    if (byNumber != null) return byNumber;
    for (final i in _intents) {
      if (i.test(q)) return IntentMatch(i.sql, i.kind, i.label);
    }
    return _nameLookup(q);
  }

  /// Every column, so the answer card can rebuild a full [RdAccount].
  static const _detailCols = '*';

  /// Any run of 6+ digits is treated as an account number (partial allowed —
  /// agents often remember only the tail).
  static IntentMatch? _accountLookup(String q) {
    final m = RegExp(r'(\d{6,})').firstMatch(q.replaceAll(RegExp(r'[\s-]'), ''));
    if (m == null) return null;
    final digits = m.group(1)!;
    return IntentMatch(
      "SELECT $_detailCols FROM v_accounts WHERE account_number LIKE '%$digits%' "
      'ORDER BY next_due LIMIT 50',
      AnswerKind.detail,
      'Account $digits',
      isSearch: true,
    );
  }

  /// Words that mean the text is a question, not a customer's name.
  static const _notNames = [
    'account', 'accounts', 'khata', 'total', 'kitna', 'kitne', 'how', 'what',
    'list', 'due', 'pending', 'defaulter', 'collection', 'interest', 'rate',
    'maturity', 'rd', 'mis', 'scss', 'nsc', 'kvp', 'ppf', 'sukanya', 'app',
    'sync', 'lot', 'group', 'calculate', 'help', 'kaise', 'kya', 'hai',
  ];

  /// Extracts a customer name from common phrasings — or treats a short, plain
  /// run of words as a name outright ("saroj kumar"). Stays fully offline.
  static IntentMatch? _nameLookup(String q) {
    String? name;
    final patterns = <RegExp>[
      RegExp(r'^(.*?)\s+(?:ka|ke|ki)\s+(?:account|khata|detail|details|info)'),
      RegExp(r'(?:account|khata|details?|info)\s+(?:of|for)\s+(.+)$'),
      RegExp(r'^(?:show|find|search|dikhao|dhundo|batao)\s+(.+)$'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(q);
      if (m != null) {
        name = m.group(1)?.trim();
        break;
      }
    }

    // Bare name: 1-4 plain words, none of them question words.
    if (name == null || name.isEmpty) {
      final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      final plain = RegExp(r'^[a-z.]+$');
      if (words.isNotEmpty &&
          words.length <= 4 &&
          words.every((w) => plain.hasMatch(w)) &&
          !words.any(_notNames.contains)) {
        name = q;
      }
    }
    if (name == null || name.isEmpty) return null;

    final clean = name.replaceAll(RegExp(r"[^a-z\s]"), '').trim();
    if (clean.length < 3) return null;
    final safe = clean.replaceAll("'", "''");
    return IntentMatch(
      "SELECT $_detailCols FROM v_accounts WHERE lower(customer_name) LIKE '%$safe%' "
      'ORDER BY next_due LIMIT 50',
      AnswerKind.detail,
      'Search: $clean',
      isSearch: true,
    );
  }
}
