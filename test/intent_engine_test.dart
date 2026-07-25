import 'package:dop_collect/assistant/answer.dart';
import 'package:dop_collect/assistant/intent_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('account-number lookup', () {
    test('finds a full account number', () {
      final m = IntentEngine.match('020002767521');
      expect(m, isNotNull);
      expect(m!.kind, AnswerKind.detail);
      expect(m.isSearch, isTrue);
      expect(m.sql, contains("account_number LIKE '%020002767521%'"));
    });

    test('accepts a partial tail and ignores spacing', () {
      final m = IntentEngine.match('account 7675 21 ka detail');
      expect(m, isNotNull);
      expect(m!.sql, contains('account_number LIKE'));
    });

    test('beats keyword intents so a number never becomes a bucket list', () {
      final m = IntentEngine.match('020002767521 pending hai kya');
      expect(m!.kind, AnswerKind.detail);
    });
  });

  group('name lookup', () {
    test('phrased lookup', () {
      final m = IntentEngine.match('Ramesh ka account');
      expect(m!.kind, AnswerKind.detail);
      expect(m.sql, contains("LIKE '%ramesh%'"));
    });

    test('bare name is treated as a search', () {
      final m = IntentEngine.match('saroj kumar');
      expect(m, isNotNull);
      expect(m!.isSearch, isTrue);
      expect(m.sql, contains("LIKE '%saroj kumar%'"));
    });

    test('selects every column so a full profile can be rendered', () {
      expect(IntentEngine.match('saroj kumar')!.sql, contains('SELECT *'));
    });

    test('question words are not mistaken for names', () {
      for (final q in [
        'kitne total accounts',
        'rd rate',
        'app kaise use kare',
        'pending list',
      ]) {
        final m = IntentEngine.match(q);
        // Either no match, or a real intent — never a name search.
        if (m != null) expect(m.isSearch, isFalse, reason: q);
      }
    });

    test('single-letter noise is rejected', () {
      expect(IntentEngine.match('ok')?.isSearch ?? false, isFalse);
    });
  });

  group('Hindi (Devanagari) queries match locally', () {
    test('डिफॉल्टर -> defaulters', () {
      final m = IntentEngine.match('आज के डिफॉल्टर');
      expect(m!.sql, contains("bucket='defaulter'"));
    });
    test('कितने खाते -> total accounts count', () {
      final m = IntentEngine.match('कुल कितने खाते हैं');
      expect(m!.kind, AnswerKind.count);
      expect(m.sql, contains('COUNT(*)'));
    });
    test('इस महीने पेंडिंग -> pending', () {
      final m = IntentEngine.match('इस महीने पेंडिंग');
      expect(m!.sql, contains("bucket='pending'"));
    });
    test('जमा -> deposited', () {
      final m = IntentEngine.match('जमा खाते');
      expect(m!.sql, contains("bucket='deposited'"));
    });
    test('मैच्योरिटी -> nearing maturity', () {
      final m = IntentEngine.match('मैच्योरिटी वाले');
      expect(m!.sql, contains('is_maturity=1'));
    });
  });

  group('bucket intents still work', () {
    test('defaulters', () {
      final m = IntentEngine.match('aaj ke defaulters');
      expect(m!.kind, AnswerKind.list);
      expect(m.sql, contains("bucket='defaulter'"));
      expect(m.isSearch, isFalse);
    });

    test('counts', () {
      final m = IntentEngine.match('kitne total accounts');
      expect(m!.kind, AnswerKind.count);
    });
  });
}
