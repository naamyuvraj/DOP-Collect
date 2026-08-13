import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Single SQLite database. Offline-first. Migrations must never drop the
/// already-synced `accounts` on a user's device.
///   v2: added `lots`.
///   v3: added per-account detail columns (opening date, total deposit,
///       pending/default installments, last deposit) filled by Deep Sync.
///   v4: added the read-only `v_accounts` view (derived buckets/fortnight/
///       months-behind) that the AI assistant queries. Carries no data, so it
///       is always safe to drop + recreate.
///   v5: added `lots.reference_number` + `lots.submitted_at` (real portal
///       reference captured on submission; null for every existing list).
///   v6: added `accounts.aslaas` (per-account, replacing one agency-wide value).
///   v7: added the `collections` ledger + `accounts.route_order`/`daily_amount`.
///   v8: added `lots.item_count`/`total_amount` (backfilled) and the
///       `v_collections` / `v_lots` read-only views, so the assistant can see
///       the collect ledger and the lists — not just the account book.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;
  Database? _roDb;

  Future<Database> get database async => _db ??= await _open();

  /// A second, SELECT-only connection to the SAME encrypted DB, used ONLY to run
  /// the AI assistant's LLM-generated SQL. Defence in depth: even if the
  /// string-based `SqlGuard` ever misses a mutation/DDL, SQLite itself rejects
  /// any write on a read-only handle — so a string parser is no longer the only
  /// thing standing between the model and the data.
  ///
  /// Opened AFTER the main DB (so the file exists, is keyed, and every
  /// migration incl. `v_accounts` has run) and with singleInstance:false so it's
  /// a genuinely distinct read-only connection, not the cached read-write one.
  Future<Database> get readOnlyDatabase async {
    if (_roDb != null) return _roDb!;
    await database; // ensure created + encrypted + migrated first
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'dop_collect.db');
    final prefs = await SharedPreferences.getInstance();
    final encrypted = prefs.getBool(_kEncrypted) ?? false;
    return _roDb ??= await openDatabase(
      path,
      password: encrypted ? await _dbKey() : null,
      readOnly: true,
      singleInstance: false,
    );
  }

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kEncrypted = 'db_encrypted_v1';

  /// True after a launch where the encrypted DB could not be opened with the
  /// current key and had to be recreated (Keystore key lost). The UI can read
  /// this to prompt the agent to Sync again.
  static bool needsResync = false;
  static const _kResync = 'db_needs_resync_v1';

  /// 256-bit DB key, generated once and kept in the Keystore.
  Future<String> _dbKey() async {
    String? k;
    try {
      k = await _secure.read(key: 'db_key');
    } catch (_) {
      // Secure storage unreadable (rare — corruption / device migration).
      // Fall through to generate a fresh key; the encrypted DB will then be
      // unreadable and recovered (recreated) in _open, and a Sync repopulates
      // it. Better than crash-looping on a locked-out Keystore.
      k = null;
    }
    if (k == null || k.isEmpty) {
      final r = Random.secure();
      k = List<int>.generate(32, (_) => r.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      try {
        await _secure.write(key: 'db_key', value: k);
      } catch (_) {/* if we can't persist it, we at least start this session */}
    }
    return k;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'dop_collect.db');
    final key = await _dbKey();
    final prefs = await SharedPreferences.getInstance();

    var encrypted = prefs.getBool(_kEncrypted) ?? false;
    if (!encrypted) {
      if (!await File(path).exists()) {
        // Fresh install — the DB we create below will be encrypted from birth.
        encrypted = true;
        await prefs.setBool(_kEncrypted, true);
      } else {
        // Existing plaintext DB (an upgrade) — encrypt it in place, safely.
        encrypted = await _encryptInPlace(path, key);
        await prefs.setBool(_kEncrypted, encrypted);
      }
    }

    needsResync = prefs.getBool(_kResync) ?? false;
    try {
      return await _openAt(path, key, encrypted);
    } catch (e) {
      // The (encrypted) DB couldn't be opened — almost always the Keystore key
      // was lost, so the ciphertext is unrecoverable regardless. A Sync fully
      // repopulates from the portal, so move the unreadable file ASIDE (never a
      // silent hard-delete) and start fresh rather than brick the app forever.
      if (encrypted && await File(path).exists()) {
        final aside = '$path.unreadable';
        try {
          if (await File(aside).exists()) await File(aside).delete();
          await File(path).rename(aside);
        } catch (_) {
          try {
            await File(path).delete();
          } catch (_) {/* last resort */}
        }
        needsResync = true;
        await prefs.setBool(_kResync, true);
        return _openAt(path, key, true);
      }
      rethrow;
    }
  }

  /// Clear the "please Sync again" flag once the agent has re-synced.
  Future<void> clearResyncFlag() async {
    needsResync = false;
    (await SharedPreferences.getInstance()).remove(_kResync);
  }

  Future<Database> _openAt(String path, String key, bool encrypted) {
    return openDatabase(
      path,
      // Only pass the key once the file is actually encrypted; otherwise open
      // the plaintext DB as-is (migration failed / not yet done) so the app
      // never fails to start and no data is lost.
      password: encrypted ? key : null,
      version: 8,
      onCreate: (db, version) async {
        await _createAccounts(db);
        await _createLots(db);
        await _createCollections(db);
        await _createAssistantView(db);
        await _createLedgerViews(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await _createLots(db);
        if (oldV < 3) await _addDetailColumns(db);
        if (oldV < 4) await _createAssistantView(db);
        if (oldV < 5) await _addLotSubmissionColumns(db);
        if (oldV < 6) await _addAslaasColumn(db);
        if (oldV < 7) {
          await _createCollections(db);
          await _addCollectionColumns(db);
        }
        if (oldV < 8) {
          // A v1 device jumping straight to v8 already got the columns from
          // _createLots above; only pre-existing lots tables need the backfill.
          if (oldV >= 2) await _addLotTotals(db);
          await _createLedgerViews(db);
        }
      },
      // Force key validation NOW so a bad/lost key fails here (recoverable
      // above) instead of later, mid-screen, as a crash.
      onOpen: (db) async {
        await db.rawQuery('SELECT count(*) FROM sqlite_master');
      },
    );
  }

  /// Encrypt an existing plaintext DB using SQLCipher's `sqlcipher_export`, then
  /// swap it in — but only after verifying the encrypted copy is readable. On
  /// any failure the original plaintext file is left untouched (returns false),
  /// so a failed migration degrades to "unencrypted", never to data loss.
  Future<bool> _encryptInPlace(String path, String key) async {
    final encPath = '$path.enc';
    Database? plain;
    try {
      if (await File(encPath).exists()) await File(encPath).delete();
      plain = await openDatabase(path); // no password => plaintext
      final v =
          Sqflite.firstIntValue(await plain.rawQuery('PRAGMA user_version')) ??
              0;
      await plain.rawQuery("ATTACH DATABASE '$encPath' AS enc KEY '$key'");
      await plain.rawQuery("SELECT sqlcipher_export('enc')");
      await plain.rawQuery('PRAGMA enc.user_version = $v');
      await plain.rawQuery('DETACH DATABASE enc');
      await plain.close();
      plain = null;

      // Verify: the encrypted copy opens with the key and has the accounts table.
      final check = await openDatabase(encPath, password: key);
      final ok = Sqflite.firstIntValue(await check.rawQuery(
              "SELECT count(*) FROM sqlite_master WHERE name='accounts'")) ==
          1;
      await check.close();
      if (!ok) throw Exception('verification failed');

      await File(path).delete();
      await File(encPath).rename(path);
      return true;
    } catch (_) {
      try {
        await plain?.close();
      } catch (_) {}
      try {
        if (await File(encPath).exists()) await File(encPath).delete();
      } catch (_) {}
      return false; // keep plaintext; retried on next launch
    }
  }

  Future<void> _createAccounts(Database db) async {
    await db.execute('''
      CREATE TABLE accounts (
        account_number        TEXT PRIMARY KEY,
        customer_name         TEXT NOT NULL,
        denomination_amount   INTEGER NOT NULL,
        next_due_date         TEXT NOT NULL,
        months_paid           INTEGER NOT NULL,
        serial                INTEGER NOT NULL DEFAULT 0,
        status                TEXT NOT NULL DEFAULT 'pending',
        aslaas                TEXT,
        opening_date          TEXT,
        total_deposit         INTEGER,
        pending_installments  INTEGER,
        default_installments  INTEGER,
        last_deposit_date     TEXT,
        route_order           INTEGER,
        daily_amount          INTEGER
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_accounts_due ON accounts(next_due_date)');
  }

  Future<void> _addDetailColumns(Database db) async {
    for (final col in const [
      'opening_date TEXT',
      'total_deposit INTEGER',
      'pending_installments INTEGER',
      'default_installments INTEGER',
      'last_deposit_date TEXT',
    ]) {
      await db.execute('ALTER TABLE accounts ADD COLUMN $col');
    }
  }

  /// v7: the field collection ledger — one row per handover of cash, never a
  /// per-account "collected" flag.
  ///
  /// Append-only on purpose. A flag has to be reset by someone, and the one
  /// this app used to keep (`accounts.status`) never was, so auto-build went
  /// quiet a month later. Everything the UI shows — collected this cycle, how
  /// much is left, what's in the bag today — is a SUM over these rows for a
  /// cycle, so it expires by itself when the cycle turns over. Undo deletes the
  /// row.
  ///
  /// One row covers both ways an agent gets paid: a monthly customer is a
  /// single `denomination`-sized row, a daily customer is ~30 small ones.
  /// `installments` is stamped at collection time (an advance payer hands over
  /// 2–3 months at once) and read back when the list is built.
  Future<void> _createCollections(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collections (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        account_number TEXT    NOT NULL,
        amount         INTEGER NOT NULL,
        installments   INTEGER NOT NULL DEFAULT 1,
        collected_at   TEXT    NOT NULL,
        cycle_ym       TEXT    NOT NULL,
        note           TEXT
      )
    ''');
    // Every read is "this cycle" or "this customer's history" — index both.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_collections_cycle '
        'ON collections(cycle_ym)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_collections_account '
        'ON collections(account_number, cycle_ym)');
  }

  /// v7: two per-customer preferences that belong to the agent, not the portal.
  ///
  ///   route_order  — the order he actually walks his round. NULL until he
  ///                  arranges it; the list falls back to due date.
  ///   daily_amount — what this customer hands over per visit. NULL means a
  ///                  monthly payer (one lump sum); a value means a daily one.
  ///
  /// Both must survive a Sync — the portal knows nothing about them — so they
  /// are preserved in `SqfliteAccountRepository.replaceAll` alongside status
  /// and ASLAAS.
  Future<void> _addCollectionColumns(Database db) async {
    for (final col in const ['route_order INTEGER', 'daily_amount INTEGER']) {
      await db.execute('ALTER TABLE accounts ADD COLUMN $col');
    }
  }

  /// v6: each account's own ASLAAS number. It was previously one agent-level
  /// value in settings, which put the SAME number on every account of a list —
  /// wrong, since the portal holds a distinct ASLAAS per account.
  Future<void> _addAslaasColumn(Database db) async {
    await db.execute('ALTER TABLE accounts ADD COLUMN aslaas TEXT');
  }

  /// Read-only view the AI assistant queries. Exposes clean, pre-computed
  /// columns (bucket, fortnight, months_behind, maturity/new flags) so neither
  /// the local intent engine nor the cloud text-to-SQL has to reason about ISO
  /// date strings or bucket math. Rules mirror `AccountFilter` in
  /// `lib/models/summaries.dart` exactly — keep them in sync.
  Future<void> _createAssistantView(Database db) async {
    // months_behind = (nowY*12+nowM) - (dueY*12+dueM). Evaluated per-query, so
    // "now" is always current. Repeated inline because SQLite views can't hold
    // intermediate aliases across CASE branches.
    const mb =
        "((CAST(strftime('%Y','now','localtime') AS INTEGER)*12 + CAST(strftime('%m','now','localtime') AS INTEGER)) "
        "- (CAST(strftime('%Y', a.next_due_date) AS INTEGER)*12 + CAST(strftime('%m', a.next_due_date) AS INTEGER)))";
    await db.execute('DROP VIEW IF EXISTS v_accounts');
    await db.execute('''
      CREATE VIEW v_accounts AS
      SELECT
        a.account_number,
        a.customer_name,
        a.denomination_amount,
        a.months_paid,
        a.status,
        a.next_due_date,
        date(a.next_due_date)                              AS next_due,
        strftime('%Y-%m', a.next_due_date)                 AS due_ym,
        CAST(strftime('%d', a.next_due_date) AS INTEGER)   AS due_day,
        CASE WHEN CAST(strftime('%d', a.next_due_date) AS INTEGER) <= 15
             THEN 'first' ELSE 'second' END                AS fortnight,
        $mb                                                AS months_behind,
        CASE
          WHEN $mb >= 1  THEN 'defaulter'
          WHEN $mb =  0  THEN 'pending'
          ELSE 'deposited'
        END                                                AS bucket,
        CASE WHEN $mb >= 6 THEN 1 ELSE 0 END               AS about_to_freeze,
        CASE WHEN $mb <= -2 THEN 1 ELSE 0 END              AS advanced_paid,
        CASE
          WHEN a.pending_installments IS NOT NULL
            THEN (CASE WHEN a.pending_installments <= 2 THEN 1 ELSE 0 END)
          WHEN a.months_paid BETWEEN 58 AND 61 THEN 1
          ELSE 0
        END                                                AS is_maturity,
        CASE
          WHEN a.opening_date IS NOT NULL
            THEN (CASE WHEN date(a.opening_date) >= date('now','localtime','-3 months')
                       THEN 1 ELSE 0 END)
          WHEN a.months_paid <= 3 THEN 1
          ELSE 0
        END                                                AS is_new,
        a.denomination_amount * a.months_paid              AS est_deposit,
        a.denomination_amount * (CASE WHEN $mb >= 1 THEN $mb ELSE 1 END)
                                                           AS arrears_amount,
        a.total_deposit,
        a.opening_date,
        a.pending_installments,
        a.default_installments,
        a.last_deposit_date,
        a.serial
      FROM accounts a
    ''');
  }

  /// v8: the other two thirds of the app, made queryable.
  ///
  /// `v_accounts` describes the book as the portal sees it. Everything the
  /// agent actually *did* — the cash he took today, the lists he built — lived
  /// in `collections` and `lots`, which the assistant's SQL guard forbids it
  /// from naming. So "aaj kitna collect hua" was not answered badly; it was
  /// unanswerable. These two views close that gap.
  ///
  /// Both carry no data of their own, so they are always safe to drop and
  /// recreate on upgrade.
  Future<void> _createLedgerViews(Database db) async {
    await db.execute('DROP VIEW IF EXISTS v_collections');
    await db.execute('''
      CREATE VIEW v_collections AS
      SELECT
        c.id,
        c.account_number,
        a.customer_name,
        c.amount,
        c.installments,
        c.collected_at,
        date(c.collected_at)                               AS collected_on,
        strftime('%H:%M', c.collected_at)                  AS collected_time,
        c.cycle_ym,
        CASE WHEN date(c.collected_at) = date('now','localtime')
             THEN 1 ELSE 0 END                             AS is_today,
        CASE WHEN c.cycle_ym = strftime('%Y-%m','now','localtime')
             THEN 1 ELSE 0 END                             AS is_this_cycle,
        a.denomination_amount,
        c.note
      FROM collections c
      LEFT JOIN accounts a ON a.account_number = c.account_number
    ''');

    await db.execute('DROP VIEW IF EXISTS v_lots');
    await db.execute('''
      CREATE VIEW v_lots AS
      SELECT
        l.id,
        l.mode,
        l.item_count,
        l.total_amount,
        l.reference_number,
        date(l.created_at)                                 AS created_on,
        strftime('%Y-%m', l.created_at)                    AS created_ym,
        l.submitted_at,
        CASE WHEN l.reference_number IS NOT NULL
             THEN 1 ELSE 0 END                             AS is_submitted,
        CASE WHEN strftime('%Y-%m', l.created_at)
                  = strftime('%Y-%m','now','localtime')
             THEN 1 ELSE 0 END                             AS is_this_cycle
      FROM lots l
    ''');
  }

  Future<void> _createLots(Database db) async {
    await db.execute('''
      CREATE TABLE lots (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at        TEXT NOT NULL,
        mode              TEXT NOT NULL,
        items_json        TEXT NOT NULL,
        reference_number  TEXT,
        submitted_at      TEXT,
        item_count        INTEGER NOT NULL DEFAULT 0,
        total_amount      INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// v8: size and value alongside the JSON blob, so `v_lots` can be a plain
  /// view. Existing rows are backfilled by parsing their items in Dart — no
  /// dependency on the JSON1 extension being present in this SQLCipher build.
  Future<void> _addLotTotals(Database db) async {
    for (final col in const [
      'item_count INTEGER NOT NULL DEFAULT 0',
      'total_amount INTEGER NOT NULL DEFAULT 0',
    ]) {
      await db.execute('ALTER TABLE lots ADD COLUMN $col');
    }
    final rows = await db.query('lots', columns: ['id', 'items_json']);
    final batch = db.batch();
    for (final r in rows) {
      var count = 0;
      var total = 0;
      try {
        for (final e in jsonDecode(r['items_json'] as String) as List) {
          final item = e as Map<String, Object?>;
          count++;
          total += ((item['d'] as num).toInt()) * ((item['i'] as num).toInt());
        }
      } catch (_) {
        continue; // unreadable blob — leave it at 0 rather than fail the upgrade
      }
      batch.update('lots', {'item_count': count, 'total_amount': total},
          where: 'id = ?', whereArgs: [r['id']]);
    }
    await batch.commit(noResult: true);
  }

  /// v5: the real portal reference (C…/DC…/NDC…) + submit time, captured once a
  /// list is actually submitted. Null for every existing (unsubmitted) list.
  Future<void> _addLotSubmissionColumns(Database db) async {
    for (final col in const ['reference_number TEXT', 'submitted_at TEXT']) {
      await db.execute('ALTER TABLE lots ADD COLUMN $col');
    }
  }
}
