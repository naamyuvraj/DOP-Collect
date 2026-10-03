import '../models/collection.dart';
import 'database.dart';
import 'sync_ids.dart';

/// The field collection ledger.
///
/// Append, correct, and delete. This was append-and-delete only, on the
/// argument that a re-recorded entry reads as what actually happened at the
/// door. In practice a mistyped figure discovered days later could only be
/// fixed by deleting and re-adding, which stamped the correction's time onto
/// the customer's khata and moved the entry to today. [update] exists so the
/// figure can be corrected while the door time and cycle stay put — the
/// history stays honest, only the number moves.
abstract class CollectionRepository {
  /// Record one handover. Returns the stored row (with its id) so the UI can
  /// offer Undo without re-reading.
  Future<Collection> add(Collection c);

  /// Undo — drop a single recorded handover.
  Future<void> remove(int id);

  /// Correct a recorded handover's figure. Only [Collection.amount] and
  /// [Collection.installments] may change; the row keeps its id, its
  /// `collected_at` and its cycle, so a correction can never silently move a
  /// payment into a different month.
  Future<void> update(Collection c);

  /// Every handover in a cycle (`yyyy-MM`), newest first.
  Future<List<Collection>> forCycle(String cycleYm);

  /// One customer's full history, newest first — the per-account log.
  Future<List<Collection>> forAccount(String accountNumber);

  /// Everything taken on one calendar day — what's in the bag tonight.
  Future<List<Collection>> forDay(DateTime day);
}

class SqfliteCollectionRepository implements CollectionRepository {
  SqfliteCollectionRepository(this._db);
  final AppDatabase _db;

  /// Every read is about money the agent actually took, so every read hides
  /// tombstones. Kept as one constant rather than repeated inline: a query that
  /// forgot it would resurrect an entry the agent had already undone, and it
  /// would look exactly like a real one.
  static const _live = 'deleted = 0';

  @override
  Future<Collection> add(Collection c) async {
    final db = await _db.database;
    // `uid` is stamped HERE and never again — it is this row's identity on the
    // agent's other device for as long as the row exists. See [newUid].
    final id = await db.insert('collections', {
      ...c.toMap(),
      'uid': newUid(),
      'updated_at': syncStamp(),
      'deleted': 0,
    });
    return c.copyWith(id: id);
  }

  @override
  Future<void> remove(int id) async {
    final db = await _db.database;
    // A tombstone, not a DELETE. The row has to survive long enough to tell the
    // agent's other device that this handover was undone; a row that is simply
    // gone says nothing, and the desktop would go on showing cash he told the
    // phone he never took.
    //
    // `updated_at` moving is what makes the delete travel at all — the push
    // selects on it, so an undo is just another change.
    await db.update(
      'collections',
      {'deleted': 1, 'updated_at': syncStamp()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> update(Collection c) async {
    assert(c.id != null, 'cannot correct an unsaved collection');
    final db = await _db.database;
    // Only the figure. Writing the whole map would let a caller move
    // collected_at or cycle_ym by accident — and would overwrite `uid`, which
    // must never change once the other device has seen it.
    await db.update(
      'collections',
      {
        'amount': c.amount,
        'installments': c.installments,
        'updated_at': syncStamp(),
      },
      where: 'id = ?',
      whereArgs: [c.id],
    );
  }

  @override
  Future<List<Collection>> forCycle(String cycleYm) async {
    final db = await _db.database;
    final rows = await db.query('collections',
        where: 'cycle_ym = ? AND $_live',
        whereArgs: [cycleYm],
        orderBy: 'collected_at DESC');
    return rows.map(Collection.fromMap).toList();
  }

  @override
  Future<List<Collection>> forAccount(String accountNumber) async {
    final db = await _db.database;
    final rows = await db.query('collections',
        where: 'account_number = ? AND $_live',
        whereArgs: [accountNumber],
        orderBy: 'collected_at DESC');
    return rows.map(Collection.fromMap).toList();
  }

  @override
  Future<List<Collection>> forDay(DateTime day) async {
    final db = await _db.database;
    // Half-open [start, next day) so it can't miss a 23:59 entry to rounding.
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await db.query('collections',
        where: 'collected_at >= ? AND collected_at < ? AND $_live',
        whereArgs: [start.toIso8601String(), end.toIso8601String()],
        orderBy: 'collected_at DESC');
    return rows.map(Collection.fromMap).toList();
  }
}

/// In-memory ledger for the browser preview (sqflite has no web backend).
class MemoryCollectionRepository implements CollectionRepository {
  final List<Collection> _items = [];
  int _seq = 0;

  List<Collection> _sorted(Iterable<Collection> src) =>
      [...src]..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));

  @override
  Future<Collection> add(Collection c) async {
    final saved = c.copyWith(id: ++_seq);
    _items.add(saved);
    return saved;
  }

  @override
  Future<void> remove(int id) async => _items.removeWhere((c) => c.id == id);

  @override
  Future<void> update(Collection c) async {
    final i = _items.indexWhere((e) => e.id == c.id);
    if (i == -1) return;
    _items[i] = _items[i]
        .copyWith(amount: c.amount, installments: c.installments);
  }

  @override
  Future<List<Collection>> forCycle(String cycleYm) async =>
      _sorted(_items.where((c) => c.cycleYm == cycleYm));

  @override
  Future<List<Collection>> forAccount(String accountNumber) async =>
      _sorted(_items.where((c) => c.accountNumber == accountNumber));

  @override
  Future<List<Collection>> forDay(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return _sorted(_items.where((c) =>
        !c.collectedAt.isBefore(start) && c.collectedAt.isBefore(end)));
  }
}
