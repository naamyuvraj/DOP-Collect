import 'package:sqflite_sqlcipher/sqflite.dart';

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

  /// Set (or clear, with null/empty) one account's own ASLAAS number.
  Future<void> setAslaas(String accountNumber, String? aslaas);

  /// Bulk-store ASLAAS numbers harvested off the portal
  /// (`accountNumber -> aslaas`). Returns how many rows were written.
  Future<int> applyAslaas(Map<String, String> byAccount);

  /// Merge a fresh portal list into the store — the entry point a Sync calls.
  /// Core fields (name, denomination, months paid, next due) are updated from
  /// the portal; locally-held state the list parse does NOT carry — collection
  /// [status], the ASLAAS number, and Deep-Sync detail (opening date, totals,
  /// last-deposit) — is preserved. Accounts absent from a (possibly partial) sync are kept, never
  /// deleted, so a dropped session can never wipe his data.
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
  Future<void> setAslaas(String accountNumber, String? aslaas) async {
    final db = await _db.database;
    final v = aslaas?.trim();
    await db.update(
      'accounts',
      {'aslaas': v == null || v.isEmpty ? null : v},
      where: 'account_number = ?',
      whereArgs: [accountNumber],
    );
  }

  @override
  Future<int> applyAslaas(Map<String, String> byAccount) async {
    if (byAccount.isEmpty) return 0;
    final db = await _db.database;
    var written = 0;
    await db.transaction((txn) async {
      for (final e in byAccount.entries) {
        final v = e.value.trim();
        if (v.isEmpty) continue;
        written += await txn.update(
          'accounts',
          {'aslaas': v},
          where: 'account_number = ?',
          whereArgs: [e.key],
        );
      }
    });
    return written;
  }

  @override
  Future<void> replaceAll(List<RdAccount> accounts) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      // Preload existing rows so we can preserve status + detail on merge.
      final existing = <String, Map<String, Object?>>{
        for (final r in await txn.query('accounts'))
          r['account_number'] as String: r,
      };
      final batch = txn.batch();
      for (final a in accounts) {
        final map = a.toMap();
        final old = existing[a.accountNumber];
        if (old != null) {
          // Keep the collection mark and Deep-Sync detail the portal list
          // doesn't include; keep the old serial if this parse didn't set one.
          map['status'] = old['status'] ?? map['status'];
          // The list parse carries no ASLAAS, so a sync must never blank it.
          map['aslaas'] = old['aslaas'] ?? map['aslaas'];
          map['opening_date'] = old['opening_date'] ?? map['opening_date'];
          map['total_deposit'] = old['total_deposit'] ?? map['total_deposit'];
          map['pending_installments'] =
              old['pending_installments'] ?? map['pending_installments'];
          map['default_installments'] =
              old['default_installments'] ?? map['default_installments'];
          map['last_deposit_date'] =
              old['last_deposit_date'] ?? map['last_deposit_date'];
          final oldSerial = (old['serial'] as num?)?.toInt() ?? 0;
          if (a.serial == 0 && oldSerial != 0) map['serial'] = oldSerial;
        }
        batch.insert('accounts', map,
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
  Future<void> setAslaas(String accountNumber, String? aslaas) async {
    final i = _items.indexWhere((a) => a.accountNumber == accountNumber);
    if (i == -1) return;
    final v = aslaas?.trim() ?? '';
    // copyWith can't null a field out, so rebuild when clearing.
    _items[i] = v.isEmpty
        ? RdAccount(
            accountNumber: _items[i].accountNumber,
            customerName: _items[i].customerName,
            denominationAmount: _items[i].denominationAmount,
            nextDueDate: _items[i].nextDueDate,
            monthsPaid: _items[i].monthsPaid,
            serial: _items[i].serial,
            status: _items[i].status,
            openingDate: _items[i].openingDate,
            totalDeposit: _items[i].totalDeposit,
            pendingInstallments: _items[i].pendingInstallments,
            defaultInstallments: _items[i].defaultInstallments,
            lastDepositDate: _items[i].lastDepositDate,
          )
        : _items[i].copyWith(aslaas: v);
  }

  @override
  Future<int> applyAslaas(Map<String, String> byAccount) async {
    var written = 0;
    for (final e in byAccount.entries) {
      if (e.value.trim().isEmpty) continue;
      final i = _items.indexWhere((a) => a.accountNumber == e.key);
      if (i == -1) continue;
      _items[i] = _items[i].copyWith(aslaas: e.value.trim());
      written++;
    }
    return written;
  }

  @override
  Future<void> replaceAll(List<RdAccount> accounts) async {
    for (final a in accounts) {
      final i = _items.indexWhere((x) => x.accountNumber == a.accountNumber);
      if (i == -1) {
        _items.add(a);
      } else {
        // Preserve status + detail + serial the same way the SQLite store does.
        final old = _items[i];
        _items[i] = a.copyWith(
          status: old.status,
          serial: a.serial == 0 ? old.serial : a.serial,
          aslaas: old.aslaas,
          openingDate: old.openingDate,
          totalDeposit: old.totalDeposit,
          pendingInstallments: old.pendingInstallments,
          defaultInstallments: old.defaultInstallments,
          lastDepositDate: old.lastDepositDate,
        );
      }
    }
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
