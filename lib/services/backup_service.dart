import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';
import 'backup_format.dart';
import 'supabase_config.dart';

/// Reads the whole book out to an encrypted file, and puts it back.
///
/// Pairs with [BackupFormat], which owns the bytes; this owns the database and
/// the filesystem. Split that way so the format — and every way it can fail — is
/// testable without a handset.
class BackupService {
  BackupService(this._db);
  final AppDatabase _db;

  /// Everything worth carrying across a reinstall.
  ///
  /// `accounts` is here even though a portal Deep Sync could rebuild most of it,
  /// because four of its columns could not: `status`, `aslaas`, `route_order`
  /// and `daily_amount` are the agent's own and the portal has never heard of
  /// them. `collections` and `lots` have no other copy anywhere.
  static const tables = ['accounts', 'collections', 'lots'];

  /// Settings that live in SharedPreferences rather than the database and would
  /// otherwise be silently lost. Deliberately NOT everything: no credentials (a
  /// backup must never carry the DOP password), no device id, no session token,
  /// no cached subscription — those are per-phone and must be re-earned.
  static const prefKeys = [
    'agent_name',
    'aslaas_number',
    'mobile_number',
    'profile_photo',
    'daily_rule_flat',
    'daily_rule_days',
    'daily_rule_amount',
    'day_closed_on',
    'day_closed_counted',
    'day_closed_total',
    'collect_daily_mode',
    'new_account_months',
    'rd_rate_history_v1',
    'downloaded_lot_ids',
  ];

  static const _kLastBackup = 'last_backup_ms';

  /// When the agent last made a backup (ms since epoch, 0 = never).
  static Future<int> lastBackupMs() async =>
      (await SharedPreferences.getInstance()).getInt(_kLastBackup) ?? 0;

  /// Build the encrypted bytes. Pure read — touches nothing.
  Future<Uint8List> export(String passphrase) async {
    final db = await _db.database;
    final data = <String, List<Map<String, Object?>>>{};
    for (final t in tables) {
      data[t] = (await db.query(t))
          .map(Map<String, Object?>.from)
          .toList(growable: false);
    }

    final prefs = await SharedPreferences.getInstance();
    final kv = <String, Object?>{};
    for (final k in prefKeys) {
      final v = prefs.get(k);
      // A key the agent never set stays absent rather than restoring a null over
      // a good value later.
      if (v != null) kv[k] = v is List<String> ? v.toList() : v;
    }

    return BackupFormat.seal(
      BackupFormat.encode(
        tables: data,
        prefs: kv,
        takenAt: DateTime.now(),
        appVersion: SupabaseConfig.buildVersion,
      ),
      passphrase,
    );
  }

  /// Write the backup to a shareable file and return it.
  ///
  /// Goes to the app's cache directory, which is what `share_plus` can hand to
  /// WhatsApp/Drive. The agent's chosen destination is the real backup; this
  /// copy is scratch and the OS may clear it.
  Future<File> writeToShareable(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, BackupFormat.fileNameFor(DateTime.now())));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// Record that a backup was actually taken. Called after the share sheet
  /// closes, not before — a sheet the agent cancels is not a backup.
  static Future<void> markBackedUp() async =>
      (await SharedPreferences.getInstance())
          .setInt(_kLastBackup, DateTime.now().millisecondsSinceEpoch);

  /// Decrypt and read without writing anything, so the UI can show the agent
  /// what he is about to overwrite and let him back out.
  BackupPayload inspect(Uint8List bytes, String passphrase) =>
      BackupFormat.decode(BackupFormat.open(bytes, passphrase));

  /// Replace the current book with [payload].
  ///
  /// All-or-nothing: one transaction, so a failure halfway leaves the existing
  /// book untouched rather than half-replaced. That matters more here than
  /// anywhere else in the app — the thing being overwritten is the only copy.
  ///
  /// Unknown tables and unknown columns are skipped rather than fatal, so a
  /// backup from a slightly older build still restores what it does have.
  Future<RestoreReport> restore(BackupPayload payload) async {
    final db = await _db.database;
    final report = RestoreReport();

    // What this build's schema actually has, so a stale column in an old backup
    // is dropped instead of failing the whole restore.
    final columns = <String, Set<String>>{};
    for (final t in tables) {
      columns[t] = (await db.rawQuery('PRAGMA table_info($t)'))
          .map((r) => '${r['name']}')
          .toSet();
    }

    await db.transaction((txn) async {
      for (final t in tables) {
        final rows = payload.tables[t];
        if (rows == null) continue; // absent in this backup — leave the table
        await txn.delete(t);
        final known = columns[t]!;
        final batch = txn.batch();
        for (final row in rows) {
          final clean = <String, Object?>{};
          for (final e in row.entries) {
            if (known.contains(e.key)) {
              clean[e.key] = e.value;
            } else {
              report.droppedColumns.add('$t.${e.key}');
            }
          }
          if (clean.isEmpty) continue;
          batch.insert(t, clean);
        }
        await batch.commit(noResult: true);
        report.restored[t] = rows.length;
      }
    });

    final prefs = await SharedPreferences.getInstance();
    for (final e in payload.prefs.entries) {
      if (!prefKeys.contains(e.key)) continue; // never trust a key we don't own
      final v = e.value;
      if (v is bool) await prefs.setBool(e.key, v);
      if (v is int) await prefs.setInt(e.key, v);
      if (v is double) await prefs.setInt(e.key, v.toInt());
      if (v is String) await prefs.setString(e.key, v);
      if (v is List) {
        await prefs.setStringList(e.key, v.map((x) => '$x').toList());
      }
    }

    // The restored book came from the portal originally, so the "please Sync
    // again" nag from a lost-Keystore recovery no longer applies.
    await _db.clearResyncFlag();
    return report;
  }
}

class RestoreReport {
  final Map<String, int> restored = {};
  final Set<String> droppedColumns = {};

  int get accounts => restored['accounts'] ?? 0;
  int get collections => restored['collections'] ?? 0;
  int get lots => restored['lots'] ?? 0;
}
