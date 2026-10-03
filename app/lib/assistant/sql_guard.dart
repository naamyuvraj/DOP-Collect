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
    'v_accounts', // the book, as the portal sees it
    'v_collections', // the field ledger — what he took, and when
    'v_lots', // the lists he has built and submitted
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
    // Not statements — functions that reach outside the database. The
    // read-only handle stops writes; it stops none of these.
    'load_extension', 'readfile', 'writefile', 'fts3_tokenizer',
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

    // A subquery in table position hides whatever follows it from the
    // comma-list scan below — `FROM (SELECT * FROM v_accounts), sqlite_master`
    // would report only `v_accounts`. Flat SELECTs are all this needs in order
    // to answer, and `WITH` is already refused, so refuse this too.
    if (_subqueryTable.hasMatch(lower)) {
      throw SqlRejected('subquery in FROM/JOIN');
    }
    // Belt and braces: nothing in SQLite's own namespace is ever the answer to
    // a question about the agent's book.
    if (lower.contains('sqlite_')) throw SqlRejected('internal table');

    // Must read from one of our views, and must not name anything else in a
    // table position. Checked by parsing the sources rather than by substring,
    // so a column called `v_accounts_note` could never smuggle a table past it.
    final sources = tableSources(lower);
    if (sources.isEmpty) throw SqlRejected('no table');
    for (final t in sources) {
      if (!allowedTables.contains(t)) throw SqlRejected('unknown table: $t');
    }

    if (!_hasLimit.hasMatch(lower)) s = '$s LIMIT $maxRows';
    return s;
  }

  /// A real `LIMIT n` clause, not merely the letters "limit".
  ///
  /// This was `lower.contains('limit')`, so any identifier containing the word
  /// — `SELECT customer_name AS daily_limit FROM v_accounts` — convinced the
  /// guard a cap was already present and the query then ran unbounded.
  static final RegExp _hasLimit = RegExp(r'(?<![a-z_])limit\s+\d');

  /// Every table named in a table position, lower-cased.
  ///
  /// `FROM`/`JOIN` introduce a COMMA-SEPARATED list, and only the first entry
  /// used to be inspected. That let the whitelist be walked straight past:
  ///
  ///     SELECT sm.sql FROM v_accounts, sqlite_master sm   -- the whole schema
  ///     SELECT * FROM v_accounts, collections             -- the raw ledger
  ///
  /// Both name `v_accounts` first, passed the check, and then read whatever
  /// they liked. So the whole list is read here: after a FROM or JOIN, take
  /// each comma-separated entry and keep its FIRST identifier — the table —
  /// discarding any alias that follows it.
  static List<String> tableSources(String lowerSql) {
    final out = <String>[];
    for (final m in _fromClause.allMatches(lowerSql)) {
      for (final entry in m.group(1)!.split(',')) {
        final t = _firstIdent.firstMatch(entry.trim())?.group(0);
        if (t == null) continue;
        // `FROM x WHERE …` — a trailing keyword is not a second table.
        if (_clauseKeywords.contains(t)) continue;
        out.add(t);
      }
    }
    return out;
  }

  static final RegExp _fromClause = RegExp(r'(?<![a-z_])(?:from|join)\s+'
      r'([a-z_][a-z0-9_]*(?:\s+[a-z_][a-z0-9_]*)?'
      r'(?:\s*,\s*[a-z_][a-z0-9_]*(?:\s+[a-z_][a-z0-9_]*)?)*)');
  static final RegExp _firstIdent = RegExp(r'^[a-z_][a-z0-9_]*');
  static final RegExp _subqueryTable = RegExp(r'(?<![a-z_])(?:from|join)\s*\(');

  /// Words that may legally follow a table name and are not tables themselves.
  static const Set<String> _clauseKeywords = {
    'where',
    'group',
    'order',
    'having',
    'limit',
    'union',
    'on',
    'as',
    'left',
    'right',
    'inner',
    'outer',
    'cross',
    'natural',
    'join',
    'using',
    'window',
    'except',
    'intersect',
    'offset',
  };
}
