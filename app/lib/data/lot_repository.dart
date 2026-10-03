import '../models/lot.dart';
import 'database.dart';
import 'sync_ids.dart';

/// Storage for saved collection lists (lots). Screens depend on this interface;
/// SQLite on device, in-memory for the web preview.
abstract class LotRepository {
  Future<List<Lot>> all();
  Future<Lot> save(Lot lot);
  Future<void> update(Lot lot); // persist edits (e.g. removed accounts)
  Future<void> delete(int id);
}

class SqfliteLotRepository implements LotRepository {
  SqfliteLotRepository(this._db);
  final AppDatabase _db;

  @override
  Future<List<Lot>> all() async {
    final db = await _db.database;
    final rows = await db.query('lots',
        where: 'deleted = 0', orderBy: 'created_at DESC');
    return rows.map(Lot.fromMap).toList();
  }

  @override
  Future<Lot> save(Lot lot) async {
    final db = await _db.database;
    // `uid` is this list's identity on the agent's other device, stamped once.
    final id = await db.insert('lots', {
      ...lot.toMap(),
      'uid': newUid(),
      'updated_at': syncStamp(),
      'deleted': 0,
    });
    return lot.copyWith(id: id);
  }

  @override
  Future<void> update(Lot lot) async {
    if (lot.id == null) return;
    final db = await _db.database;
    // `lot.toMap()` carries no `uid`, and sqflite only writes the keys it is
    // given — so the identity the other device knows this row by survives an
    // edit. Do not "helpfully" add uid to the map.
    await db.update(
      'lots',
      {...lot.toMap(), 'updated_at': syncStamp()},
      where: 'id = ?',
      whereArgs: [lot.id],
    );
  }

  @override
  Future<void> delete(int id) async {
    final db = await _db.database;
    // Tombstone — see the note on `SqfliteCollectionRepository.remove`. A list
    // deleted on the phone has to disappear from the desktop too, and a row
    // that is gone cannot say so.
    await db.update(
      'lots',
      {'deleted': 1, 'updated_at': syncStamp()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

class MemoryLotRepository implements LotRepository {
  final List<Lot> _items = [];
  int _seq = 0;

  @override
  Future<List<Lot>> all() async =>
      [..._items]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<Lot> save(Lot lot) async {
    final saved = lot.copyWith(id: ++_seq);
    _items.add(saved);
    return saved;
  }

  @override
  Future<void> update(Lot lot) async {
    final i = _items.indexWhere((l) => l.id == lot.id);
    if (i != -1) _items[i] = lot;
  }

  @override
  Future<void> delete(int id) async =>
      _items.removeWhere((l) => l.id == id);
}
