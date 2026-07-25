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
/// `v_accounts` view is allowed. Because we run it against a read-only view on
/// the local DB, a worst case is wrong rows — never data loss — but we still
/// reject anything that smells like mutation, DDL, multi-statement, or comments.
class SqlGuard {
  static const List<String> _forbidden = [
    'insert', 'update', 'delete', 'drop', 'alter', 'create', 'replace',
    'attach', 'detach', 'pragma', 'vacuum', 'reindex', 'trigger',
    'begin', 'commit', 'rollback', 'grant', ';', '--', '/*', '*/',
  ];

  /// Returns a safe SELECT (with a LIMIT injected if absent) or throws
  /// [SqlRejected].
  static String sanitize(String rawSql, {int maxRows = 200}) {
    var s = rawSql.trim();
    // Strip a single trailing semicolon before the multi-statement check.
    if (s.endsWith(';')) s = s.substring(0, s.length - 1).trim();
    final lower = s.toLowerCase();

    if (lower.isEmpty) throw SqlRejected('empty');
    if (!lower.startsWith('select')) throw SqlRejected('not a SELECT');

    for (final kw in _forbidden) {
      if (lower.contains(kw)) throw SqlRejected('forbidden token: $kw');
    }

    // Must read from our view, and must not name any other table after FROM/JOIN.
    if (!lower.contains('v_accounts')) throw SqlRejected('no v_accounts');
    for (final m
        in RegExp(r'\b(from|join)\s+([a-z_][a-z0-9_]*)').allMatches(lower)) {
      if (m.group(2) != 'v_accounts') {
        throw SqlRejected('unknown table: ${m.group(2)}');
      }
    }

    if (!lower.contains('limit')) s = '$s LIMIT $maxRows';
    return s;
  }
}
