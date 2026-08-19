import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/data/collection_repository.dart';
import 'package:dop_collect/models/collection.dart';

/// Correcting a mistyped figure used to mean delete-and-re-add, which stamped
/// the correction's time onto the customer's khata and could move the payment
/// into a different cycle. These lock in that `update` fixes the number and
/// nothing else.
void main() {
  late MemoryCollectionRepository repo;
  late Collection saved;

  final atTheDoor = DateTime(2026, 8, 20, 0, 34);

  setUp(() async {
    repo = MemoryCollectionRepository();
    saved = await repo.add(Collection(
      accountNumber: '020020081166',
      amount: 167,
      collectedAt: atTheDoor,
      cycleYm: Collection.cycleOf(atTheDoor),
    ));
  });

  test('the figure changes', () async {
    await repo.update(saved.copyWith(amount: 200));
    final rows = await repo.forAccount('020020081166');
    expect(rows.single.amount, 200);
  });

  test('the door time and the cycle do NOT move', () async {
    // The whole reason this exists rather than delete-and-re-add.
    await repo.update(saved.copyWith(amount: 200));
    final row = (await repo.forAccount('020020081166')).single;
    expect(row.collectedAt, atTheDoor);
    expect(row.cycleYm, '2026-08');
    expect(row.id, saved.id);
  });

  test('a correction cannot be smuggled into another cycle', () async {
    // copyWith deliberately refuses to carry a new date, so even a caller that
    // builds one by hand and passes it through update() is ignored.
    final tampered = Collection(
      id: saved.id,
      accountNumber: saved.accountNumber,
      amount: 999,
      collectedAt: DateTime(2026, 9, 1),
      cycleYm: '2026-09',
    );
    await repo.update(tampered);
    final row = (await repo.forAccount('020020081166')).single;
    expect(row.amount, 999, reason: 'the figure is the one thing that moves');
    expect(row.cycleYm, '2026-08');
    expect(row.collectedAt, atTheDoor);
  });

  test('installments can be corrected too', () async {
    await repo.update(saved.copyWith(amount: 6000, installments: 3));
    final row = (await repo.forAccount('020020081166')).single;
    expect(row.installments, 3);
  });

  test('correcting a row that is gone is a no-op, not a crash', () async {
    await repo.remove(saved.id!);
    await repo.update(saved.copyWith(amount: 500));
    expect(await repo.forAccount('020020081166'), isEmpty);
  });

  group('a backdated add belongs to the day it was made for', () {
    // The khata calendar lets a visit be keyed in days later. The figure is
    // whatever he types, but the DATE decides which month's total it joins —
    // stamping it with today would quietly move a July payment into August.
    test('the cycle comes off the chosen date, not today', () async {
      final chosen = DateTime(2026, 7, 15, 9, 30);
      final saved = await repo.add(Collection(
        accountNumber: '020013913225',
        amount: 3000,
        collectedAt: chosen,
        cycleYm: Collection.cycleOf(chosen),
      ));
      expect(saved.cycleYm, '2026-07');

      final july = await repo.forCycle('2026-07');
      expect(july.map((c) => c.id), contains(saved.id));
      expect(await repo.forCycle('2026-08'),
          isNot(contains(saved)),
          reason: 'a July payment must not surface in August');
    });

    test('paying ahead is carried as installments, not just rupees', () async {
      // Three months in one handover. Recording it as one installment would
      // understate the RD even though the money is right.
      final at = DateTime(2026, 7, 15, 9, 30);
      final saved = await repo.add(Collection(
        accountNumber: '020013913225',
        amount: 9000,
        collectedAt: at,
        cycleYm: Collection.cycleOf(at),
        installments: 3,
      ));
      final row = (await repo.forAccount('020013913225'))
          .firstWhere((c) => c.id == saved.id);
      expect(row.installments, 3);
      expect(row.amount, 9000);
    });
  });
}
