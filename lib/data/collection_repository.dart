import '../models/collection.dart';
import 'database.dart';

/// The field collection ledger.
///
/// Append and delete only — there is no "update a collection". A wrong entry is
/// removed (the sheet's Undo) and re-recorded, so the log always reads as what
/// actually happened at the door rather than a value someone edited later.
abstract class CollectionRepository {
  /// Record one handover. Returns the stored row (with its id) so the UI can
  /// offer Undo without re-reading.
  Future<Collection> add(Collection c);

  /// Undo — drop a single recorded handover.
  Future<void> remove(int id);

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

  @override
  Future<Collection> add(Collection c) async {
    final db = await _db.database;
    final id = await db.insert('collections', c.toMap());
    return c.copyWith(id: id);
  }

  @override
  Future<void> remove(int id) async {
    final db = await _db.database;
    await db.delete('collections', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<Collection>> forCycle(String cycleYm) async {
    final db = await _db.database;
    final rows = await db.query('collections',
        where: 'cycle_ym = ?', whereArgs: [cycleYm], orderBy: 'collected_at DESC');
    return rows.map(Collection.fromMap).toList();
  }

  @override
  Future<List<Collection>> forAccount(String accountNumber) async {
    final db = await _db.database;
    final rows = await db.query('collections',
        where: 'account_number = ?',
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
        where: 'collected_at >= ? AND collected_at < ?',
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
