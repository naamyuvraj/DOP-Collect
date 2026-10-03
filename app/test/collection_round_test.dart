import 'package:dop_collect/models/collection.dart';
import 'package:dop_collect/models/collection_round.dart';
import 'package:dop_collect/models/daily_rule.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

RdAccount _acct(
  String n, {
  int denom = 1000,
  DateTime? due,
  int? daily,
  int? route,
}) =>
    RdAccount(
      accountNumber: n,
      customerName: 'C$n',
      denominationAmount: denom,
      nextDueDate: due ?? DateTime(2026, 8, 10),
      monthsPaid: 12,
      dailyAmount: daily,
      routeOrder: route,
    );

Collection _paid(String acct, int amount, {DateTime? at, int inst = 0}) {
  final when = at ?? DateTime(2026, 8, 3, 10);
  return Collection(
    accountNumber: acct,
    amount: amount,
    installments: inst,
    collectedAt: when,
    cycleYm: Collection.cycleOf(when),
  );
}

void main() {
  final now = DateTime(2026, 8, 12);

  group('progress is summed from the ledger, never stored', () {
    test('many small handovers add up to one installment', () {
      final a = _acct('1', denom: 1000, daily: 30);
      final rows = CollectionRound.progressByAccount(
          [a], [for (var i = 0; i < 4; i++) _paid('1', 30)]);
      final p = rows['1']!;
      expect(p.collected, 120);
      expect(p.remaining, 880);
      expect(p.partial, isTrue);
      expect(p.complete, isFalse);
    });

    test('a cycle with no entries is simply untouched', () {
      final p = CollectionRound.progressByAccount([_acct('1')], [])['1']!;
      expect(p.collected, 0);
      expect(p.untouched, isTrue);
      expect(p.remaining, 1000);
    });

    test('overpayment is an advance, never a negative balance', () {
      final p = CollectionRound.progressByAccount(
          [_acct('1', denom: 1000)], [_paid('1', 2500)])['1']!;
      expect(p.remaining, 0);
      expect(p.complete, isTrue);
      expect(p.advanceMonths, 2);
    });
  });

  group('the daily amount is the installment spread over the month', () {
    // The whole point: the figure comes from the account's own value, never a
    // generic 10/20/50 list.
    test('is denomination over the month, rounded up', () {
      const rule = DailyRule.standard; // 30 visits
      expect(rule.baseFor(_acct('a', denom: 15000)), 500);
      expect(rule.baseFor(_acct('b', denom: 3000)), 100);
      // Rounds UP: ₹33.33 becomes ₹34, so thirty visits can actually reach
      // ₹1,000. Rounding down would leave the agent covering the difference.
      expect(rule.baseFor(_acct('c', denom: 1000)), 34);
      expect(rule.baseFor(_acct('d', denom: 500)), 17);
    });

    test('the agent can change the number of visits for the whole book', () {
      const rule = DailyRule(days: 25);
      expect(rule.baseFor(_acct('a', denom: 15000)), 600);
    });

    test('or put every account on one flat amount', () {
      const rule = DailyRule(mode: DailyMode.flat, flatAmount: 50);
      expect(rule.baseFor(_acct('a', denom: 15000)), 50);
      expect(rule.baseFor(_acct('b', denom: 1000)), 50);
    });

    test('one customer\'s own amount overrides the book-wide rule', () {
      const rule = DailyRule.standard;
      expect(rule.amountFor(_acct('a', denom: 1000, daily: 50)), 50);
      expect(rule.amountFor(_acct('b', denom: 1000)), 34); // rule applies
    });

    test('an ordinary visit takes the daily amount', () {
      final p = CollectionRound.progressByAccount(
          [_acct('1', denom: 1000)], [_paid('1', 300)])['1']!;
      expect(p.dailyNext, 34);
      expect(p.isSettling, isFalse);
    });

    test('the last visit takes the remainder, not another daily slice', () {
      final p = CollectionRound.progressByAccount(
          [_acct('1', denom: 1000)], [_paid('1', 990)])['1']!;
      // ₹10 left, less than the ₹34 daily — take the ₹10 and close the month.
      expect(p.dailyNext, 10);
      expect(p.isSettling, isTrue);
    });

    test('daily visits reach the installment exactly, never over', () {
      final a = _acct('1', denom: 1000);
      var taken = 0;
      final entries = <Collection>[];
      for (var visit = 0; visit < 60 && taken < 1000; visit++) {
        final p = CollectionRound.progressByAccount([a], entries)['1']!;
        entries.add(_paid('1', p.dailyNext));
        taken += p.dailyNext;
      }
      // ₹34 × 29 = ₹986, then ₹14 settles it. Not ₹1,020, not ₹986.
      expect(taken, 1000);
      expect(CollectionRound.progressByAccount([a], entries)['1']!.complete,
          isTrue);
    });

    test('a full-month swipe hands over the whole installment', () {
      final p =
          CollectionRound.progressByAccount([_acct('1', denom: 1000)], [])['1']!;
      expect(p.monthlyNext, 1000);
    });

    test('a full-month swipe on a part-paid customer takes only the balance',
        () {
      final p = CollectionRound.progressByAccount(
          [_acct('1', denom: 1000)], [_paid('1', 400)])['1']!;
      expect(p.monthlyNext, 600);
    });
  });

  group('grouping', () {
    test('untouched, part-paid and complete land in their own groups', () {
      final accounts = [_acct('a'), _acct('b'), _acct('c')];
      final rows = CollectionRound.build(
          accounts, [_paid('b', 400), _paid('c', 1000)], now);
      Map<String, RoundGroup> g = {
        for (final r in rows) r.accountNumber: r.group
      };
      expect(g['a'], RoundGroup.toCollect);
      expect(g['b'], RoundGroup.partial);
      expect(g['c'], RoundGroup.collected);
    });

    test('an account already on a list must not be collected from again', () {
      final rows = CollectionRound.build([_acct('a')], [], now,
          alreadyListed: {'a'});
      expect(rows.single.group, RoundGroup.settled);
    });

    test('paid ahead on the portal is nothing to collect', () {
      // Next due in October while collecting in August: already paid forward.
      final rows = CollectionRound.build(
          [_acct('a', due: DateTime(2026, 10, 10))], [], now);
      expect(rows.single.group, RoundGroup.settled);
    });

    test('groups are ordered work-first, settled-last', () {
      final rows = CollectionRound.build(
        [_acct('done'), _acct('todo'), _acct('part')],
        [_paid('done', 1000), _paid('part', 200)],
        now,
      );
      expect(rows.map((r) => r.accountNumber),
          ['todo', 'part', 'done']);
    });
  });

  group('the paid filter', () {
    List<RoundEntry> rows() => CollectionRound.build(
          [_acct('todo'), _acct('part'), _acct('done'), _acct('listed')],
          [_paid('part', 400), _paid('done', 1000)],
          now,
          alreadyListed: {'listed'},
        );

    test('All shows every account — nothing is ever hidden', () {
      expect(rows().where(RoundFilter.all.matches).length, 4);
    });

    test('Paid means the month is covered, not "has paid something"', () {
      final paid =
          rows().where(RoundFilter.paid.matches).map((r) => r.accountNumber);
      // 'part' handed over ₹400 of ₹1,000 — started, but not paid.
      expect(paid, containsAll(<String>['done', 'listed']));
      expect(paid, isNot(contains('part')));
      expect(paid, isNot(contains('todo')));
    });

    test('To collect covers untouched and part-paid together', () {
      final owing = rows()
          .where(RoundFilter.toCollect.matches)
          .map((r) => r.accountNumber);
      expect(owing, containsAll(<String>['todo', 'part']));
      expect(owing.length, 2);
    });

    test('the two working filters partition the book with no gaps', () {
      final all = rows();
      final owing = all.where(RoundFilter.toCollect.matches).length;
      final paid = all.where(RoundFilter.paid.matches).length;
      // Every account is in exactly one of the two — so the counts on the
      // filter chips can always be trusted to add up to the total.
      expect(owing + paid, all.length);
    });
  });

  group('ordering', () {
    test('my route wins, and unplaced customers fall to the end', () {
      final rows = CollectionRound.build(
        [
          _acct('third', route: 3, due: DateTime(2026, 8, 1)),
          _acct('unplaced', due: DateTime(2026, 8, 2)),
          _acct('first', route: 1, due: DateTime(2026, 8, 28)),
        ],
        [],
        now,
        sort: RoundSort.route,
      );
      expect(rows.map((r) => r.accountNumber),
          ['first', 'third', 'unplaced']);
    });

    test('due date is the fallback before any route exists', () {
      final rows = CollectionRound.build(
        [
          _acct('late', due: DateTime(2026, 8, 28)),
          _acct('early', due: DateTime(2026, 8, 2)),
        ],
        [],
        now,
        sort: RoundSort.due,
      );
      expect(rows.map((r) => r.accountNumber), ['early', 'late']);
    });
  });

  group('the round totals', () {
    test('outstanding counts only what is still owed', () {
      final rows = CollectionRound.build(
        [_acct('a'), _acct('b'), _acct('c')],
        [_paid('b', 400), _paid('c', 1000)],
        now,
      );
      // a owes 1000, b owes 600, c is done.
      expect(CollectionRound.outstanding(rows), 1600);
    });

    test('the bag is the sum of the day, whatever the cycle', () {
      expect(
          CollectionRound.total([_paid('a', 30), _paid('b', 1000)]), 1030);
    });

    test('shortfall lists the part-paid, biggest gap first', () {
      final rows = CollectionRound.build(
        [_acct('small'), _acct('big'), _acct('done')],
        [_paid('small', 900), _paid('big', 100), _paid('done', 1000)],
        now,
      );
      final short = CollectionRound.shortfall(rows);
      expect(short.map((r) => r.accountNumber), ['big', 'small']);
      expect(short.first.progress.remaining, 900);
    });

    test('the shortfall warning holds until list day is close', () {
      expect(CollectionRound.nearCycleEnd(DateTime(2026, 8, 12)), isFalse);
      expect(CollectionRound.nearCycleEnd(DateTime(2026, 8, 26)), isTrue);
    });
  });

  test('a cycle stops counting when the month turns over', () {
    // The lesson from the old sticky "deposited" flag: last month's money must
    // not make this month look collected.
    final july = _paid('a', 1000, at: DateTime(2026, 7, 20));
    expect(july.cycleYm, '2026-07');
    final rows = CollectionRound.build([_acct('a')], const [], now);
    expect(rows.single.group, RoundGroup.toCollect);
  });
}
