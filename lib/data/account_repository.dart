import 'package:sqflite/sqflite.dart';

import '../models/rd_account.dart';
import 'database.dart';
import 'portal/agent_detail_parser.dart';

/// Read/write access to RD accounts. Screens depend on this interface only, so
/// the storage backend (SQLite on device, in-memory for the web preview) and
/// the Phase-2 portal sync can change without touching the UI.
abstract class AccountRepository {
  Future<List<RdAccount>> all();
  Future<List<RdAccount>> search(String query);
  Future<RdAccount?> byAccountNumber(String accountNumber);
  Future<void> setStatus(String accountNumber, CollectionStatus status);

  /// Wholesale replace — the entry point a portal Sync will call.
  Future<void> replaceAll(List<RdAccount> accounts);
  Future<int> count();

  /// Merge per-account detail (Deep Sync) into an existing account.
  Future<void> applyDetail(AccountDetail d);
}

/// SQLite-backed store used on the real (Android) app. Offline-first.
class SqfliteAccountRepository implements AccountRepository {
  SqfliteAccountRepository(this._db);
  final AppDatabase _db;

  @override
  Future<List<RdAccount>> all() async {
    final db = await _db.database;
    final rows = await db.query('accounts', orderBy: 'next_due_date ASC');
    return rows.map(RdAccount.fromMap).toList();
  }

  @override
  Future<List<RdAccount>> search(String query) async {
    final db = await _db.database;
    final q = '%${query.trim()}%';
    final rows = await db.query(
      'accounts',
      where: 'customer_name LIKE ? OR account_number LIKE ?',
      whereArgs: [q, q],
      orderBy: 'next_due_date ASC',
    );
    return rows.map(RdAccount.fromMap).toList();
  }

  @override
  Future<RdAccount?> byAccountNumber(String accountNumber) async {
    final db = await _db.database;
    final rows = await db.query(
      'accounts',
      where: 'account_number = ?',
      whereArgs: [accountNumber],
      limit: 1,
    );
    return rows.isEmpty ? null : RdAccount.fromMap(rows.first);
  }

  @override
  Future<void> setStatus(String accountNumber, CollectionStatus status) async {
    final db = await _db.database;
    await db.update(
      'accounts',
      {'status': status.name},
      where: 'account_number = ?',
      whereArgs: [accountNumber],
    );
  }

  @override
  Future<void> replaceAll(List<RdAccount> accounts) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete('accounts');
      final batch = txn.batch();
      for (final a in accounts) {
        batch.insert('accounts', a.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<int> count() async {
    final db = await _db.database;
    final r = await db.rawQuery('SELECT COUNT(*) c FROM accounts');
    return (r.first['c'] as num).toInt();
  }

  @override
  Future<void> applyDetail(AccountDetail d) async {
    final db = await _db.database;
    await db.update(
      'accounts',
      {
        'opening_date': d.openingDate?.toIso8601String(),
        'total_deposit': d.totalDeposit,
        'pending_installments': d.pendingInstallments,
        'default_installments': d.defaultInstallments,
        'last_deposit_date': d.lastDepositDate?.toIso8601String(),
      },
      where: 'account_number = ?',
      whereArgs: [d.accountNumber],
    );
  }
}

/// In-memory store for the browser preview (sqflite has no web backend).
/// Same semantics, no persistence.
class MemoryAccountRepository implements AccountRepository {
  final List<RdAccount> _items = [];

  List<RdAccount> get _sorted =>
      [..._items]..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));

  @override
  Future<List<RdAccount>> all() async => _sorted;

  @override
  Future<List<RdAccount>> search(String query) async {
    final q = query.trim().toLowerCase();
    return _sorted
        .where((a) =>
            a.customerName.toLowerCase().contains(q) ||
            a.accountNumber.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<RdAccount?> byAccountNumber(String accountNumber) async {
    for (final a in _items) {
      if (a.accountNumber == accountNumber) return a;
    }
    return null;
  }

  @override
  Future<void> setStatus(String accountNumber, CollectionStatus status) async {
    final i = _items.indexWhere((a) => a.accountNumber == accountNumber);
    if (i != -1) _items[i] = _items[i].copyWith(status: status);
  }

  @override
  Future<void> replaceAll(List<RdAccount> accounts) async {
    _items
      ..clear()
      ..addAll(accounts);
  }

  @override
  Future<int> count() async => _items.length;

  @override
  Future<void> applyDetail(AccountDetail d) async {
    final i = _items.indexWhere((a) => a.accountNumber == d.accountNumber);
    if (i != -1) {
      _items[i] = _items[i].copyWith(
        openingDate: d.openingDate,
        totalDeposit: d.totalDeposit,
        pendingInstallments: d.pendingInstallments,
        defaultInstallments: d.defaultInstallments,
        lastDepositDate: d.lastDepositDate,
      );
    }
  }
}
