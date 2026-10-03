import 'package:dop_collect/models/collection.dart';
import 'package:dop_collect/models/khata.dart';
import 'package:flutter_test/flutter_test.dart';

Collection _c(String isoDay, int amount,
        {String? cycle, int installments = 1, int? id}) =>
    Collection(
      id: id,
      accountNumber: '1234567890',
      amount: amount,
      collectedAt: DateTime.parse(isoDay),
      cycleYm: cycle ?? Collection.cycleOf(DateTime.parse(isoDay)),
      installments: installments,
    );

void main() {
  test('an empty ledger opens no pages, rather than a blank month', () {
    expect(KhataBook.fromCollections(const []), isEmpty);
  });

  test('a monthly payer gets one page with one visit', () {
    final pages = KhataBook.fromCollections([_c('2026-08-05T10:00:00', 15000)]);
    expect(pages, hasLength(1));
    expect(pages.first.total, 15000);
    expect(pages.first.visits, 1);
    expect(pages.first.installments, 1);
    expect(pages.first.byDay, {5: 15000});
  });

  test('a daily payer sums to the month total and keeps every day', () {
    final entries = [
      for (var d = 1; d <= 26; d++)
        _c('2026-08-${d.toString().padLeft(2, '0')}T09:00:00', 500),
    ];
    final page = KhataBook.fromCollections(entries).single;
    expect(page.visits, 26);
    expect(page.total, 26 * 500);
    expect(page.byDay[1], 500);
    expect(page.byDay[26], 500);
    expect(page.byDay.containsKey(27), isFalse);
  });

  test('two handovers on the same day add up on that square', () {
    final page = KhataBook.fromCollections([
      _c('2026-08-05T09:00:00', 300),
      _c('2026-08-05T18:00:00', 200),
    ]).single;
    expect(page.byDay, {5: 500});
    expect(page.visits, 1, reason: 'one day he turned up, not two');
    expect(page.total, 500);
    expect(page.onDay(5), hasLength(2));
  });

  test('pages are newest first and skip months with nothing in them', () {
    final pages = KhataBook.fromCollections([
      _c('2026-06-10T09:00:00', 500),
      _c('2026-08-10T09:00:00', 500), // nothing at all in July
    ]);
    expect(pages.map((p) => p.shortLabel).toList(), ['Aug 2026', 'Jun 2026']);
  });

  test('entries within a page are newest first', () {
    final page = KhataBook.fromCollections([
      _c('2026-08-01T09:00:00', 100),
      _c('2026-08-20T09:00:00', 200),
      _c('2026-08-10T09:00:00', 300),
    ]).single;
    expect(page.entries.map((e) => e.amount).toList(), [200, 300, 100]);
  });

  test('paying ahead counts installments without inflating the visit count', () {
    final page = KhataBook.fromCollections(
        [_c('2026-08-05T09:00:00', 45000, installments: 3)]).single;
    expect(page.installments, 3);
    expect(page.visits, 1);
    expect(page.total, 45000);
  });

  group('a payment booked against another cycle', () {
    test('sits on the day it was taken, not the month it settles', () {
      // Handed over 1 Aug, but it clears July's installment.
      final pages = KhataBook.fromCollections(
          [_c('2026-08-01T09:00:00', 15000, cycle: '2026-07')]);
      expect(pages.single.shortLabel, 'Aug 2026',
          reason: 'the calendar records when cash moved');
      expect(pages.single.byDay, {1: 15000});
    });

    test('is flagged rather than silently misfiled', () {
      final odd = KhataBook.fromCollections(
          [_c('2026-08-01T09:00:00', 15000, cycle: '2026-07')]).single;
      expect(odd.hasOtherCycle, isTrue);

      final normal =
          KhataBook.fromCollections([_c('2026-08-05T09:00:00', 15000)]).single;
      expect(normal.hasOtherCycle, isFalse);
    });
  });

  group('calendar grid maths', () {
    test('August 2026 starts on a Saturday and has 31 days', () {
      final page =
          KhataBook.fromCollections([_c('2026-08-05T09:00:00', 1)]).single;
      expect(page.daysInMonth, 31);
      expect(page.firstWeekday, DateTime.saturday);
    });

    test('February in a leap year has 29', () {
      final page =
          KhataBook.fromCollections([_c('2024-02-05T09:00:00', 1)]).single;
      expect(page.daysInMonth, 29);
    });

    test('February in a normal year has 28', () {
      final page =
          KhataBook.fromCollections([_c('2026-02-05T09:00:00', 1)]).single;
      expect(page.daysInMonth, 28);
    });

    test('December rolls into the next year without breaking', () {
      final page =
          KhataBook.fromCollections([_c('2026-12-31T09:00:00', 1)]).single;
      expect(page.daysInMonth, 31);
      expect(page.label, 'December 2026');
    });
  });

  test('lifetime total spans every page', () {
    final all = [
      _c('2026-06-10T09:00:00', 500),
      _c('2026-07-10T09:00:00', 700),
      _c('2026-08-10T09:00:00', 300),
    ];
    expect(KhataBook.lifetimeTotal(all), 1500);
    final pages = KhataBook.fromCollections(all);
    expect(pages.fold<int>(0, (s, p) => s + p.total), 1500,
        reason: 'the pages must account for every rupee');
  });

  test('a year of daily collecting still groups into 12 pages', () {
    final entries = <Collection>[];
    for (var m = 1; m <= 12; m++) {
      for (var d = 1; d <= 25; d++) {
        entries.add(_c(
            '2026-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}T09:00:00',
            500));
      }
    }
    final pages = KhataBook.fromCollections(entries);
    expect(pages, hasLength(12));
    expect(pages.first.shortLabel, 'Dec 2026');
    expect(pages.fold<int>(0, (s, p) => s + p.total), 12 * 25 * 500);
  });
}
