/// Thrown when LLM-generated SQL fails the safety whitelist.
class SqlRejected implements Exception {
  SqlRejected(this.reason);
  final String reason;
  @override
  String toString() => 'SqlRejected: $reason';
}

/// Validates and normalizes SQL produced by the cloud model before it is run.
///
/// The model output is untrusted: only a single read-only `SELECT` over the
/// whitelisted views is allowed. Because we run it against read-only views on
/// the local DB, a worst case is wrong rows — never data loss — but we still
/// reject anything that smells like mutation, DDL, multi-statement, or comments.
class SqlGuard {
  /// The only names that may follow FROM or JOIN. All three are views, so even
  /// a query that slipped past every other check can read nothing the app does
  /// not already show on screen — and can write nothing at all.
  static const Set<String> allowedTables = {
    'v_accounts',   // the book, as the portal sees it
    'v_collections', // the field ledger — what he took, and when
    'v_lots',       // the lists he has built and submitted
  };

  /// Statement keywords, matched as whole words.
  ///
  /// These used to be plain substring tests, which meant any column whose name
  /// merely contained one was unreadable — `v_lots.created_on` contains
  /// "create", so a perfectly ordinary SELECT was rejected as a DDL attempt.
  /// Word boundaries keep the check strict about statements while letting
  /// columns be named in English.
  static const List<String> _forbiddenWords = [
    'insert', 'update', 'delete', 'drop', 'alter', 'create', 'replace',
    'attach', 'detach', 'pragma', 'vacuum', 'reindex', 'trigger',
    'begin', 'commit', 'rollback', 'grant',
  ];

  /// Punctuation that has no place in a single expression, matched literally:
  /// statement separators and comment markers, which are how a second
  /// statement would be smuggled in.
  static const List<String> _forbiddenChars = [';', '--', '/*', '*/'];

  /// Returns a safe SELECT (with a LIMIT injected if absent) or throws
  /// [SqlRejected].
  static String sanitize(String rawSql, {int maxRows = 200}) {
    var s = rawSql.trim();
    // Strip a single trailing semicolon before the multi-statement check.
    if (s.endsWith(';')) s = s.substring(0, s.length - 1).trim();
    final lower = s.toLowerCase();

    if (lower.isEmpty) throw SqlRejected('empty');
    if (!lower.startsWith('select')) throw SqlRejected('not a SELECT');

    for (final kw in _forbiddenChars) {
      if (lower.contains(kw)) throw SqlRejected('forbidden token: $kw');
    }
    for (final kw in _forbiddenWords) {
      if (RegExp('(?<![a-z_])$kw(?![a-z_])').hasMatch(lower)) {
        throw SqlRejected('forbidden keyword: $kw');
      }
    }

    // Must read from one of our views, and must not name anything else after
    // FROM/JOIN. Checked by parsing the sources rather than by substring, so a
    // column called `v_accounts_note` could never smuggle a table past it.
    final sources = RegExp(r'\b(from|join)\s+([a-z_][a-z0-9_]*)')
        .allMatches(lower)
        .map((m) => m.group(2)!)
        .toList();
    if (sources.isEmpty) throw SqlRejected('no table');
    for (final t in sources) {
      if (!allowedTables.contains(t)) throw SqlRejected('unknown table: $t');
    }

    if (!lower.contains('limit')) s = '$s LIMIT $maxRows';
    return s;
  }
}
