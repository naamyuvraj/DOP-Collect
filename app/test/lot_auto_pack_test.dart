import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/models/collection.dart';
import 'package:dop_collect/models/collection_round.dart';
import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/screens/lists/list_builder_screen.dart';

/// Auto-grouping: the packer that divides a chosen pool into ₹20,000 lists,
/// and the rule that prices each row before it gets there.
///
/// Both halves matter for the same reason. Packing that breaks a ceiling files
/// a document the portal rejects; pricing that ignores the cash actually
/// collected files one the portal ACCEPTS and that is wrong — which is the
/// failure that got the first auto-build deleted, and is the one worth the most
/// tests here.
void main() {
  final now = DateTime(2026, 7, 15);

  RdAccount acct(String n, int denom, {int behindMonths = 0}) => RdAccount(
        accountNumber: n,
        customerName: 'C$n',
        denominationAmount: denom,
        // behindMonths months before the current month => that many owed.
        nextDueDate: DateTime(2026, 7 - behindMonths, 10),
        monthsPaid: 10,
      );

  PackItem item(String n, int denom, int installments) =>
      PackItem(account: acct(n, denom), installments: installments);

  group('the packer respects both ceilings', () {
    test('no cash list exceeds ₹20,000', () {
      // Twelve ₹3,000 rows = ₹36,000: cannot be one list however arranged.
      final items = [for (var i = 0; i < 12; i++) item('a$i', 3000, 1)];
      final r = LotPacking.pack(items, now);
      expect(r.lots, isNotEmpty);
      for (final lot in r.lots) {
        expect(lot.total, lessThanOrEqualTo(LotPacking.defaultCap));
      }
    });

    test('no list exceeds the account ceiling, even when the rupees fit', () {
      // Forty ₹100 rows total ₹4,000 — miles inside the cash cap. Only the
      // row count binds, and it must still bind.
      final items = [for (var i = 0; i < 40; i++) item('a$i', 100, 1)];
      final r = LotPacking.pack(items, now);
      for (final lot in r.lots) {
        expect(lot.count, lessThanOrEqualTo(LotPacking.maxAccountsPerList));
      }
      expect(r.accountCount, 40);
      // 40 rows at 15 a list is three lists — the count ceiling, not the cash.
      expect(r.lotCount, 3);
    });

    test('a cheque list has no rupee ceiling, only the row count', () {
      // ₹75,000 of cheques is legitimate; it must NOT be split on amount.
      final items = [for (var i = 0; i < 15; i++) item('a$i', 5000, 1)];
      final r = LotPacking.pack(items, now, amountCap: null);
      expect(r.lotCount, 1);
      expect(r.lots.single.total, 75000);
    });
  });

  group('the packer loses nothing and invents nothing', () {
    test('every account in, every account out, once', () {
      final items = [
        for (var i = 0; i < 31; i++) item('a$i', 1000 + (i % 7) * 500, 1)
      ];
      final r = LotPacking.pack(items, now);
      final out = [
        for (final lot in r.lots)
          for (final i in lot.items) i.account.accountNumber
      ];
      expect(out.length, 31, reason: 'no row may be dropped or duplicated');
      expect(out.toSet().length, 31);
      expect(r.totalAmount, items.fold<int>(0, (s, i) => s + i.amount));
    });

    test('installment counts are carried through untouched', () {
      // The packer decides which list a row lands on. It must never decide how
      // much a customer is down for — that is the agent's figure.
      final r = LotPacking.pack([item('a', 2000, 3), item('b', 1000, 2)], now);
      final byAccount = {
        for (final lot in r.lots)
          for (final i in lot.items) i.account.accountNumber: i.installments
      };
      expect(byAccount, {'a': 3, 'b': 2});
    });

    test('a row too big for any cash list is surfaced, not dropped', () {
      // Three months of a ₹10,000 installment is ₹30,000. No arrangement of
      // lists holds it, and silently omitting it is discovered at the counter.
      final items = [item('big', 10000, 3), item('small', 1000, 1)];
      final r = LotPacking.pack(items, now);
      expect(r.unplaceable.map((i) => i.account.accountNumber), ['big']);
      expect(r.accountCount, 1);
      expect(r.lots.single.items.single.account.accountNumber, 'small');
    });

    test('a zero-installment row is not listed at all', () {
      // A part-paid customer seeds to zero. Listing him for nothing would file
      // a ₹0 row against his account.
      final r = LotPacking.pack([item('a', 1000, 0), item('b', 1000, 1)], now);
      expect(r.accountCount, 1);
      expect(r.unplaceable, isEmpty);
    });

    test('an empty pool packs to nothing rather than one empty list', () {
      final r = LotPacking.pack(const [], now);
      expect(r.isEmpty, isTrue);
      expect(r.lotCount, 0);
    });
  });

  group('the packer fills lists, which is the whole point of it', () {
    test('it finds the two-list packing rather than a lazy three', () {
      // 10k,10k,5k,5k,5k,1k = ₹36,000. Two lists is optimal (20k + 16k); a
      // first-fit that took the small rows first would need three.
      final items = [
        item('p', 10000, 1),
        item('q', 10000, 1),
        item('r', 5000, 1),
        item('s', 5000, 1),
        item('t', 5000, 1),
        item('u', 1000, 1),
      ];
      final r = LotPacking.pack(items, now);
      expect(r.lotCount, 2);
      expect(r.lots.first.total, 20000, reason: 'fullest list comes first');
    });

    test('it hits the arithmetic minimum on an even split', () {
      // 30 rows x ₹2,000 = ₹60,000, and 10 rows fill a list exactly. Three
      // lists is the floor and there is no excuse for a fourth.
      final items = [for (var i = 0; i < 30; i++) item('a$i', 2000, 1)];
      final r = LotPacking.pack(items, now);
      expect(r.lotCount, 3);
      for (final lot in r.lots) {
        expect(lot.total, 20000);
        expect(lot.count, 10);
      }
    });

    test('a big row and the small rows that fill its list share it', () {
      // ₹18,000 leaves ₹2,000. Two ₹1,000 rows belong on that list, not on a
      // second one.
      final r = LotPacking.pack([
        item('big', 18000, 1),
        item('x', 1000, 1),
        item('y', 1000, 1),
      ], now);
      expect(r.lotCount, 1);
      expect(r.lots.single.count, 3);
    });
  });

  group('the proposal is reproducible', () {
    test('the same pool packs to the same lists every time', () {
      // He reads the proposal, scrolls back, and it has to be the proposal he
      // read. Ties are broken deterministically for exactly this reason.
      List<List<String>> shape(List<PackItem> items) {
        final r = LotPacking.pack(items, now);
        return [
          for (final lot in r.lots)
            [for (final i in lot.items) i.account.accountNumber]
        ];
      }

      final items = [for (var i = 0; i < 23; i++) item('a$i', 2000, 1)];
      expect(shape(items), shape(items));
      // Same set, different input order — same proposal.
      expect(shape(items), shape(items.reversed.toList()));
    });
  });

  group('rows sit in the order the counter wants', () {
    test('within a list, owed-and-on-time sorts above paid-ahead', () {
      final ahead = PackItem(
          account: RdAccount(
              accountNumber: 'ahead',
              customerName: 'Ahead',
              denominationAmount: 1000,
              nextDueDate: DateTime(2026, 9, 10),
              monthsPaid: 10),
          installments: 1);
      final due = item('due', 1000, 1);
      final r = LotPacking.pack([ahead, due], now);
      expect(r.lots.single.items.map((i) => i.account.accountNumber),
          ['due', 'ahead']);
    });
  });

  group('the builder and the packer agree on the limits', () {
    // If these ever drift, the packer proposes lists the manual builder would
    // refuse — the exact failure the shared constants exist to prevent.
    test('caps match the screen the lists are edited on', () {
      expect(LotPacking.maxAccountsPerList, ListBuilderScreen.maxAccounts);
      expect(LotPacking.defaultCap, ListBuilderScreen.lotCap);
    });

    test('packing under the screen defaults never overfills the screen', () {
      final items = [for (var i = 0; i < 60; i++) item('a$i', 1500, 1)];
      final r = LotPacking.pack(items, now,
          amountCap: ListBuilderScreen.lotCap,
          maxAccounts: ListBuilderScreen.maxAccounts);
      for (final lot in r.lots) {
        expect(lot.count, lessThanOrEqualTo(ListBuilderScreen.maxAccounts));
        expect(lot.total, lessThanOrEqualTo(ListBuilderScreen.lotCap));
      }
    });
  });

  group('pricing a row: the ledger outranks the due date', () {
    Collection paid(String account, int amount, int installments) => Collection(
          accountNumber: account,
          amount: amount,
          collectedAt: DateTime(2026, 7, 10),
          cycleYm: '2026-07',
          installments: installments,
        );

    int seedFor(RdAccount a, List<Collection> entries) {
      final progress = CollectionRound.progressByAccount([a], entries);
      return CollectionRound.listInstallments(a, progress[a.accountNumber], now);
    }

    test('three months collected is listed as three, not one', () {
      // THE regression that deleted the first auto-build. The portal still
      // shows one month due; the agent is carrying three months of this
      // customer's cash.
      final a = acct('a', 1000);
      expect(seedFor(a, [paid('a', 3000, 3)]), 3);
    });

    test('one month collected from a customer five months behind lists one',
        () {
      // The mirror of the above, and just as important: the list must describe
      // the cash in the bag, not the debt on the portal. Listing five would
      // file a deposit he cannot fund.
      final a = acct('a', 1000, behindMonths: 5);
      expect(seedFor(a, [paid('a', 1000, 1)]), 1);
    });

    test('a part-paid customer seeds to zero, not to a rounded-up one', () {
      // ₹600 of a ₹1,000 installment is not a month. Listing him for one files
      // a deposit against ₹400 still in his pocket.
      final a = acct('a', 1000);
      expect(seedFor(a, [paid('a', 600, 0)]), 0);
    });

    test('a customer the ledger has not seen falls back to what is owed', () {
      // Silence is not a statement that nothing is owed — an agent who does not
      // work the collect sheet has an empty ledger for everyone.
      expect(seedFor(acct('a', 1000, behindMonths: 4), const []), 4);
    });

    test('a paid-ahead customer the ledger has not seen still seeds to one', () {
      // Months behind is negative here; the floor keeps him listable rather
      // than producing a negative or zero row.
      expect(seedFor(acct('a', 1000, behindMonths: -2), const []), 1);
    });

    test('a zero seed is not quietly promoted back to one', () {
      // The gate is `collected > 0`, not `seed > 0`. If it were the latter, the
      // part-payer above would fall through to the arrears branch and be listed
      // for a month he has not paid — which is the bug this whole rule exists
      // to prevent.
      final a = acct('a', 1000, behindMonths: 3);
      expect(seedFor(a, [paid('a', 200, 0)]), 0);
    });
  });
}
