import 'dart:math' as math;

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/rd_account.dart';
import 'database.dart';
import 'portal/agent_list_parser.dart';
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
/// length.
///
/// The day is CLAMPED to the target month's length rather than left to
/// `DateTime`'s overflow. `DateTime(2026, 2, 31)` is not 28 February, it is
/// 3 March — LATER than the window should start — so on 30 and 31 March the
/// window began after 1 March, an account closed on the 1st vanished from the
/// list, and then reappeared on 1 April when the window slid back. A month-long
/// window that runs backwards reads as the app losing records.
DateTime maturedFrom(DateTime now) {
  final y = now.month == 1 ? now.year - 1 : now.year;
  final m = now.month == 1 ? 12 : now.month - 1;
  final lastDay = DateTime(y, m + 1, 0).day; // day 0 of next month = this one's
  return DateTime(y, m, now.day > lastDay ? lastDay : now.day);
}

/// What a merge actually did to the book.
///
/// [closed] are the accounts this call stamped closed. [refusedClosures] is the
/// number it declined to close because there were too many of them at once —
/// see [AccountRepository.closureCeiling]. The two are mutually exclusive: a
/// refused merge closes nothing at all.
class MergeReport {
  const MergeReport({this.closed = const [], this.refusedClosures = 0});
  final List<RdAccount> closed;
  final int refusedClosures;

  /// True when the guard fired and the closures were held back.
  bool get refused => refusedClosures > 0;
  static const none = MergeReport();
}

/// Read/write access to RD accounts. Screens depend on this interface only, so
/// the storage backend (SQLite on device, in-memory for the web preview) and
/// the Phase-2 portal sync can change without touching the UI.
abstract class AccountRepository {
  Future<List<RdAccount>> all();
  Future<List<RdAccount>> search(String query);
  Future<RdAccount?> byAccountNumber(String accountNumber);

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
  /// Returns what happened — see [MergeReport].
  Future<MergeReport> replaceAll(List<RdAccount> accounts,
      {bool complete = false});

  /// Most accounts one finished sync may close before the result is treated as
  /// a fault rather than a month of maturities.
  ///
  /// A COMPLETE sync closes everything it did not see, so the correctness of
  /// the whole book rests on the walk having genuinely read every page. That is
  /// a great deal of weight for one boolean to carry, and when it was wrong the
  /// cost was hundreds of customers leaving the book in a single tap. This is
  /// the second line: a real month closes a handful of matured accounts, so
  /// anything on a different scale is a broken sync, not a busy month.
  ///
  /// Five per cent, with a floor of ten so a small book (or a genuinely quiet
  /// one) is not held hostage by a percentage. The asymmetry is the point — a
  /// wrong refusal costs one message and a second Sync, a wrong closure costs
  /// the ledger's only record of who those customers were.
  static int closureCeiling(int liveBefore) =>
      math.max(10, (liveBefore * 0.05).ceil());

  /// Accounts closed on or after [from], newest closure first. Backs the
  /// Settings → Matured Accounts list; see [maturedFrom] for the window.
  Future<List<RdAccount>> maturedSince(DateTime from);

  /// Record accounts the portal still lists but with no next installment due —
  /// they have run their full term. Stored CLOSED, so they show under
  /// Settings → Matured Accounts and are excluded from the round and from
  /// every dashboard total.
  ///
  /// Without this they were counted by the parser and then dropped, so the
  /// book quietly held fewer customers than the portal did and there was
  /// nothing on screen naming which ones were missing. On a first sync into an
  /// empty book they did not even show as closures, because there was nothing
  /// there to close.
  ///
  /// Returns how many rows were newly recorded (an account already live in the
  /// book is left alone — see the implementation for why).
  Future<int> recordMatured(List<MaturedRow> rows, {DateTime? asOf});

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
  Future<MergeReport> replaceAll(List<RdAccount> accounts,
      {bool complete = false}) async {
    final db = await _db.database;
    final closed = <RdAccount>[];
    var refused = 0;
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
        final live =
            existing.values.where((r) => r['closed_at'] == null).toList();
        final missing = [
          for (final row in live)
            if (!seen.contains(row['account_number'] as String)) row
        ];
        // The guard. A month closes a handful of matured accounts; a sync that
        // wants to close a fifth of the book has not found a busy month, it has
        // misread the portal. Close nothing, and let the caller say so.
        if (missing.length > AccountRepository.closureCeiling(live.length)) {
          refused = missing.length;
        } else {
          for (final row in missing) {
            final number = row['account_number'] as String;
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
      }
      await batch.commit(noResult: true);
    });
    return MergeReport(closed: closed, refusedClosures: refused);
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
  Future<int> recordMatured(List<MaturedRow> rows, {DateTime? asOf}) async {
    if (rows.isEmpty) return 0;
    final now = asOf ?? DateTime.now();
    final db = await _db.database;
    var written = 0;
    await db.transaction((txn) async {
      for (final r in rows) {
        final existing = await txn.query('accounts',
            where: 'account_number = ?',
            whereArgs: [r.accountNumber],
            limit: 1);
        if (existing.isNotEmpty) {
          // Already known. Only stamp it closed if it is not already — never
          // move an existing closure date, or a re-sync would keep pushing the
          // account back to the top of Matured Accounts every month.
          if (existing.first['closed_at'] == null) {
            await txn.update(
                'accounts', {'closed_at': now.toIso8601String(), 'serial': 0},
                where: 'account_number = ?', whereArgs: [r.accountNumber]);
            written++;
          }
          continue;
        }
        // New to the book and already matured — the case that used to vanish
        // entirely, because a first sync has nothing to "close".
        //
        // `next_due_date` is set to the closure date rather than invented: the
        // account has no next installment, that is what matured means, and the
        // Matured Accounts screen never renders this field. Storing it closed
        // keeps it out of the round and out of every dashboard total.
        await txn.insert(
            'accounts',
            RdAccount(
              accountNumber: r.accountNumber,
              customerName: r.customerName,
              denominationAmount: r.denominationAmount,
              nextDueDate: now,
              monthsPaid: r.monthsPaid,
              closedAt: now,
            ).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
        written++;
      }
    });
    return written;
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
  Future<MergeReport> replaceAll(List<RdAccount> accounts,
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

    if (!complete) return MergeReport.none;
    final seen = {for (final a in accounts) a.accountNumber};
    final now = DateTime.now();
    final liveCount = _items.where((a) => !a.isClosed).length;
    final missing = [
      for (var i = 0; i < _items.length; i++)
        if (!_items[i].isClosed && !seen.contains(_items[i].accountNumber)) i
    ];
    // The same guard as the SQLite store — the preview must not disagree.
    if (missing.length > AccountRepository.closureCeiling(liveCount)) {
      return MergeReport(refusedClosures: missing.length);
    }
    final closed = <RdAccount>[];
    for (final i in missing) {
      _items[i] = _items[i].copyWith(closedAt: now, serial: 0);
      closed.add(_items[i]);
    }
    return MergeReport(closed: closed);
  }

  @override
  Future<List<RdAccount>> maturedSince(DateTime from) async => [
        ..._items.where((a) => a.isClosed && !a.closedAt!.isBefore(from))
      ]..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));

  @override
  Future<int> recordMatured(List<MaturedRow> rows, {DateTime? asOf}) async {
    final now = asOf ?? DateTime.now();
    var written = 0;
    for (final r in rows) {
      final i = _items.indexWhere((a) => a.accountNumber == r.accountNumber);
      if (i >= 0) {
        if (!_items[i].isClosed) {
          _items[i] = _items[i].copyWith(closedAt: now, serial: 0);
          written++;
        }
        continue;
      }
      _items.add(RdAccount(
        accountNumber: r.accountNumber,
        customerName: r.customerName,
        denominationAmount: r.denominationAmount,
        nextDueDate: now,
        monthsPaid: r.monthsPaid,
        closedAt: now,
      ));
      written++;
    }
    return written;
  }

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
