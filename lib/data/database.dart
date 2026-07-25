import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Single SQLite database. Offline-first. Migrations must never drop the
/// already-synced `accounts` on a user's device.
///   v2: added `lots`.
///   v3: added per-account detail columns (opening date, total deposit,
///       pending/default installments, last deposit) filled by Deep Sync.
///   v4: added the read-only `v_accounts` view (derived buckets/fortnight/
///       months-behind) that the AI assistant queries. Carries no data, so it
///       is always safe to drop + recreate.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'dop_collect.db');
    return openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await _createAccounts(db);
        await _createLots(db);
        await _createAssistantView(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await _createLots(db);
        if (oldV < 3) await _addDetailColumns(db);
        if (oldV < 4) await _createAssistantView(db);
      },
    );
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
        opening_date          TEXT,
        total_deposit         INTEGER,
        pending_installments  INTEGER,
        default_installments  INTEGER,
        last_deposit_date     TEXT
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

  Future<void> _createLots(Database db) async {
    await db.execute('''
      CREATE TABLE lots (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at  TEXT NOT NULL,
        mode        TEXT NOT NULL,
        items_json  TEXT NOT NULL
      )
    ''');
  }
}
