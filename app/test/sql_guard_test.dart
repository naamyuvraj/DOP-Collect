import 'package:dop_collect/assistant/sql_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard in front of LLM-written SQL.
///
/// It runs on a read-only connection, so the worst case was never data loss —
/// it was the model reading things the app does not show and answering off
/// them. Three ways past it, all closed here.
void main() {
  String? reject(String sql) {
    try {
      SqlGuard.sanitize(sql);
      return null;
    } on SqlRejected catch (e) {
      return e.reason;
    }
  }

  group('the FROM list is read whole, not just its first entry', () {
    // The bypass: only the identifier immediately after FROM was inspected, so
    // naming an allowed view first let anything follow it past the whitelist.
    test('a comma-joined internal table is refused', () {
      expect(reject('SELECT sm.sql FROM v_accounts, sqlite_master sm'),
          isNotNull);
    });

    test('a comma-joined raw table is refused', () {
      expect(reject('SELECT * FROM v_accounts, collections'),
          'unknown table: collections');
      expect(reject('SELECT * FROM v_accounts a, accounts raw'),
          'unknown table: accounts');
    });

    test('a subquery in table position is refused outright', () {
      // It would hide its siblings from the comma scan.
      expect(reject('SELECT * FROM (SELECT * FROM v_accounts), sqlite_master'),
          isNotNull);
    });

    test('but ordinary multi-view queries still work', () {
      for (final sql in [
        'SELECT * FROM v_accounts',
        'SELECT * FROM v_accounts a, v_collections c',
        'SELECT * FROM v_collections c JOIN v_accounts a '
            'ON a.account_number = c.account_number',
        'SELECT bucket, COUNT(*) FROM v_accounts GROUP BY bucket '
            'ORDER BY 2 DESC',
        'SELECT * FROM v_lots WHERE is_submitted = 1',
      ]) {
        expect(reject(sql), isNull, reason: sql);
      }
    });
  });

  group('the row cap is a clause, not a substring', () {
    test('an identifier containing "limit" does not suppress it', () {
      // `AS daily_limit` used to convince the guard a cap was already there.
      final out =
          SqlGuard.sanitize('SELECT customer_name AS daily_limit FROM v_accounts');
      expect(out, endsWith('LIMIT 200'));
    });

    test('a real LIMIT is left alone', () {
      expect(SqlGuard.sanitize('SELECT * FROM v_accounts LIMIT 5'),
          'SELECT * FROM v_accounts LIMIT 5');
    });
  });

  group('functions that reach outside the database', () {
    test('load_extension is refused', () {
      expect(reject("SELECT load_extension('/tmp/x.so') FROM v_accounts"),
          'forbidden keyword: load_extension');
    });
    test('readfile is refused', () {
      expect(reject("SELECT readfile('/etc/passwd') FROM v_accounts"),
          'forbidden keyword: readfile');
    });
  });

  group('what already worked keeps working', () {
    test('mutation, DDL, multi-statement and comments stay refused', () {
      expect(reject('SELECT * FROM v_accounts; DROP TABLE accounts'), isNotNull);
      expect(reject('DELETE FROM v_accounts'), isNotNull);
      expect(reject('SELECT * FROM v_accounts /* x */'), isNotNull);
      expect(reject('WITH x AS (SELECT 1) SELECT * FROM x'), isNotNull);
    });
  });
}
