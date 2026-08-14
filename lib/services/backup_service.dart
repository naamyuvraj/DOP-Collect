import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';
import 'backup_format.dart';
import 'supabase_config.dart';

/// Reads the khata out to an encrypted file, and puts it back.
///
/// Pairs with [BackupFormat], which owns the bytes; this owns the database and
/// the filesystem. Split that way so the format — and every way it can fail — is
/// testable without a handset.
class BackupService {
  BackupService(this._db);
  final AppDatabase _db;

  /// The khata, and only the khata.
  ///
  /// `collections` is every rupee taken at a door. It is the one thing in this
  /// app with no other copy anywhere — the portal has never heard of it and
  /// neither has our server, so an uninstall ends it. Accounts are deliberately
  /// NOT here: a portal Deep Sync rebuilds them, and leaving them out means a
  /// restore can never overwrite the agent's live account book by accident.
  ///
  /// The format itself is keyed by table name, so widening this list is the only
  /// change needed if `lots` or the account book should travel too.
  static const tables = ['collections'];

  /// Nothing. A khata backup carries the ledger and no settings — no agent name,
  /// no ASLAAS, and above all no credentials, because this file is meant to be
  /// sent through WhatsApp or parked in Drive.
  static const prefKeys = <String>[];

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

  /// Replace the khata with [payload].
  ///
  /// All-or-nothing: one transaction, so a failure halfway leaves the existing
  /// ledger untouched rather than half-replaced. That matters more here than
  /// anywhere else in the app — the thing being overwritten is the only copy.
  ///
  /// Touches ONLY the tables in [tables]. The account book is not in that list,
  /// so a restore can never damage it, and anything else the file happens to
  /// carry is ignored rather than written blindly.
  ///
  /// Unknown columns are skipped rather than fatal, so a backup from a slightly
  /// older build still restores what it does have.
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

    // Deliberately NOT clearing AppDatabase.needsResync. That flag means the
    // ACCOUNT book was lost and must be pulled from the portal again; restoring
    // a khata puts the ledger back but no accounts, so the nag is still true and
    // silencing it here would strand him with an empty book and no prompt.
    return report;
  }
}

class RestoreReport {
  final Map<String, int> restored = {};
  final Set<String> droppedColumns = {};

  /// Entries put back — the number the agent is shown after a restore.
  int get collections => restored['collections'] ?? 0;
}
