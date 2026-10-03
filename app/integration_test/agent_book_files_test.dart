import 'dart:io';

import 'package:dop_collect/data/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// The four per-agent book paths, on a REAL device.
///
/// Every one of them renames a database file, and none can run on the host:
/// they need `dart:io` plus `getDatabasesPath()`, and the handset store is
/// SQLCipher rather than the plain SQLite a host test can open. So this is an
/// integration test, and it exists because the thing being renamed is the
/// `collections` ledger — the only record of cash taken at a door, with no
/// cloud copy guaranteed and `allowBackup=false` underneath it.
///
/// Run:
///   flutter test integration_test/agent_book_files_test.dart -d <device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const agentA = 'AGENTA0001';
  const agentB = 'AGENTB0002';

  Future<String> dbDir() async => getDatabasesPath();

  Future<List<String>> booksOnDisk() async {
    final d = Directory(await dbDir());
    if (!await d.exists()) return const [];
    return d
        .listSync()
        .map((f) => p.basename(f.path))
        .where((n) => n.startsWith('dop_collect'))
        .toList()
      ..sort();
  }

  /// Wipe every book and all app prefs, so each case starts from nothing.
  Future<void> reset() async {
    await AppDatabase.instance.close();
    final d = Directory(await dbDir());
    if (await d.exists()) {
      for (final f in d.listSync()) {
        if (p.basename(f.path).startsWith('dop_collect')) {
          try {
            f.deleteSync();
          } catch (_) {/* ignore */}
        }
      }
    }
    // Order matters: releaseAgent SETS the legacy-adopted flag (that is its
    // job — see its doc), so prefs must be cleared AFTER it or every test
    // below starts in a state where adoption is already closed and the legacy
    // cases pass vacuously.
    await AppDatabase.instance.releaseAgent();
    await (await SharedPreferences.getInstance()).clear();
    await AppDatabase.instance.close();
  }

  Future<void> seedCollection(int amount, String uid) async {
    final db = await AppDatabase.instance.database;
    await db.insert('collections', {
      'account_number': '020000000001',
      'amount': amount,
      'installments': 1,
      'collected_at': '2026-09-07T10:00:00.000Z',
      'cycle_ym': '2026-09',
      'uid': uid,
      'updated_at': '2026-09-07T10:00:00.000Z',
      'deleted': 0,
    });
  }

  /// The state a phone is actually in at the moment of the v13 update: a book
  /// under the old fixed name, no agent key, and no adoption flag — because
  /// nothing in the shipped app had ever written one.
  Future<void> becomeLegacyInstall(int amount, String uid) async {
    await AppDatabase.instance.releaseAgent();
    await (await SharedPreferences.getInstance()).clear();
    await AppDatabase.instance.close();
    await seedCollection(amount, uid);
    await AppDatabase.instance.close();
  }

  Future<int> collectionTotal() async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery('SELECT COALESCE(sum(amount),0) s FROM collections');
    return (r.first['s'] as num).toInt();
  }

  setUp(reset);
  tearDownAll(reset);

  testWidgets('two agents on one phone keep separate books', (_) async {
    await AppDatabase.instance.useAgent(agentA);
    await seedCollection(500, 'a-1');
    expect(await collectionTotal(), 500);

    await AppDatabase.instance.useAgent(agentB);
    // B must NOT see A's money. This is the whole bug.
    expect(await collectionTotal(), 0,
        reason: "agent B opened agent A's book");
    await seedCollection(900, 'b-1');
    expect(await collectionTotal(), 900);

    // And A's book is still intact, not overwritten.
    await AppDatabase.instance.useAgent(agentA);
    expect(await collectionTotal(), 500, reason: "agent A's book was lost");

    final files = await booksOnDisk();
    expect(files.length, greaterThanOrEqualTo(2),
        reason: 'expected one file per agent, found $files');
  });

  testWidgets('a pre-v13 book is adopted exactly once', (_) async {
    // Build the legacy file the way an installed app would have left it: no
    // agent key set, so `_fileName` is the legacy name.
    final legacy = File(p.join(await dbDir(), AppDatabase.legacyFileName));
    await becomeLegacyInstall(1200, 'legacy-1');
    expect(await legacy.exists(), isTrue,
        reason: 'test did not actually create the legacy file');

    // First agent in after the update inherits it — otherwise he opens the app
    // to an empty book.
    await AppDatabase.instance.useAgent(agentA);
    expect(await collectionTotal(), 1200,
        reason: 'the pre-v13 book was not claimed');
    expect(await legacy.exists(), isFalse,
        reason: 'the legacy file should have been renamed, not copied');

    // The SECOND agent must not inherit it again — that is the original bug
    // wearing a different hat.
    await AppDatabase.instance.useAgent(agentB);
    expect(await collectionTotal(), 0,
        reason: 'agent B adopted the same legacy book a second time');
  });

  testWidgets('logout closes legacy adoption for good', (_) async {
    final legacy = File(p.join(await dbDir(), AppDatabase.legacyFileName));
    await becomeLegacyInstall(700, 'legacy-2');
    expect(await legacy.exists(), isTrue);

    // Nobody claimed it, then someone logs out. "The book belongs to whoever
    // signs in now" stops being true at that moment. Note the legacy file is
    // genuinely unclaimed here — becomeLegacyInstall wiped the flag — so this
    // asserts the logout, not the setUp.
    await AppDatabase.instance.releaseAgent();
    await AppDatabase.instance.useAgent(agentB);
    expect(await collectionTotal(), 0,
        reason: 'an unclaimed legacy book was adopted after a logout');
  });

  testWidgets('startFreshBook sets the old one aside and Undo brings it back',
      (_) async {
    await AppDatabase.instance.useAgent(agentA);
    await seedCollection(2500, 'mixed-1');
    expect(await collectionTotal(), 2500);

    await AppDatabase.instance.startFreshBook(agentA);
    expect(await collectionTotal(), 0, reason: 'the fresh book is not empty');

    // Nothing may be destroyed: collections is the only record of that cash.
    final aside = await booksOnDisk();
    expect(aside.where((f) => f.contains('.replaced-')), isNotEmpty,
        reason: 'the old book was deleted rather than set aside: $aside');

    final restored = await AppDatabase.instance.restoreSetAsideBook();
    expect(restored, isTrue);
    expect(await collectionTotal(), 2500,
        reason: 'Undo did not bring the book back');
  });

  testWidgets('adoptAgentId carries the book to a corrected id', (_) async {
    await AppDatabase.instance.useAgent(agentA);
    await seedCollection(3100, 'corrected-1');
    final before = AppDatabase.instance.fileName;

    // The portal is the authority on the id and does not always match what was
    // typed. The book has to follow, or the agent finds the app empty mid-sync.
    await AppDatabase.instance.adoptAgentId('AGENTA0001-REAL');
    expect(AppDatabase.instance.fileName, isNot(before));
    expect(await collectionTotal(), 3100,
        reason: 'the book did not follow the corrected id');
  });

  testWidgets('a corrected id that already has a book keeps BOTH', (_) async {
    const corrected = 'AGENTA0001-REAL';

    // The agent has signed in with the right id before, so a book already
    // exists under the corrected key.
    await AppDatabase.instance.useAgent(corrected);
    await seedCollection(4200, 'real-1');

    // ...and has since been running under a mis-typed id, taking real cash.
    await AppDatabase.instance.useAgent(agentA);
    await seedCollection(1700, 'miskeyed-1');
    expect(await collectionTotal(), 1700);

    // The portal corrects the id. The corrected book wins, as it should.
    await AppDatabase.instance.adoptAgentId(corrected);
    expect(await collectionTotal(), 4200,
        reason: 'the corrected id should open its own, real book');

    // But the mis-keyed book held cash with no other copy anywhere, so it must
    // be set aside rather than orphaned where nothing can name it.
    final aside = await booksOnDisk();
    expect(aside.where((f) => f.contains('.replaced-')), isNotEmpty,
        reason: 'the mis-keyed book was orphaned, not set aside: $aside');

    expect(await AppDatabase.instance.restoreSetAsideBook(), isTrue);
    expect(await collectionTotal(), 1700,
        reason: 'the mis-keyed book was not recoverable');
  });
}
