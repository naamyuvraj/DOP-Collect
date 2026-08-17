import 'dart:convert';

import 'package:dop_collect/models/lot.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rebate and default fee come from the PORTAL, are shown once during
/// submission, and were then thrown away — so every printed report said 0.00 in
/// both columns. For an advance payer that understated the rebate he had earned;
/// for a defaulter it hid a fee he had actually paid, on a document he hands
/// across a post office counter.
///
/// These tests pin the two things that let that happen: the figures must survive
/// a save/load round trip, and "the portal has not said" must stay distinct from
/// "the portal said zero".
LotItem item(String acct, {int? rebate, int? defaultFee, int inst = 1}) =>
    LotItem(
      accountNumber: acct,
      customerName: 'Sita Devi',
      denomination: 1000,
      installments: inst,
      rebate: rebate,
      defaultFee: defaultFee,
    );

Lot lotOf(List<LotItem> items) =>
    Lot(createdAt: DateTime(2026, 8, 16), mode: 'Cash', items: items);

/// Save and reload the way the database does — items go through JSON.
LotItem roundTrip(LotItem it) =>
    LotItem.fromJson(jsonDecode(jsonEncode(it.toJson())) as Map<String, Object?>);

void main() {
  group('the figures survive being saved', () {
    test('rebate and default fee come back off disk', () {
      final out = roundTrip(item('A1', rebate: 400, defaultFee: 25));
      expect(out.rebate, 400);
      expect(out.defaultFee, 25);
    });

    test('a real zero is preserved, not turned back into "unknown"', () {
      // The attached portal report shows Default Fee 0.00 on a paid-up account.
      // That is an answer, and it must not decay into a blank.
      final out = roundTrip(item('A1', rebate: 400, defaultFee: 0));
      expect(out.defaultFee, 0);
      expect(out.defaultFee, isNotNull);
    });

    test('an unsubmitted list stays unknown rather than becoming zero', () {
      final out = roundTrip(item('A1'));
      expect(out.rebate, isNull);
      expect(out.defaultFee, isNull);
    });

    test('an unsubmitted item writes no rebate keys at all', () {
      // Keeps lists prepared by older builds byte-identical, so adding these
      // fields cannot change a stored lot that predates them.
      final json = item('A1').toJson();
      expect(json.containsKey('rb'), isFalse);
      expect(json.containsKey('df'), isFalse);
    });

    test('a lot saved by an OLDER build still loads', () {
      final legacy = {'a': 'A1', 'n': 'Sita Devi', 'd': 1000, 'i': 1};
      final out = LotItem.fromJson(legacy);
      expect(out.accountNumber, 'A1');
      expect(out.rebate, isNull);
      expect(out.defaultFee, isNull);
    });

    test('copyWith carries them, and does not wipe them when omitted', () {
      final withFees = item('A1', rebate: 400, defaultFee: 25);
      expect(withFees.copyWith(installments: 3).rebate, 400);
      expect(withFees.copyWith(installments: 3).defaultFee, 25);
      expect(withFees.copyWith(rebate: 500).rebate, 500);
    });
  });

  group('list totals', () {
    test('rebate and default fee total across the list', () {
      final l = lotOf([
        item('A1', rebate: 400, defaultFee: 0),
        item('A2', rebate: 150, defaultFee: 30),
      ]);
      expect(l.totalRebate, 550);
      expect(l.totalDefaultFee, 30);
    });

    test('an unknown line contributes nothing rather than breaking the sum', () {
      final l = lotOf([item('A1', rebate: 400), item('A2')]);
      expect(l.totalRebate, 400);
      expect(l.totalDefaultFee, 0);
    });

    test('hasPortalFigures is false until the portal has answered', () {
      expect(lotOf([item('A1'), item('A2')]).hasPortalFigures, isFalse);
    });

    test('one answered line is enough to print the totals', () {
      // A part-submitted list should show what is known, not hide all of it.
      expect(lotOf([item('A1', rebate: 400), item('A2')]).hasPortalFigures,
          isTrue);
    });

    test('a zero answer still counts as the portal having answered', () {
      expect(lotOf([item('A1', rebate: 0, defaultFee: 0)]).hasPortalFigures,
          isTrue);
    });

    test('the gross deposit total ignores fees', () {
      final l = lotOf([item('A1', inst: 12, rebate: 400, defaultFee: 0)]);
      expect(l.totalAmount, 12000);
    });
  });

  _downloadsGrouping();

  group('what he actually hands over', () {
    test('rebate comes off — the reference report case', () {
      // 12 x 1000 = 12,000 deposit, 400 rebate, so 11,600 changes hands.
      final l = lotOf([item('A1', inst: 12, rebate: 400, defaultFee: 0)]);
      expect(l.totalNetAmount, 11600);
    });

    test('default fee goes ON, it does not come off', () {
      // The sign that matters: a defaulter pays MORE. Getting this backwards
      // would under-collect at the counter.
      final l = lotOf([item('A1', inst: 1, rebate: 0, defaultFee: 30)]);
      expect(l.totalNetAmount, 1030);
    });

    test('a rebate and a fee on the same line net correctly', () {
      final l = lotOf([item('A1', inst: 12, rebate: 400, defaultFee: 30)]);
      expect(l.totalNetAmount, 11630);
    });

    test('an unsubmitted list nets to its gross deposit', () {
      // No portal figures yet, so nothing to add or take off — never zero.
      final l = lotOf([item('A1', inst: 12)]);
      expect(l.totalNetAmount, 12000);
    });

    test('mixed submitted and unsubmitted lines still total', () {
      final l = lotOf([
        item('A1', inst: 12, rebate: 400),
        item('A2', inst: 1),
      ]);
      expect(l.totalNetAmount, 11600 + 1000);
    });
  });
}

/// The Downloads tab grouped on `createdAt` and relied on incidental ordering,
/// so a list built Thursday and submitted today filed under Thursday, and
/// today's batch could sit below last week's.
void _downloadsGrouping() {
  Lot lot(String ref, DateTime created, {DateTime? submitted}) => Lot(
        createdAt: created,
        mode: 'Cash',
        items: [item('A1')],
        referenceNumber: ref,
        submittedAt: submitted,
      );

  group('Downloads grouping', () {
    test('files under the day it was SUBMITTED, not created', () {
      final l = lot('C1', DateTime(2026, 8, 13, 9),
          submitted: DateTime(2026, 8, 16, 14));
      expect(l.filedDayLabel, '16-Aug-2026');
    });

    test('falls back to creation when never submitted', () {
      final l = Lot(
          createdAt: DateTime(2026, 8, 13, 9), mode: 'Cash', items: [item('A1')]);
      expect(l.filedDayLabel, '13-Aug-2026');
    });

    test('newest day first, regardless of input order', () {
      final groups = Lot.groupByDay([
        lot('C_OLD', DateTime(2026, 8, 10), submitted: DateTime(2026, 8, 10, 9)),
        lot('C_NEW', DateTime(2026, 8, 16), submitted: DateTime(2026, 8, 16, 9)),
      ]);
      expect(groups.first.day, '16-Aug-2026');
      expect(groups.last.day, '10-Aug-2026');
    });

    test('two batches on one day stay in one group, newest first', () {
      final groups = Lot.groupByDay([
        lot('C_AM', DateTime(2026, 8, 16), submitted: DateTime(2026, 8, 16, 9)),
        lot('C_PM', DateTime(2026, 8, 16), submitted: DateTime(2026, 8, 16, 17)),
      ]);
      expect(groups, hasLength(1));
      expect(groups.first.lots.first.referenceNumber, 'C_PM');
    });

    test('Today and Yesterday read as words, older as a date', () {
      final now = DateTime(2026, 8, 16, 12);
      expect(Lot.relativeDay(DateTime(2026, 8, 16, 9), now), 'Today');
      expect(Lot.relativeDay(DateTime(2026, 8, 15, 23), now), 'Yesterday');
      expect(Lot.relativeDay(DateTime(2026, 8, 10), now), '10-Aug-2026');
    });

    test('an empty list groups to nothing', () {
      expect(Lot.groupByDay(const []), isEmpty);
    });
  });
}
