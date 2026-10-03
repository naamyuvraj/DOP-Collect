import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'credentials.dart';
import 'sync_ids.dart';

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
///   v9: added `accounts.closed_at` — when a COMPLETE sync first found the
///       account gone from the portal listing (matured and closed). Existing
///       rows get NULL, i.e. "live", so an upgrade closes nothing on its own;
///       the first finished sync after it is what marks them.
///  v10: rebuilt `v_accounts` so the assistant and the app agree. `is_new` and
///       `is_maturity` were defined differently here than in `AccountFilter`,
///       so the two surfaces answered the same question with different
///       numbers; `opening_on` is new, and the dead `status` column is gone.
///  v11: rebuilt `v_accounts` again for the term boundary. The five/ten-year
///       inference was `months_paid > 60`; only a LIVE account reaches the
///       view, so 60 paid means the 61st is due and the account was continued.
///       At `> 60` it read as matured and `is_maturity` fired five years early.
///  v12: added `uid`/`updated_at`/`deleted` to `collections` and `lots`, and
///       `updated_at` to `accounts` — everything two-way sync with the desktop
///       needs. `uid` is backfilled for existing rows so the agent's whole
///       history syncs, not just what he does from today. `remove()` is now a
///       soft delete: a hard-deleted row cannot tell the other device it went.
///  v13: added the `meta` key/value table, which holds `book_owner` — the DOP
///       agent id whose book this file is. Carries no customer data; it exists
///       so a book can say whose it is. See [useAgent].
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
    // The web backend serialises everything through one shared worker, so a
    // second "connection" is the same connection — `singleInstance: false`
    // buys nothing there. The SqlGuard is still in front of the model, so this
    // is one layer thinner on web, not zero.
    if (kIsWeb) return _roDb ??= await _openWeb();
    final dir = await getDatabasesPath();
    final path = p.join(dir, _fileName);
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

  // --- Which agent's book is this? -----------------------------------------
  //
  // ONE FILE PER AGENT, and the reason is that scoping a shared table cannot
  // be made safe here. Every read would need an `agent_id = ?` predicate, and
  // the two read-only VIEWS (`v_accounts`, `v_collections`) are what the AI
  // assistant runs generated SQL against — a view takes no parameters, so a
  // forgotten predicate there answers across two agents' books with no error
  // anywhere. A separate file cannot forget: the rows are not in it.
  //
  // It also makes the switch non-destructive. A's book stays on disk when B
  // logs in, so switching back is instant and nothing has to be re-synced from
  // the portal — and no code path ever has to DELETE a collections row, which
  // is the one table with no other copy anywhere.

  /// File key of the agent whose book is open. Null = the legacy, unclaimed
  /// file, which is the shape every install had before v13.
  String? _agentKey;

  static const _kAgentKey = 'db_agent_key_v1';
  static const _kLegacyAdopted = 'db_legacy_adopted_v1';

  /// The pre-v13 filename. Still the name of the file on every existing
  /// install until the first [useAgent] claims it.
  static const legacyFileName = 'dop_collect.db';

  String get _fileName => (_agentKey == null || _agentKey!.isEmpty)
      ? legacyFileName
      : 'dop_collect_${_agentKey!}.db';

  /// The file name this database is currently using. Exposed for diagnostics
  /// and tests; nothing should build a path from anything else.
  String get fileName => _fileName;

  /// A stable, non-reversible file key for a DOP agent id.
  ///
  /// Hashed rather than used raw for two reasons. The agent id is the login
  /// name for a banking portal and it should not sit in a filename that any
  /// file manager lists. And it is normalised first, so `MI847…`, `DOP.MI847…`
  /// and `dop.mi847…` are one agent and not three books — the same three forms
  /// [Credentials.normaliseAgentId] already exists to reconcile.
  ///
  /// Truncated to 16 hex characters (64 bits). A collision would merge two
  /// agents' books, which is the bug this whole change exists to prevent, so
  /// the margin matters: at 64 bits it is not reachable by the population of
  /// DOP agents in India, let alone by the users of this app.
  static String agentKeyFor(String agentId) {
    final id = Credentials.normaliseAgentId(agentId).toUpperCase();
    if (id.isEmpty) return '';
    return sha256.convert(utf8.encode(id)).toString().substring(0, 16);
  }

  /// Point the database at [agentId]'s book, opening it on the next query.
  ///
  /// Call this before anything reads the database — at startup, after a login,
  /// and after the portal corrects the stored agent id. It is a no-op when the
  /// book is already the right one, so calling it often is free.
  ///
  /// An empty [agentId] is deliberately ignored rather than treated as "no
  /// agent". A Keystore read can fail (lock-screen change, direct boot) and
  /// return empty credentials — see [Credentials.load], whose whole contract is
  /// to degrade to empty rather than throw. Re-keying to the legacy file on
  /// that would show the agent an empty book and invite him to re-sync over it.
  /// Keeping the current book is the safe reading of "I don't know".
  Future<void> useAgent(String agentId) async {
    final key = agentKeyFor(agentId);
    if (key.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    _agentKey ??= prefs.getString(_kAgentKey);
    // Already this agent's book — nothing to do, and in particular nothing to
    // re-stamp. An unstamped book claimed from the pre-v13 file has to STAY
    // unstamped until a sync vouches for it; stamping it on the next cold
    // start would quietly assert the ownership this whole path exists to
    // question, and the mixed book would never be offered its repair. Whether
    // the handle is open is irrelevant: an unopened book opens on first query,
    // exactly as it did before any of this.
    if (_agentKey == key) return;

    await close();
    _agentKey = key;
    await prefs.setString(_kAgentKey, key);

    // A book claimed from the pre-v13 file is deliberately left UNSTAMPED.
    // Its provenance is the one thing nothing on this phone knows — it may be
    // this agent's, or it may be the mixed book that made this change
    // necessary — and stamping it here would assert the very fact we cannot
    // check, hiding it from the repair in SyncScreen that exists to ask.
    // A completed sync with no refused closures is what earns the stamp.
    final adopted = kIsWeb ? false : await _adoptLegacy(prefs);
    if (!adopted) await setBookOwner(agentId);
  }

  /// Carry the open book across to a CORRECTED id for the same agent.
  ///
  /// The portal is the authority on an agent's id, and it does not always
  /// match what was typed — see `_adoptPortalAgentId`. That correction changes
  /// the file key, so without this the agent's book would still be sitting
  /// under the old key and he would find the app empty mid-sync.
  ///
  /// This is deliberately NOT [useAgent]. The difference is the rename: here
  /// the two ids are one agent, so the book moves. A different agent signing in
  /// gets his own file and this one is left untouched, which is why [useAgent]
  /// needs no such step and never has to decide whether a book is "really" the
  /// same person's — a judgement that, made wrong, costs a book.
  Future<void> adoptAgentId(String correctedId) async {
    final key = agentKeyFor(correctedId);
    if (key.isEmpty || key == _agentKey) return;

    final from = _fileName;
    await close();
    _agentKey = key;
    try {
      await (await SharedPreferences.getInstance())
          .setString(_kAgentKey, key);
      if (!kIsWeb) {
        final dir = await getDatabasesPath();
        final src = File(p.join(dir, from));
        final dst = File(p.join(dir, _fileName));
        if (await src.exists()) {
          if (!await dst.exists()) {
            await src.rename(dst.path);
          } else {
            // The corrected id already has a book — that one is the real book
            // and it wins. But the mis-keyed file is not junk: it may hold cash
            // rows taken while the wrong id was stored, and `collections` has
            // no other copy anywhere. Set it aside under the name
            // `restoreSetAsideBook` looks for, so it is recoverable through the
            // same Undo as any other replaced book instead of being orphaned
            // where nothing can name it.
            final stamp =
                DateTime.now().toIso8601String().replaceAll(':', '-');
            await src.rename('${dst.path}.replaced-$stamp');
          }
        }
      }
    } catch (_) {/* the book stays under the old key; the next sync retries */}
    await setBookOwner(correctedId);
  }

  /// Claim the pre-v13 file for the first agent to log in after the update.
  ///
  /// Exactly once, ever. The book on the phone belongs to whoever is signing
  /// in now, and moving it is what stops that agent finding an empty app after
  /// an update. The flag matters as much as the rename: without it, the NEXT
  /// agent to log in on the same phone would adopt the same file a second time
  /// and inherit the first agent's customers — which is this bug again, wearing
  /// a different hat.
  /// Returns true only when a pre-v13 book was actually claimed.
  Future<bool> _adoptLegacy(SharedPreferences prefs) async {
    if (prefs.getBool(_kLegacyAdopted) ?? false) return false;
    var claimed = false;
    try {
      final dir = await getDatabasesPath();
      final legacy = File(p.join(dir, legacyFileName));
      final target = File(p.join(dir, _fileName));
      if (await legacy.exists() && !await target.exists()) {
        await legacy.rename(target.path);
        // The sync marks describe THIS book, so they move with it. Without
        // this the claiming agent's first sync after the update re-pushes his
        // whole book — 1,500 accounts plus every collection and lot — through
        // the chunk loop, which over a rural connection is the slowest thing
        // the app does.
        for (final k in const ['sync_cursor', 'sync_pushed_high_water']) {
          final v = prefs.getString(k);
          if (v != null) {
            await prefs.setString('${k}_$_agentKey', v);
            await prefs.remove(k);
          }
        }
        claimed = true;
      }
      await prefs.setBool(_kLegacyAdopted, true);
    } catch (_) {
      // A rename that fails leaves the legacy file where it is and the agent
      // with an empty book he can re-sync from the portal. Bad, but recoverable
      // — and far better than failing to open the app at all.
    }
    return claimed;
  }

  /// Move the open book aside and start an empty one for [agentId].
  ///
  /// The MANUAL repair, and the only one there is. Separate files mean a normal
  /// agent switch never needs it — B gets B's file and A's is untouched. What
  /// needs it is a book that was already mixed before any of this existed: a
  /// pre-v13 file carries no owner, so nothing can tell whose it is, and the
  /// only honest thing to do is ask. SyncScreen offers this when a complete
  /// sync would close more of the book than [AccountRepository.closureCeiling]
  /// allows, which is exactly the shape a foreign book has.
  ///
  /// The old file is RENAMED, never deleted, exactly as an unreadable database
  /// is. `collections` is the only record of cash taken at a door and the
  /// server may not have all of it, so nothing in this app is allowed to
  /// destroy a book — not even one we are confident belongs to someone else.
  Future<void> startFreshBook(String agentId) async {
    await close();
    if (!kIsWeb) {
      try {
        final dir = await getDatabasesPath();
        final current = File(p.join(dir, _fileName));
        if (await current.exists()) {
          final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
          await current.rename('${current.path}.replaced-$stamp');
        }
      } catch (_) {/* fall through: reopening creates a fresh file anyway */}
    } else {
      // No filesystem in the browser. Dropping the rows is the only way to
      // start clean, and the desktop book is a replica of the phone's — the
      // phone still holds the original.
      try {
        final db = await database;
        await db.transaction((txn) async {
          for (final t in const ['accounts', 'collections', 'lots']) {
            await txn.delete(t);
          }
        });
      } catch (_) {/* ignore */}
      await close();
    }
    // The new book is empty, so the marks of the old one are worse than
    // useless: the pull cursor says the server's rows have already been seen,
    // and the fresh book would stay empty through every sync that follows.
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in const ['sync_cursor', 'sync_pushed_high_water']) {
        await prefs.remove('${k}_$_agentKey');
      }
    } catch (_) {/* a stale mark costs a re-pull, not data */}
    await setBookOwner(agentId);
  }

  /// Close both handles. The next query reopens whatever [_fileName] now says.
  Future<void> close() async {
    final db = _db;
    final ro = _roDb;
    _db = null;
    _roDb = null;
    try {
      await ro?.close();
    } catch (_) {/* a handle we are discarding anyway */}
    try {
      await db?.close();
    } catch (_) {/* ditto */}
  }

  /// Forget which agent's book is open, so the next [useAgent] starts clean.
  /// Called on logout — the file itself is left exactly where it is.
  ///
  /// It also closes legacy adoption for good. "The book on this phone belongs
  /// to whoever signs in now" is true at an upgrade and false the moment
  /// someone logs out, so an unclaimed pre-v13 file must never be adopted
  /// afterwards. Without this, one failed Keystore read at the upgrade launch
  /// (which leaves the flag unset — see [useAgent] on empty credentials) would
  /// let the NEXT agent to sign in inherit the previous one's whole book: this
  /// same bug, on the upgrade path carrying the most books.
  Future<void> releaseAgent() async {
    await close();
    _agentKey = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAgentKey);
      await prefs.setBool(_kLegacyAdopted, true);
    } catch (_) {/* the key is re-derived from the agent id on next login */}
  }


  /// The agent-scoped suffix for anything stored per book, or '' for the
  /// legacy file. `CloudSync` keys its two cursors on this so the marks travel
  /// with the book they describe.
  String get agentKey => _agentKey ?? '';

  /// Test seam. Sets which agent's book is "open" without touching a file, so
  /// the per-agent behaviour built on top of the key — notably `CloudSync`'s
  /// cursor names — can be exercised on the host, where there is no SQLCipher
  /// and no databases directory.
  @visibleForTesting
  static set testAgentKey(String? key) => instance._agentKey = key;

  /// Books set aside by [startFreshBook], newest first. Empty on web.
  Future<List<File>> setAsideBooks() async {
    if (kIsWeb) return const [];
    try {
      final dir = await getDatabasesPath();
      final prefix = '$_fileName.replaced-';
      final all = await Directory(dir).list().toList();
      final hits = all
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith(prefix))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return hits;
    } catch (_) {
      return const [];
    }
  }

  /// Put the most recently set-aside book back. The undo for [startFreshBook].
  ///
  /// Rename-not-delete is only honest if something can rename it back, and
  /// nothing else in this app can: a `.replaced-` file is invisible to the
  /// agent and reachable only over adb. The book created in its place is set
  /// aside in turn rather than deleted, so undo is itself undoable and no tap
  /// anywhere in this flow can destroy a collections row.
  Future<bool> restoreSetAsideBook() async {
    if (kIsWeb) return false;
    final books = await setAsideBooks();
    if (books.isEmpty) return false;
    await close();
    try {
      final dir = await getDatabasesPath();
      final current = File(p.join(dir, _fileName));
      if (await current.exists()) {
        final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
        await current.rename('${current.path}.discarded-$stamp');
      }
      await books.first.rename(p.join(dir, _fileName));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The DOP agent id this book belongs to, or null if it has never said.
  Future<String?> bookOwner() async {
    try {
      final db = await database;
      final r = await db.query('meta',
          where: 'key = ?', whereArgs: ['book_owner'], limit: 1);
      final v = r.isEmpty ? null : r.first['value'] as String?;
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null; // pre-v13 file mid-migration, or an unreadable book
    }
  }

  /// Record whose book this is. Written on every agent change and on every
  /// completed portal sync, so a book that has been used says so.
  Future<void> setBookOwner(String agentId) async {
    final id = Credentials.normaliseAgentId(agentId);
    if (id.isEmpty) return;
    try {
      final db = await database;
      await db.insert('meta', {'key': 'book_owner', 'value': id},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {/* never let a stamp failure break a sync or a login */}
  }

  Future<void> _createMeta(Database db) async {
    await db.execute("""
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    """);
  }

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

  /// The browser's store: real SQLite, compiled to WASM, persisted in
  /// IndexedDB by a shared worker (`web/sqflite_sw.js` + `web/sqlite3.wasm`,
  /// installed by `dart run sqflite_common_ffi_web:setup`).
  ///
  /// It runs the SAME schema and the SAME migrations as the handset, which is
  /// the whole reason for choosing it over talking to IndexedDB directly: every
  /// query in the app — the repositories, `v_accounts`, and all of `CloudSync`
  /// — is SQL, and a hand-rolled object store would have meant a second
  /// implementation of each, free to disagree with the first.
  ///
  /// SECURITY, AND IT IS A REAL DIFFERENCE: the handset file is SQLCipher
  /// AES-256. There is no SQLCipher build for the browser, so this store is
  /// UNENCRYPTED at rest. It is origin-scoped — only pages served from this
  /// exact origin can read it — but anyone with the unlocked machine can open
  /// devtools and read the book. That is a weaker promise than the phone makes
  /// and the Privacy Policy has to say so.
  Future<Database> _openWeb() async {
    final factory = databaseFactoryFfiWeb;
    // Same name as the handset file, so the two are recognisably one app —
    // including the per-agent suffix, so a browser shared by two agents keeps
    // two stores exactly as a shared handset does.
    return factory.openDatabase(_fileName, options: _options);
  }

  Future<Database> _open() async {
    // The whole of the block below — a databases path, a Keystore key, a
    // plaintext-to-encrypted migration, a file to move aside when the key is
    // lost — is about a FILE. The browser has none of those things.
    if (kIsWeb) return _openWeb();

    final dir = await getDatabasesPath();
    final path = p.join(dir, _fileName);
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

  /// The schema version, and the ONLY place it is written.
  static const schemaVersion = 13;

  /// Create/upgrade/open, extracted so the phone's SQLCipher file and the
  /// browser's WASM-SQLite store are opened with the SAME callbacks.
  ///
  /// That is the point of pulling them out. If the two backends each carried
  /// their own copy of the migration chain, a column added to one would be
  /// missing on the other, and `CloudSync` — which reads and writes both by
  /// the same column names — would fail on whichever device was behind.
  OpenDatabaseOptions get _options => OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onOpen: _onOpen,
      );

  Future<Database> _openAt(String path, String key, bool encrypted) {
    return openDatabase(
      path,
      // Only pass the key once the file is actually encrypted; otherwise open
      // the plaintext DB as-is (migration failed / not yet done) so the app
      // never fails to start and no data is lost.
      password: encrypted ? key : null,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _onOpen,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
        await _createAccounts(db);
        await _createLots(db);
        await _createCollections(db);
        // Fresh installs get the sync columns here rather than in the create
        // statements above, so there is exactly ONE definition of them and a
        // new phone cannot end up with a different shape from an upgraded one.
        await _addSyncColumns(db);
        await _createMeta(db);
        await _createAssistantView(db);
        await _createLedgerViews(db);
  }

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
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
        if (oldV < 9) {
          await _addClosedColumn(db);
          // v_accounts now filters on closed_at, so it must be rebuilt — it
          // carries no data, so dropping and recreating it is always safe.
          await _createAssistantView(db);
        }
        if (oldV < 10) {
          // v_accounts had its own definitions of "new" and "maturing" that
          // disagreed with the app's, and exposed `status` — a column nothing
          // has written since the collections ledger replaced it. Rebuilt.
          await _createAssistantView(db);
        }
        if (oldV < 11) {
          // The term boundary moved from `months_paid > 60` to `>= 60`, so
          // is_maturity stops calling a continued (ten-year) account matured
          // five years early. The view holds no data, so rebuilding it is
          // always safe.
          await _createAssistantView(db);
        }
        if (oldV < 12) {
          await _addSyncColumns(db);
          // Both ledger views now hide soft-deleted rows.
          await _createLedgerViews(db);
        }
        if (oldV < 13) await _createMeta(db);
  }

  /// Force key validation NOW so a bad/lost key fails here (recoverable in
  /// [_open]) instead of later, mid-screen, as a crash.
  Future<void> _onOpen(Database db) async {
    await db.rawQuery('SELECT count(*) FROM sqlite_master');
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
        daily_amount          INTEGER,
        closed_at             TEXT
      )
    ''');
    await db
        .execute('CREATE INDEX idx_accounts_due ON accounts(next_due_date)');
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

  /// v9: the closure stamp. Before this column existed, an account that matured
  /// and closed stayed in the book forever — `replaceAll` is an upsert and
  /// nothing else ever deleted a row. It then aged into a permanent defaulter
  /// (its next due date receding a month at a time), kept its old short code
  /// while the live book renumbered around it, and sat in the daily round for a
  /// customer who no longer had an account.
  Future<void> _addClosedColumn(Database db) async {
    await db.execute('ALTER TABLE accounts ADD COLUMN closed_at TEXT');
  }

  /// v12: the columns two-way sync needs, on the two tables the agent OWNS.
  ///
  /// `accounts` is not one of them in the same way. It is re-derived from the
  /// portal on every sync and rows are never deleted — an account that leaves
  /// the listing gets `closed_at` stamped, which already travels as an ordinary
  /// field — so it needs a stamp and nothing else.
  ///
  ///   uid         stable row identity across devices. See [newUid].
  ///   updated_at  when THIS device last touched the row. It is both the
  ///               conflict rule on the server (`client_updated_at`) and the
  ///               local "not pushed yet" marker, which is why there is no
  ///               separate outbox table to drift out of step with the data.
  ///   deleted     tombstone. `remove()` used to DELETE the row, and a row that
  ///               is gone cannot tell the other device it went — so an undone
  ///               collection stayed on the desktop as money the agent says he
  ///               never took.
  ///
  /// Written to be safely re-runnable, and that is not belt-and-braces: a
  /// device coming from a schema older than v7 runs `_createCollections`
  /// during the SAME upgrade, and a fresh install runs this straight after
  /// `onCreate`. Blindly issuing ALTER TABLE in either case fails the whole
  /// migration with "duplicate column name", which on this app means the
  /// database will not open.
  Future<void> _addSyncColumns(Database db) async {
    Future<Set<String>> columnsOf(String table) async =>
        (await db.rawQuery('PRAGMA table_info($table)'))
            .map((r) => '${r['name']}')
            .toSet();

    Future<void> add(String table, String column, String decl) async {
      if ((await columnsOf(table)).contains(column)) return;
      await db.execute('ALTER TABLE $table ADD COLUMN $column $decl');
    }

    for (final table in const ['collections', 'lots']) {
      await add(table, 'uid', 'TEXT');
      await add(table, 'updated_at', 'TEXT');
      await add(table, 'deleted', 'INTEGER NOT NULL DEFAULT 0');

      // Backfill in Dart: SQLite has no uuid(), and every existing row needs an
      // id the OTHER device will agree with forever. Done once, here, so the
      // agent's whole history joins the sync rather than only what he does from
      // today onwards.
      final blank = await db.query(table,
          columns: ['id'], where: 'uid IS NULL OR uid = \'\'');
      if (blank.isNotEmpty) {
        final batch = db.batch();
        for (final r in blank) {
          batch.update(table, {'uid': newUid()},
              where: 'id = ?', whereArgs: [r['id']]);
        }
        await batch.commit(noResult: true);
      }

      // Partial index: rows still carrying a NULL uid (a restore from a backup
      // taken before v12, before its own backfill runs) must not collide with
      // each other.
      await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_uid '
          'ON $table(uid) WHERE uid IS NOT NULL');
      // Every sync push is "rows changed since last time".
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_updated '
          'ON $table(updated_at)');
    }

    await add('accounts', 'updated_at', 'TEXT');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_accounts_updated '
        'ON accounts(updated_at)');
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
    // Derived opening date, IDENTICAL to `RdAccount.derivedOpeningDate`: next
    // due minus months_paid months, with the day CLAMPED to the target month
    // rather than allowed to overflow. SQLite's own `-N months` modifier
    // normalises (31 Mar - 1 month = 3 Mar) where Dart's clamps (28 Feb), so
    // doing it the lazy way would have reintroduced a divergence in the very
    // column added to remove one.
    const firstOfOpening = "date(a.next_due_date, 'start of month', "
        "'-' || a.months_paid || ' months')";
    const openingDay = "MIN("
        "CAST(strftime('%d', a.next_due_date) AS INTEGER), "
        "CAST(strftime('%d', date($firstOfOpening, '+1 month', '-1 day')) "
        "AS INTEGER))";
    const derivedOpening =
        "date($firstOfOpening, '+' || ($openingDay - 1) || ' days')";
    // Term: 60 months, or 120 for an account continued past five years — the
    // same inference `RdAccount.termMonths` makes, INCLUDING its boundary.
    // Every row in this view is a live account (closed ones are excluded
    // below), so the portal still names a next installment for it; 60 paid
    // therefore means the 61st is due and the account ran on to ten years.
    // `> 60` called that account matured and put it in is_maturity a full
    // five years early.
    const term = 'CASE WHEN a.months_paid >= 60 THEN 120 ELSE 60 END';
    const toMaturity = 'MAX(0, $term - a.months_paid)';

    await db.execute('DROP VIEW IF EXISTS v_accounts');
    await db.execute('''
      CREATE VIEW v_accounts AS
      SELECT
        a.account_number,
        a.customer_name,
        a.denomination_amount,
        a.months_paid,
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
        -- Maturity: within two installments of the end of the term. Was
        -- `months_paid BETWEEN 58 AND 61`, which disagreed with the app in
        -- BOTH directions — it called a 61-month account (just continued to
        -- ten years, 59 still to run) maturing, and did not call a 119-month
        -- one maturing at all. Now the same rule as `AccountFilter.maturity`.
        CASE
          WHEN a.pending_installments IS NOT NULL
            THEN (CASE WHEN a.pending_installments <= 2 THEN 1 ELSE 0 END)
          WHEN a.months_paid > 0 AND $toMaturity <= 2 THEN 1
          ELSE 0
        END                                                AS is_maturity,
        -- The account's opening date: the exact one when a detail fetch has
        -- stored it, else derived. Matches `RdAccount.effectiveOpeningDate`.
        COALESCE(date(a.opening_date), $derivedOpening)    AS opening_on,
        -- New: opened in the CURRENT calendar month, which is what
        -- `AccountFilter.newAccounts` means at its default window of 1. This
        -- was `months_paid <= 3` (or a 3-month window on the exact opening
        -- date), so the assistant and the home screen disagreed about which
        -- accounts were new, and by how many.
        --
        -- The agent can widen the app's window to 2 or 3 months; a view cannot
        -- see that setting, so a widened window is answered from `opening_on`
        -- instead — see the schema prompt.
        CASE WHEN COALESCE(date(a.opening_date), $derivedOpening)
                  >= date('now','localtime','start of month')
             THEN 1 ELSE 0 END                             AS is_new,
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
      -- Closed accounts are excluded outright. Every column above is a
      -- statement about a LIVE account: `months_behind` on a closed one grows
      -- by one every month forever, so leaving them in made the assistant
      -- report matured customers as the agent's worst defaulters.
      WHERE a.closed_at IS NULL
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
      -- Soft-deleted rows are an Undo the agent already pressed. They stay in
      -- the table so the delete can reach his other device, but every question
      -- asked of this view -- what came in today, what this cycle totals -- is
      -- about money he actually took.
      WHERE c.deleted = 0
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
      WHERE l.deleted = 0
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
