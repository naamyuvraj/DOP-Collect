import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../data/database.dart';
import 'analytics.dart';
import '../data/session.dart';
import '../data/sync_ids.dart';
import 'supabase_config.dart';

/// What one sync did, for the UI and the logs.
class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.pulled = 0,
    this.ok = true,
    this.code,
    this.message = '',
  });

  final int pushed;
  final int pulled;
  final bool ok;

  /// Machine code from the server: `no_session`, `disabled`, `rate`, or a
  /// local one (`offline`, `not_configured`).
  final String? code;
  final String message;

  bool get changedAnything => pushed > 0 || pulled > 0;

  @override
  String toString() =>
      'SyncReport(ok: $ok, pushed: $pushed, pulled: $pulled, code: $code)';
}

/// Two-way sync of the agent's book with the `sync` edge function.
///
/// WHAT MAKES THIS SAFE TO RUN AT ANY TIME
/// ---------------------------------------
/// Three rules, and every one of them exists because breaking it loses money
/// out of the collections ledger:
///
/// 1. **A row is dirty iff `updated_at` is newer than the last push.** There is
///    no outbox table. An outbox is a second copy of the truth that has to be
///    written in the same transaction as the data, and the day those two
///    disagree is the day a handover silently never leaves the phone.
///
/// 2. **The high-water mark is taken BEFORE the push, from the rows actually
///    sent.** Advancing it to "now" afterwards would swallow anything the agent
///    recorded during the round trip — he takes cash at a door while the
///    request is in flight, and that row is marked as sent without ever having
///    been.
///
/// 3. **Applying a pulled row must not make it dirty.** The write carries the
///    server's own `client_updated_at`, so a row that arrived from the desktop
///    is not immediately pushed back as though this device had edited it. Get
///    this wrong and two devices ping-pong the same row forever.
class CloudSync {
  CloudSync._();

  /// Test seam — every request goes through this, so a test can assert exactly
  /// what reached the wire.
  @visibleForTesting
  static http.Client client = http.Client();

  static Timer? _autoSyncTimer;
  static bool _isSyncing = false;
  static final StreamController<SyncReport> _syncStreamController =
      StreamController<SyncReport>.broadcast();

  /// Stream of sync reports emitted whenever a sync completes.
  static Stream<SyncReport> get syncStream => _syncStreamController.stream;

  /// Start background periodic auto-sync (every 3 minutes).
  static void startAutoSync({Duration interval = const Duration(minutes: 3)}) {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(interval, (_) => triggerAutoSync());
  }

  /// Stop background periodic auto-sync.
  static void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Trigger an auto-sync run if not already running.
  static Future<SyncReport?> triggerAutoSync({Database? db}) async {
    return run(db: db);
  }

  // Both marks are keyed by the agent whose book they describe.
  static String get _suffix {
    final k = AppDatabase.instance.agentKey;
    return k.isEmpty ? '' : '_$k';
  }

  static String get _kCursor => 'sync_cursor$_suffix';
  static String get _kPushed => 'sync_pushed_high_water$_suffix';

  /// Server's cap. Exceeding it is a 413, not a truncation.
  static const _pushChunk = 2000;

  /// Tables, in the order a pull must be applied.
  static const _tables = ['accounts', 'collections', 'lots'];

  static Future<Map<String, dynamic>?> _post(Map<String, Object?> body) async {
    try {
      final res = await client
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/sync'),
            headers: {
              'apikey': SupabaseConfig.anonKey,
              'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return null; // offline, timeout, or a body we cannot read
    }
  }

  /// Push local changes, then pull remote ones. Safe to call repeatedly.
  static Future<SyncReport> run({Database? db}) async {
    if (_isSyncing) {
      return const SyncReport(ok: true, message: 'Sync already in progress.');
    }
    _isSyncing = true;
    try {
      final report = await _run(db);
      if (!_syncStreamController.isClosed) {
        _syncStreamController.add(report);
      }
      return report;
    } catch (e, st) {
      Analytics.error('cloud_sync', 'CloudSync.run failed: $e',
          detail: st.toString(), screen: 'cloud_sync');
      return const SyncReport(
          ok: false, code: 'error', message: 'Sync failed. Try again.');
    } finally {
      _isSyncing = false;
    }
  }

  static Future<SyncReport> _run(Database? db) async {
    if (!SupabaseConfig.configured) {
      return const SyncReport(
          ok: false, code: 'not_configured', message: 'Sync is not set up.');
    }
    final session = await SessionStore.load();
    if (session == null) {
      return const SyncReport(
          ok: false, code: 'no_session', message: 'Sign in to sync.');
    }

    final database = db ?? await AppDatabase.instance.database;
    final prefs = await SharedPreferences.getInstance();

    var totalPushed = 0;
    var totalPulled = 0;

    // ---- Push -------------------------------------------------------------
    final highWater = _readMap(prefs, _kPushed);
    final sending = <String, List<Map<String, Object?>>>{};
    final marks = <String, String>{};

    for (final table in _tables) {
      final since = highWater[table] as String? ?? '';
      final rows = await _dirtyRows(database, table, since);
      if (rows.isEmpty) continue;
      sending[table] = rows;
      // Rule 2: the mark is the newest row we are ACTUALLY sending, read off
      // the batch itself.
      marks[table] = rows
          .map((r) => r['client_updated_at'] as String)
          .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    }

    // Chunked so one enormous first sync cannot trip the server's 413. Each
    // chunk is committed on the server before the next is sent, so an
    // interruption halfway leaves the earlier chunks safely stored.
    while (sending.values.any((r) => r.isNotEmpty)) {
      final batch = <String, List<Map<String, Object?>>>{};
      for (final table in _tables) {
        final rows = sending[table];
        if (rows == null || rows.isEmpty) continue;
        final take = rows.length > _pushChunk ? _pushChunk : rows.length;
        batch[table] = rows.sublist(0, take);
        sending[table] = rows.sublist(take);
      }
      if (batch.isEmpty) break;

      final j = await _post({
        'token': session.token,
        'push': batch,
        // Ask for nothing back on a push-only leg; the pull below does that.
        'limit': 1,
        'cursor': _readMap(prefs, _kCursor),
      });
      final failure = _failure(j);
      if (failure != null) return failure;
      final pushed = (j!['pushed'] as Map?) ?? const {};
      for (final v in pushed.values) {
        totalPushed += (v as num?)?.toInt() ?? 0;
      }
    }

    // Only once every chunk landed. A mark advanced after a partial push would
    // mark unsent rows as sent.
    if (marks.isNotEmpty) {
      highWater.addAll(marks);
      await prefs.setString(_kPushed, jsonEncode(highWater));
    }

    // ---- Pull -------------------------------------------------------------
    // Loops while the server says `more`, so a first sync of a whole book
    // drains in one call to [run] rather than one page per launch.
    var cursor = _readMap(prefs, _kCursor);
    var guard = 0;
    while (true) {
      final j = await _post({
        'token': session.token,
        'cursor': cursor,
      });
      final failure = _failure(j);
      if (failure != null) return failure;

      final pull = (j!['pull'] as Map?) ?? const {};
      var got = 0;
      for (final table in _tables) {
        final rows = (pull[table] as List?)?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];
        if (rows.isEmpty) continue;
        await _apply(database, table, rows);
        got += rows.length;

        // A pulled row is, by definition, already on the server — so the push
        // mark has to move past it or the very next sync sends it straight
        // back. Two devices would then trade the same row forever, each one
        // seeing the other's write as a local edit it had not yet uploaded.
        //
        // This is why the mark is a stamp and not a boolean: the row keeps the
        // server's `client_updated_at`, so "already sent" and "arrived from
        // elsewhere" are the same statement and one comparison covers both.
        final newest = rows
            .map((r) => r['client_updated_at'] as String?)
            .whereType<String>()
            .fold<String?>(
                null, (a, b) => a == null || b.compareTo(a) > 0 ? b : a);
        if (newest != null) {
          final seen = highWater[table] as String?;
          if (seen == null || newest.compareTo(seen) > 0) {
            highWater[table] = newest;
            await prefs.setString(_kPushed, jsonEncode(highWater));
          }
        }
      }
      totalPulled += got;

      cursor = (j['cursor'] as Map?)?.cast<String, dynamic>() ?? cursor;
      await prefs.setString(_kCursor, jsonEncode(cursor));

      if (j['more'] != true) break;
      // The server advances the cursor off the last row of each page, so this
      // terminates on its own. The guard is for the case where it does not —
      // a spinning sync would drain a phone's battery in a pocket, and that is
      // worse than a sync that stops early and retries next time.
      if (++guard > 200) break;
    }

    return SyncReport(pushed: totalPushed, pulled: totalPulled);
  }

  /// A server reply that means "stop", turned into a report. Null = carry on.
  static SyncReport? _failure(Map<String, dynamic>? j) {
    if (j == null) {
      return const SyncReport(
          ok: false, code: 'offline', message: 'No connection.');
    }
    if (j['ok'] == true) return null;
    final code = j['code'] as String?;
    return SyncReport(
      ok: false,
      code: code,
      message: switch (code) {
        'no_session' => 'Signed out. Verify this device again.',
        'disabled' => 'This account is disabled.',
        'rate' => 'Too many syncs just now — try again shortly.',
        'too_many' => 'Too much to send at once.',
        _ => 'Sync failed. Try again.',
      },
    );
  }

  // --- Local reads ---------------------------------------------------------

  /// Rows this device has touched since [since], shaped for the server.
  ///
  /// `updated_at` is sent as `client_updated_at` — the server keeps its own
  /// clock for the pull cursor and uses ours only to settle conflicts.
  static Future<List<Map<String, Object?>>> _dirtyRows(
      Database db, String table, String since) async {
    // A row with no stamp at all predates v12 and has never been pushed.
    final where = since.isEmpty
        ? null
        : '(updated_at IS NULL OR updated_at > ?)';
    final rows = await db.query(
      table,
      where: where,
      whereArgs: since.isEmpty ? null : [since],
      orderBy: 'updated_at ASC',
    );

    return [
      for (final r in rows)
        if (table == 'accounts')
          {
            'account_number': r['account_number'],
            'customer_name': r['customer_name'] ?? '',
            'denomination_amount': r['denomination_amount'] ?? 0,
            'next_due_date': r['next_due_date'],
            'months_paid': r['months_paid'] ?? 0,
            'serial': r['serial'] ?? 0,
            'status': r['status'] ?? 'pending',
            'aslaas': r['aslaas'],
            'opening_date': r['opening_date'],
            'total_deposit': r['total_deposit'],
            'pending_installments': r['pending_installments'],
            'default_installments': r['default_installments'],
            'last_deposit_date': r['last_deposit_date'],
            'route_order': r['route_order'],
            'daily_amount': r['daily_amount'],
            'closed_at': r['closed_at'],
            'deleted': false,
            'client_updated_at': (r['updated_at'] as String?) ?? syncStamp(),
          }
        else if (table == 'collections')
          {
            'uid': r['uid'],
            'account_number': r['account_number'],
            'amount': r['amount'],
            'installments': r['installments'] ?? 1,
            'collected_at': r['collected_at'],
            'cycle_ym': r['cycle_ym'],
            'note': r['note'],
            'deleted': (r['deleted'] as int? ?? 0) == 1,
            'client_updated_at': (r['updated_at'] as String?) ?? syncStamp(),
          }
        else
          {
            'uid': r['uid'],
            'created_at': r['created_at'],
            'mode': r['mode'],
            'items_json': r['items_json'],
            'reference_number': r['reference_number'],
            'submitted_at': r['submitted_at'],
            'item_count': r['item_count'] ?? 0,
            'total_amount': r['total_amount'] ?? 0,
            'deleted': (r['deleted'] as int? ?? 0) == 1,
            'client_updated_at': (r['updated_at'] as String?) ?? syncStamp(),
          },
    ]
        // A row with no uid cannot be merged — it would arrive on the other
        // device as a brand new handover on every sync. The v12 migration
        // backfills these, so this only catches a row written by something
        // that bypassed the repository.
        .where((m) => table == 'accounts' || (m['uid'] as String?) != null)
        .toList();
  }

  // --- Local writes --------------------------------------------------------

  /// Merge server rows into the local tables.
  ///
  /// Rule 3: `updated_at` is written from the server's `client_updated_at`, NOT
  /// from now(). A row that came down from the desktop must not look like a
  /// local edit, or the two devices push it back and forth forever.
  static Future<void> _apply(
      Database db, String table, List<Map<String, dynamic>> rows) async {
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        final stamp = r['client_updated_at'] as String?;
        if (table == 'accounts') {
          // `accounts.next_due_date` is TEXT NOT NULL locally, but
          // `book_accounts.next_due_date` is nullable on the server. One null
          // coming down is a NOT NULL violation that takes the whole pull with
          // it — and because the cursor is saved after this, every later sync
          // re-fetches the same page and fails again.
          //
          // Skipped and reported rather than repaired: the row is not usable
          // without a due date, and inventing one would put a made-up date on
          // the screen the agent plans his round from.
          final due = r['next_due_date'] as String?;
          if (due == null || due.isEmpty) {
            Analytics.error('cloud_sync',
                'pull: account with no next_due_date skipped',
                screen: 'cloud_sync');
            continue;
          }
          batch.insert(
            'accounts',
            {
              'account_number': r['account_number'],
              'customer_name': r['customer_name'] ?? '',
              'denomination_amount': r['denomination_amount'] ?? 0,
              'next_due_date': r['next_due_date'],
              'months_paid': r['months_paid'] ?? 0,
              'serial': r['serial'] ?? 0,
              'status': r['status'] ?? 'pending',
              'aslaas': r['aslaas'],
              'opening_date': r['opening_date'],
              'total_deposit': r['total_deposit'],
              'pending_installments': r['pending_installments'],
              'default_installments': r['default_installments'],
              'last_deposit_date': r['last_deposit_date'],
              'route_order': r['route_order'],
              'daily_amount': r['daily_amount'],
              'closed_at': r['closed_at'],
              'updated_at': stamp,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          final values = table == 'collections'
              ? {
                  'uid': r['uid'],
                  'account_number': r['account_number'],
                  'amount': r['amount'],
                  'installments': r['installments'] ?? 1,
                  'collected_at': r['collected_at'],
                  'cycle_ym': r['cycle_ym'],
                  'note': r['note'],
                  'deleted': (r['deleted'] == true) ? 1 : 0,
                  'updated_at': stamp,
                }
              : {
                  'uid': r['uid'],
                  'created_at': r['created_at'],
                  'mode': r['mode'],
                  'items_json': r['items_json'],
                  'reference_number': r['reference_number'],
                  'submitted_at': r['submitted_at'],
                  'item_count': r['item_count'] ?? 0,
                  'total_amount': r['total_amount'] ?? 0,
                  'deleted': (r['deleted'] == true) ? 1 : 0,
                  'updated_at': stamp,
                };
          // Keyed on `uid`, never on the local auto-increment id — the two
          // devices agree on the uuid and on nothing else. UPDATE-then-INSERT
          // rather than a plain upsert so the local `id` (which the UI holds
          // in list state) survives an edit arriving from the other device.
          final hit = await txn.update(table, values,
              where: 'uid = ?', whereArgs: [r['uid']]);
          if (hit == 0) batch.insert(table, values);
        }
      }
      await batch.commit(noResult: true);
    });
  }

  static Map<String, dynamic> _readMap(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{}; // corrupt: fall back to a full re-sync
    }
  }

  /// Forget the CURRENT agent's cursors, so the next [run] re-pulls his whole
  /// book.
  ///
  /// The repair for a device whose local copy is suspect. It never deletes
  /// anything: the pull merges by uid, so re-pulling is additive.
  ///
  /// Note it is not what makes an agent switch safe — the marks are keyed per
  /// agent, so a switch carries no marks across and needs no reset. Calling
  /// this on logout would throw away the outgoing agent's marks and make his
  /// next sign-in re-push his entire book.
  static Future<void> resetCursors() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCursor);
    await prefs.remove(_kPushed);
  }
}
