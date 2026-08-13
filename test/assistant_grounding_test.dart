import 'package:dop_collect/assistant/answer.dart';
import 'package:dop_collect/assistant/intent_engine.dart';
import 'package:dop_collect/assistant/sql_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// The assistant used to be able to see only `v_accounts` — the book as the
/// portal describes it. Everything the agent actually DID (the cash he took,
/// the lists he built) was unreachable. These tests pin the two halves of the
/// fix: the guard now admits the ledger views, and the offline engine routes
/// "collected" questions to them without stealing the "pending" ones.
void main() {
  group('SqlGuard — which views are readable', () {
    test('admits the ledger view', () {
      final sql = SqlGuard.sanitize(
          'SELECT SUM(amount) AS total FROM v_collections WHERE is_today=1');
      expect(sql, contains('v_collections'));
      expect(sql, contains('LIMIT'));
    });

    test('admits the lists view', () {
      expect(SqlGuard.sanitize('SELECT COUNT(*) AS n FROM v_lots'),
          contains('v_lots'));
    });

    test('a join across two allowed views is fine', () {
      expect(
        () => SqlGuard.sanitize('SELECT a.customer_name FROM v_accounts a '
            'JOIN v_collections c ON c.account_number = a.account_number'),
        returnsNormally,
      );
    });

    test('still refuses the underlying tables', () {
      for (final t in const ['accounts', 'collections', 'lots', 'sqlite_master']) {
        expect(() => SqlGuard.sanitize('SELECT * FROM $t'),
            throwsA(isA<SqlRejected>()),
            reason: '$t must not be readable directly');
      }
    });

    test('a column whose name contains a view name is not a table', () {
      // The old check was a substring test, so this would have passed it.
      expect(() => SqlGuard.sanitize('SELECT v_accounts_note FROM secrets'),
          throwsA(isA<SqlRejected>()));
    });

    test('a column merely containing a keyword is readable', () {
      // v_lots.created_on contains "create"; the guard used to read that as an
      // attempted CREATE and reject an ordinary SELECT.
      expect(
          () => SqlGuard.sanitize(
              'SELECT id, created_on, created_ym FROM v_lots'),
          returnsNormally);
    });

    test('still refuses writes and multi-statement', () {
      expect(() => SqlGuard.sanitize('DELETE FROM v_accounts'),
          throwsA(isA<SqlRejected>()));
      expect(
          () => SqlGuard.sanitize(
              'SELECT 1 FROM v_accounts; DROP TABLE accounts'),
          throwsA(isA<SqlRejected>()));
    });
  });

  group('IntentEngine — collected vs owed, offline', () {
    String sqlFor(String q) => IntentEngine.match(q)!.sql;

    test('"aaj kitna collect hua" reads the ledger', () {
      final m = IntentEngine.match('aaj kitna collect hua')!;
      expect(m.sql, contains('v_collections'));
      expect(m.sql, contains('is_today=1'));
      expect(m.kind, AnswerKind.sum);
    });

    test('"aaj kisse paisa liya" lists today\'s entries', () {
      final m = IntentEngine.match('aaj kis kis se paisa liya')!;
      expect(m.sql, contains('v_collections'));
      expect(m.kind, AnswerKind.list);
    });

    test('"is mahine kitna wasool hua" reads the cycle', () {
      expect(sqlFor('is mahine kitna wasool hua'), contains('is_this_cycle=1'));
    });

    test('"bag me kitna hai" is today\'s cash', () {
      expect(sqlFor('bag me kitna cash hai'), contains('v_collections'));
    });

    // The regression this ordering exists to prevent: these two questions
    // share almost every word and mean opposite things.
    test('"is mahine kitna collection pending hai" still reads the book', () {
      final sql = sqlFor('is mahine kitna collection pending hai');
      expect(sql, contains('v_accounts'));
      expect(sql, isNot(contains('v_collections')));
    });

    test('"aaj ke defaulters" is untouched', () {
      expect(sqlFor('aaj ke defaulters'), contains("bucket='defaulter'"));
    });

    test('unsubmitted lists', () {
      final m = IntentEngine.match('kaunsi list submit nahi hui')!;
      expect(m.sql, contains('v_lots'));
      expect(m.sql, contains('is_submitted=0'));
    });

    test('every intent it can produce is accepted by the guard', () {
      for (final q in const [
        'aaj kitna collect hua',
        'aaj kis kis se paisa liya',
        'is mahine kitna wasool hua',
        'bag me kitna cash hai',
        'kaunsi list submit nahi hui',
        'kitni list bani',
        'kitne defaulter hain',
        'is mahine kitna collection pending hai',
        'ramesh ka account',
      ]) {
        final m = IntentEngine.match(q);
        expect(m, isNotNull, reason: '"$q" should match an intent');
        expect(() => SqlGuard.sanitize(m!.sql), returnsNormally,
            reason: '"$q" produced SQL the guard rejects');
      }
    });
  });
}
