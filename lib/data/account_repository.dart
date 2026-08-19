import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/rd_account.dart';
import 'database.dart';
import 'portal/agent_detail_parser.dart';

/// Start of the window in which a closed account is still shown under
/// Settings → Matured Accounts: exactly one calendar month back from [now].
///
/// One month, not forever. A matured account is worth seeing for a little while
/// — the agent still has a passbook to hand over and a last payment to settle,
/// and he wants to check what the customer paid in. After that it is history,
/// and a "closed" list that only ever grows is just a second, stale book.
///
/// Calendar month rather than 30 days so it means what the agent means: closed
/// on the 3rd, visible until the 3rd of next month, whatever the month's
/// length. `DateTime` normalises an overflowing day itself (31 Mar - 1 month
/// reads as 3 Mar), which errs towards showing the account a day or two longer
/// — the harmless direction.
DateTime maturedFrom(DateTime now) =>
    DateTime(now.year, now.month - 1, now.day);

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

  /// Persist the agent's walking order (`accountNumber -> position`). Written
  /// as one transaction when he finishes rearranging his round.
  Future<void> setRouteOrder(Map<String, int> positions);

  /// Set (or clear, with null) how much this customer hands over per visit.
  /// Null means a monthly payer who gives the whole installment at once.
  Future<void> setDailyAmount(String accountNumber, int? amount);

  /// Bulk-store ASLAAS numbers harvested off the portal
  /// (`accountNumber -> aslaas`). Returns how many rows were written.
  Future<int> applyAslaas(Map<String, String> byAccount);

  /// Merge a fresh portal list into the store — the entry point a Sync calls.
  /// Core fields (name, denomination, months paid, next due) are updated from
  /// the portal; locally-held state the list parse does NOT carry — collection
  /// [status], the ASLAAS number, and Deep-Sync detail (opening date, totals,
  /// last-deposit) — is preserved.
  ///
  /// Accounts absent from the fetch are NEVER deleted. What happens to them
  /// depends on [complete]:
  ///
  ///   * `complete: false` (the default, and what a partial or stalled walk
  ///     passes) — they are left exactly as they were. A dropped session holds
  ///     only a prefix of the book, so absence there means nothing at all.
  ///   * `complete: true` — the walk started at page 1 and read every page the
  ///     portal advertised, so absence is real: the account has matured and
  ///     closed, or been transferred. Those rows are STAMPED closed (see
  ///     [RdAccount.closedAt]) rather than removed, because `collections` holds
  ///     money the agent actually took at that door.
  ///
  /// An account that reappears is un-closed — a portal that briefly hid a row
  /// must not cost the agent a customer.
  ///
  /// Returns the accounts closed by THIS call (empty unless [complete]), so the
  /// caller can tell the agent what just left his book.
  Future<List<RdAccount>> replaceAll(List<RdAccount> accounts,
      {bool complete = false});

  /// Accounts closed on or after [from], newest closure first. Backs the
  /// Settings → Matured Accounts list; see [maturedFrom] for the window.
  Future<List<RdAccount>> maturedSince(DateTime from);

  /// Live accounts only.
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
    // Live accounts only. Every caller — the Home totals, the bucket filters,
    // the collect round, the Deep Sync worklist — is asking about the book the
    // agent still works, not the one he used to.
    final rows = await db.query('accounts',
        where: 'closed_at IS NULL', orderBy: 'next_due_date ASC');
    return rows.map(RdAccount.fromMap).toList();
  }

  @override
  Future<List<RdAccount>> search(String query) async {
    final db = await _db.database;
    final q = '%${query.trim()}%';
    final rows = await db.query(
      'accounts',
      where: 'closed_at IS NULL AND '
          '(customer_name LIKE ? OR account_number LIKE ?)',
      whereArgs: [q, q],
      orderBy: 'next_due_date ASC',
    );
    return rows.map(RdAccount.fromMap).toList();
  }

  /// Deliberately finds CLOSED accounts too. This is what the Matured Accounts
  /// list and the ledger's account lookups resolve through — a customer whose
  /// account closed still has a khata full of real payments to show.
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
  Future<void> setRouteOrder(Map<String, int> positions) async {
    if (positions.isEmpty) return;
    final db = await _db.database;
    await db.transaction((txn) async {
      for (final e in positions.entries) {
        await txn.update('accounts', {'route_order': e.value},
            where: 'account_number = ?', whereArgs: [e.key]);
      }
    });
  }

  @override
  Future<void> setDailyAmount(String accountNumber, int? amount) async {
    final db = await _db.database;
    await db.update(
      'accounts',
      {'daily_amount': amount == null || amount <= 0 ? null : amount},
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
  Future<List<RdAccount>> replaceAll(List<RdAccount> accounts,
      {bool complete = false}) async {
    final db = await _db.database;
    final closed = <RdAccount>[];
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
          // Nor his route order or a customer's daily amount — those are the
          // agent's own field settings and exist nowhere on the portal, so a
          // sync that dropped them would silently undo his whole round order.
          map['route_order'] = old['route_order'] ?? map['route_order'];
          map['daily_amount'] = old['daily_amount'] ?? map['daily_amount'];
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
        // Present on the portal = live, full stop. An account that reappears
        // after a closure (a portal that briefly dropped a row, an account
        // reopened at the counter) is un-closed here, so a wrong closure costs
        // the agent one sync, not a customer.
        map['closed_at'] = null;
        batch.insert('accounts', map,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // Only a finished walk can conclude anything from absence. See the
      // interface doc: a short read holds a prefix of the book, so treating a
      // missing account as closed there would wipe out most of it.
      if (complete) {
        final seen = {for (final a in accounts) a.accountNumber};
        final now = DateTime.now();
        for (final row in existing.values) {
          final number = row['account_number'] as String;
          if (seen.contains(number)) continue;
          if (row['closed_at'] != null) continue; // already closed, keep the date
          batch.update(
            'accounts',
            {
              'closed_at': now.toIso8601String(),
              // Drop the short code. A complete sync renumbers the surviving
              // book 1..N, so a closed account holding its old serial would
              // answer to the same "#47" as a live customer — and `serialHint`
              // would jump Deep Sync to the wrong portal page.
              'serial': 0,
            },
            where: 'account_number = ?',
            whereArgs: [number],
          );
          closed.add(RdAccount.fromMap(
              {...row, 'closed_at': now.toIso8601String(), 'serial': 0}));
        }
      }
      await batch.commit(noResult: true);
    });
    return closed;
  }

  @override
  Future<List<RdAccount>> maturedSince(DateTime from) async {
    final db = await _db.database;
    final rows = await db.query(
      'accounts',
      where: 'closed_at IS NOT NULL AND closed_at >= ?',
      whereArgs: [from.toIso8601String()],
      orderBy: 'closed_at DESC',
    );
    return rows.map(RdAccount.fromMap).toList();
  }

  @override
  Future<int> count() async {
    final db = await _db.database;
    final r = await db
        .rawQuery('SELECT COUNT(*) c FROM accounts WHERE closed_at IS NULL');
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

  /// Live accounts, in due-date order — the SQLite store's `all()` filters
  /// `closed_at IS NULL`, and the preview must not disagree with it.
  List<RdAccount> get _sorted => [..._items.where((a) => !a.isClosed)]
    ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));

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

  /// copyWith can't null a field out, so clearing one means rebuilding the row.
  /// Every nullable field is listed here — miss one and clearing an ASLAAS
  /// would silently wipe the customer's daily amount too.
  RdAccount _rebuild(
    RdAccount a, {
    String? aslaas,
    int? routeOrder,
    int? dailyAmount,
  }) =>
      RdAccount(
        accountNumber: a.accountNumber,
        customerName: a.customerName,
        denominationAmount: a.denominationAmount,
        nextDueDate: a.nextDueDate,
        monthsPaid: a.monthsPaid,
        serial: a.serial,
        status: a.status,
        aslaas: aslaas,
        routeOrder: routeOrder,
        dailyAmount: dailyAmount,
        openingDate: a.openingDate,
        totalDeposit: a.totalDeposit,
        pendingInstallments: a.pendingInstallments,
        defaultInstallments: a.defaultInstallments,
        lastDepositDate: a.lastDepositDate,
        closedAt: a.closedAt,
      );

  @override
  Future<void> setAslaas(String accountNumber, String? aslaas) async {
    final i = _items.indexWhere((a) => a.accountNumber == accountNumber);
    if (i == -1) return;
    final v = aslaas?.trim() ?? '';
    final a = _items[i];
    _items[i] = _rebuild(a,
        aslaas: v.isEmpty ? null : v,
        routeOrder: a.routeOrder,
        dailyAmount: a.dailyAmount);
  }

  @override
  Future<void> setRouteOrder(Map<String, int> positions) async {
    for (final e in positions.entries) {
      final i = _items.indexWhere((a) => a.accountNumber == e.key);
      if (i == -1) continue;
      _items[i] = _items[i].copyWith(routeOrder: e.value);
    }
  }

  @override
  Future<void> setDailyAmount(String accountNumber, int? amount) async {
    final i = _items.indexWhere((a) => a.accountNumber == accountNumber);
    if (i == -1) return;
    final a = _items[i];
    _items[i] = _rebuild(a,
        aslaas: a.aslaas,
        routeOrder: a.routeOrder,
        dailyAmount: amount == null || amount <= 0 ? null : amount);
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
  Future<List<RdAccount>> replaceAll(List<RdAccount> accounts,
      {bool complete = false}) async {
    for (final a in accounts) {
      final i = _items.indexWhere((x) => x.accountNumber == a.accountNumber);
      if (i == -1) {
        _items.add(a);
      } else {
        // Preserve status + detail + serial the same way the SQLite store does.
        // `a` comes off the portal with closedAt null, and copyWith is never
        // handed one here — so a reappearing account is un-closed, matching the
        // SQLite store's explicit `closed_at = null`.
        final old = _items[i];
        _items[i] = a.copyWith(
          status: old.status,
          serial: a.serial == 0 ? old.serial : a.serial,
          aslaas: old.aslaas,
          routeOrder: old.routeOrder,
          dailyAmount: old.dailyAmount,
          openingDate: old.openingDate,
          totalDeposit: old.totalDeposit,
          pendingInstallments: old.pendingInstallments,
          defaultInstallments: old.defaultInstallments,
          lastDepositDate: old.lastDepositDate,
        );
      }
    }

    if (!complete) return const [];
    final seen = {for (final a in accounts) a.accountNumber};
    final now = DateTime.now();
    final closed = <RdAccount>[];
    for (var i = 0; i < _items.length; i++) {
      final a = _items[i];
      if (seen.contains(a.accountNumber) || a.isClosed) continue;
      _items[i] = a.copyWith(closedAt: now, serial: 0);
      closed.add(_items[i]);
    }
    return closed;
  }

  @override
  Future<List<RdAccount>> maturedSince(DateTime from) async =>
      [..._items.where((a) => a.isClosed && !a.closedAt!.isBefore(from))]
        ..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));

  @override
  Future<int> count() async => _items.where((a) => !a.isClosed).length;

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
