import 'package:dop_collect/assistant/collect_action.dart';
import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/collection_repository.dart';
import 'package:dop_collect/models/collection.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RdAccount acc(String number, String name, {int amount = 1000}) => RdAccount(
      accountNumber: number,
      customerName: name,
      denominationAmount: amount,
      nextDueDate: DateTime(2026, 8, 10),
      monthsPaid: 12,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('CollectPhrase — instructions', () {
    test('takes the name and the amount out of Hinglish', () {
      final r = CollectPhrase.parse('Ramesh se 500 le liya');
      expect(r, isNotNull);
      expect(r!.name, 'ramesh');
      expect(r.amount, 500);
      expect(r.isUndo, isFalse);
    });

    test('handles a full name and a different verb', () {
      final r = CollectPhrase.parse('ramesh kumar ne 1000 diya');
      expect(r!.name, 'ramesh kumar');
      expect(r.amount, 1000);
    });

    test('handles English word order', () {
      final r = CollectPhrase.parse('collected 250 from suresh');
      expect(r!.name, 'suresh');
      expect(r.amount, 250);
    });

    test('an amount is optional — the sheet rule fills it in', () {
      final r = CollectPhrase.parse('ramesh se le liya');
      expect(r!.name, 'ramesh');
      expect(r.amount, isNull);
    });

    test('recognises an undo', () {
      final r = CollectPhrase.parse('ramesh ka undo karo');
      expect(r!.isUndo, isTrue);
      expect(r.name, 'ramesh');
    });
  });

  group('CollectPhrase — everything that must NOT become an action', () {
    // The parser sits in front of every question the assistant answers, so a
    // false positive here turns a question into a proposed write.
    for (final q in const [
      'Ramesh se kitna liya',      // asking, not telling
      'aaj kitna collect hua',     // asking
      'kisne paisa diya',          // asking — case-inflected interrogative
      'kisko paisa diya',
      'kaunsa account jama hua',
      'kitne log ne diya',
      'aaj ke defaulters',         // no verb at all
      'Ramesh ka account',         // a lookup
      'ramesh se paanch sau lena hai', // a plan, not a receipt
      '2000 ki RD 10 saal',        // a calculation
      '',
    ]) {
      test('"$q" is not an instruction', () {
        expect(CollectPhrase.parse(q), isNull);
      });
    }
  });

  group('CollectActions.resolve', () {
    late MemoryAccountRepository accounts;
    late MemoryCollectionRepository collections;
    late CollectActions actions;
    final now = DateTime(2026, 8, 13, 11);

    setUp(() async {
      accounts = MemoryAccountRepository();
      collections = MemoryCollectionRepository();
      await accounts.replaceAll([
        acc('100001', 'Ramesh Kumar'),
        acc('100002', 'Suresh Yadav', amount: 3000),
        acc('100003', 'Ramesh Yadav'),
      ]);
      actions = CollectActions(accounts: accounts, collections: collections);
    });

    test('an unknown name is no match, not a guess', () async {
      final r = await actions.resolve(
          const CollectRequest(name: 'mahesh', amount: 500), now);
      expect(r, isA<CollectNoMatch>());
    });

    test('two Rameshes ask rather than pick one', () async {
      final r = await actions.resolve(
          const CollectRequest(name: 'ramesh', amount: 500), now);
      expect(r, isA<CollectAmbiguous>());
      expect((r as CollectAmbiguous).matches, hasLength(2));
    });

    test('an exact full name wins over the other partial match', () async {
      final r = await actions.resolve(
          const CollectRequest(name: 'ramesh kumar', amount: 500), now);
      expect(r, isA<CollectReady>());
      expect((r as CollectReady).action.account.accountNumber, '100001');
      expect(r.action.amount, 500);
    });

    test('a part payment carries no installment', () async {
      final r = await actions.resolve(
          const CollectRequest(name: 'suresh', amount: 500), now);
      expect((r as CollectReady).action.installments, 0);
    });

    test('a full installment carries one', () async {
      final r = await actions.resolve(
          const CollectRequest(name: 'suresh', amount: 3000), now);
      expect((r as CollectReady).action.installments, 1);
    });

    test('no amount falls back to the daily rule', () async {
      // ₹3,000 over the default 30 visits = ₹100.
      final r =
          await actions.resolve(const CollectRequest(name: 'suresh'), now);
      expect((r as CollectReady).action.amount, 100);
    });

    test('undo targets the latest entry, and only within this cycle',
        () async {
      await collections.add(Collection(
        accountNumber: '100002',
        amount: 700,
        collectedAt: now.subtract(const Duration(days: 40)),
        cycleYm: '2026-07',
      ));
      final recent = await collections.add(Collection(
        accountNumber: '100002',
        amount: 300,
        collectedAt: now,
        cycleYm: '2026-08',
      ));
      final r = await actions.resolve(
          const CollectRequest(name: 'suresh', isUndo: true), now);
      expect((r as CollectReady).action.entryId, recent.id);
      expect(r.action.amount, 300);
    });

    test('nothing collected this cycle means nothing to undo', () async {
      final r = await actions.resolve(
          const CollectRequest(name: 'suresh', isUndo: true), now);
      expect(r, isA<CollectNoMatch>());
    });
  });

  group('CollectActions.perform', () {
    test('writes one ledger row and hands back its id for undo', () async {
      final accounts = MemoryAccountRepository();
      final collections = MemoryCollectionRepository();
      await accounts.replaceAll([acc('100001', 'Ramesh Kumar')]);
      final actions =
          CollectActions(accounts: accounts, collections: collections);
      final now = DateTime(2026, 8, 13, 11);

      final outcome = await actions.perform(
        CollectAction(
          kind: CollectActionKind.collect,
          account: acc('100001', 'Ramesh Kumar'),
          amount: 500,
          installments: 0,
        ),
        now,
      );
      expect(outcome.entryId, isNotNull);
      expect(await collections.forCycle('2026-08'), hasLength(1));

      await actions.undo(outcome.entryId!);
      expect(await collections.forCycle('2026-08'), isEmpty);
    });
  });
}
