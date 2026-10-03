import 'dart:convert';

import 'package:dop_collect/services/cloud_sync.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Sync, against a real SQLite.
///
/// The merge rules are the whole point of this file, and a mock database would
/// prove nothing about them — it would agree with the implementation by
/// construction. `sqflite_common_ffi` runs the actual engine on the host, so
/// UPDATE-by-uid, the tombstone column and the unique index behave the way they
/// will on a handset.
///
/// The SESSION is faked (there is no Keystore here) by pointing the client at a
/// stub server; every assertion below is either about what reached the wire or
/// about what ended up in the database.
void main() {
  // Needed before any platform channel is stubbed, and before
  // SharedPreferences' mock values are read.
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late List<Map<String, dynamic>> sent;
  late List<Map<String, dynamic>> replies;

  /// The v12 shape of the three tables, as `AppDatabase` leaves them.
  Future<Database> freshDb() async {
    final d = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await d.execute('''
      CREATE TABLE accounts (
        account_number TEXT PRIMARY KEY, customer_name TEXT NOT NULL,
        denomination_amount INTEGER NOT NULL, next_due_date TEXT NOT NULL,
        months_paid INTEGER NOT NULL, serial INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending', aslaas TEXT, opening_date TEXT,
        total_deposit INTEGER, pending_installments INTEGER,
        default_installments INTEGER, last_deposit_date TEXT,
        route_order INTEGER, daily_amount INTEGER, closed_at TEXT,
        updated_at TEXT)''');
    await d.execute('''
      CREATE TABLE collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT, account_number TEXT NOT NULL,
        amount INTEGER NOT NULL, installments INTEGER NOT NULL DEFAULT 1,
        collected_at TEXT NOT NULL, cycle_ym TEXT NOT NULL, note TEXT,
        uid TEXT, updated_at TEXT, deleted INTEGER NOT NULL DEFAULT 0)''');
    await d.execute('CREATE UNIQUE INDEX idx_collections_uid '
        'ON collections(uid) WHERE uid IS NOT NULL');
    await d.execute('''
      CREATE TABLE lots (
        id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL,
        mode TEXT NOT NULL, items_json TEXT NOT NULL, reference_number TEXT,
        submitted_at TEXT, item_count INTEGER NOT NULL DEFAULT 0,
        total_amount INTEGER NOT NULL DEFAULT 0,
        uid TEXT, updated_at TEXT, deleted INTEGER NOT NULL DEFAULT 0)''');
    return d;
  }

  /// Queue one reply per expected request. Anything beyond the queue is an
  /// empty, quiet success — which is what the pull loop needs to terminate.
  http.Client stub() => MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        final body = replies.isNotEmpty
            ? replies.removeAt(0)
            : {'ok': true, 'pull': {}, 'cursor': {}, 'more': false, 'pushed': {}};
        return http.Response(jsonEncode(body), 200);
      });

  setUp(() async {
    db = await freshDb();
    sent = [];
    replies = [];
    SharedPreferences.setMockInitialValues({});
    SupabaseConfig.testUrl = 'https://stub.test';
    SupabaseConfig.testAnonKey = 'anon-test';
    CloudSync.client = stub();
    await CloudSync.resetCursors();
  });

  tearDown(() async {
    await db.close();
    SupabaseConfig.testUrl = null;
    SupabaseConfig.testAnonKey = null;
  });

  Future<void> collection(String uid, int amount, String stamp,
          {int deleted = 0}) =>
      db.insert('collections', {
        'account_number': '020000000001',
        'amount': amount,
        'installments': 1,
        'collected_at': '2026-09-01T10:00:00.000Z',
        'cycle_ym': '2026-09',
        'uid': uid,
        'updated_at': stamp,
        'deleted': deleted,
      });

  List<Map<String, dynamic>> pushedRows(String table) => [
        for (final r in sent)
          if (r['push'] is Map && (r['push'] as Map)[table] is List)
            ...((r['push'] as Map)[table] as List)
                .cast<Map<String, dynamic>>()
      ];

  // -------------------------------------------------------------------------
  // Guards before anything is sent
  // -------------------------------------------------------------------------

  test('with no session, nothing reaches the wire', () async {
    final r = await CloudSync.run(db: db);
    expect(r.ok, isFalse);
    expect(r.code, 'no_session');
    expect(sent, isEmpty);
  });

  // -------------------------------------------------------------------------
  // Everything below needs a session
  // -------------------------------------------------------------------------
  group('with a verified session', () {
    setUp(() async {
      // SessionStore reads the Keystore, which does not exist on the host.
      // The platform channel is stubbed to answer as though a token is stored.
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') {
          final key = (call.arguments as Map)['key'] as String;
          return switch (key) {
            'otp_session_token' => 'tok-123',
            'otp_session_account' => 'acct-1',
            'otp_session_phone' => '9876543210',
            'otp_session_agent' => 'AGENT01',
            _ => null,
          };
        }
        return null;
      });
    });

    test('an unreachable server is a report, not a throw', () async {
      // At a customer's door with no signal is the NORMAL case, not an error
      // state — it must never take a screen down.
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      CloudSync.client =
          MockClient((_) async => throw const SocketExceptionStub());
      final r = await CloudSync.run(db: db);
      expect(r.ok, isFalse);
      expect(r.code, 'offline');
    });

    test('a dirty collection is pushed with its own stamp as the conflict key',
        () async {
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      final r = await CloudSync.run(db: db);
      expect(r.ok, isTrue, reason: r.message);

      final rows = pushedRows('collections');
      expect(rows, hasLength(1));
      expect(rows.first['uid'], 'u1');
      expect(rows.first['amount'], 500);
      // The server settles conflicts on THIS, so it must be the row's own
      // stamp — not the moment the request happened to be built.
      expect(rows.first['client_updated_at'], '2026-09-01T10:00:00.000Z');
    });

    test('a tombstone is pushed as a deletion, not omitted', () async {
      // An undone handover has to travel. If it does not, the other device
      // goes on showing cash the agent says he never took.
      await collection('u1', 500, '2026-09-01T10:00:00.000Z', deleted: 1);
      await CloudSync.run(db: db);
      final rows = pushedRows('collections');
      expect(rows, hasLength(1));
      expect(rows.first['deleted'], isTrue);
    });

    test('the high-water mark comes from the batch, not from now()', () async {
      // THE regression this design exists to prevent. The agent takes cash at
      // a door WHILE the request is in flight; that row is newer than
      // everything sent, and a mark set to "now" would file it as already sent
      // and it would never leave the phone.
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      await CloudSync.run(db: db);

      final prefs = await SharedPreferences.getInstance();
      final mark = jsonDecode(prefs.getString('sync_pushed_high_water')!)
          as Map<String, dynamic>;
      expect(mark['collections'], '2026-09-01T10:00:00.000Z');

      // Now the row that landed mid-flight.
      await collection('u2', 700, '2026-09-01T10:00:30.000Z');
      sent.clear();
      await CloudSync.run(db: db);
      expect(pushedRows('collections').map((r) => r['uid']), ['u2'],
          reason: 'the mid-flight row must still be pending');
    });

    test('a row already pushed is not pushed again', () async {
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      await CloudSync.run(db: db);
      sent.clear();
      await CloudSync.run(db: db);
      expect(pushedRows('collections'), isEmpty);
    });

    test('a pulled row lands in the database and does NOT become dirty',
        () async {
      // The ping-pong guard. Written with the SERVER's stamp, so the next
      // sync does not push it straight back as a local edit — two devices
      // would otherwise trade the same row forever.
      replies.add({
        'ok': true,
        'pull': {
          'collections': [
            {
              'uid': 'from-desktop',
              'account_number': '020000000001',
              'amount': 900,
              'installments': 1,
              'collected_at': '2026-09-02T09:00:00.000Z',
              'cycle_ym': '2026-09',
              'deleted': false,
              'client_updated_at': '2026-09-02T09:00:00.000Z',
            }
          ]
        },
        'cursor': {
          'collections': {'t': '2026-09-02T09:00:01.000Z', 'k': 'from-desktop'}
        },
        'more': false,
        'pushed': {},
      });
      final r = await CloudSync.run(db: db);
      expect(r.pulled, 1);

      final local = await db.query('collections', where: "uid = 'from-desktop'");
      expect(local, hasLength(1));
      expect(local.first['amount'], 900);
      expect(local.first['updated_at'], '2026-09-02T09:00:00.000Z');

      sent.clear();
      await CloudSync.run(db: db);
      expect(pushedRows('collections'), isEmpty,
          reason: 'a pulled row must not be pushed back');
    });

    test('a pulled edit updates by uid and keeps the local row id', () async {
      // The UI holds `id` in list state. Replacing the row instead of updating
      // it would renumber it under the agent's finger mid-scroll.
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      final before =
          (await db.query('collections', where: "uid = 'u1'")).first['id'];

      replies.add({'ok': true, 'pull': {}, 'cursor': {}, 'more': false, 'pushed': {}});
      replies.add({
        'ok': true,
        'pull': {
          'collections': [
            {
              'uid': 'u1',
              'account_number': '020000000001',
              'amount': 650, // corrected on the other device
              'installments': 1,
              'collected_at': '2026-09-01T10:00:00.000Z',
              'cycle_ym': '2026-09',
              'deleted': false,
              'client_updated_at': '2026-09-03T08:00:00.000Z',
            }
          ]
        },
        'cursor': {},
        'more': false,
        'pushed': {},
      });
      await CloudSync.run(db: db);

      final rows = await db.query('collections', where: "uid = 'u1'");
      expect(rows, hasLength(1), reason: 'must not duplicate the row');
      expect(rows.first['amount'], 650);
      expect(rows.first['id'], before, reason: 'the local id must survive');
    });

    test('a pulled tombstone hides the row locally', () async {
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      replies.add({'ok': true, 'pull': {}, 'cursor': {}, 'more': false, 'pushed': {}});
      replies.add({
        'ok': true,
        'pull': {
          'collections': [
            {
              'uid': 'u1',
              'account_number': '020000000001',
              'amount': 500,
              'installments': 1,
              'collected_at': '2026-09-01T10:00:00.000Z',
              'cycle_ym': '2026-09',
              'deleted': true,
              'client_updated_at': '2026-09-03T08:00:00.000Z',
            }
          ]
        },
        'cursor': {},
        'more': false,
        'pushed': {},
      });
      await CloudSync.run(db: db);
      final live = await db.query('collections', where: 'deleted = 0');
      expect(live, isEmpty);
    });

    test('the pull loops while the server says more', () async {
      // Nothing local is dirty, so there is no push leg — the first reply
      // queued here is answered to the first PULL.
      for (var page = 0; page < 3; page++) {
        replies.add({
          'ok': true,
          'pull': {
            'lots': [
              {
                'uid': 'lot-$page',
                'created_at': '2026-09-0${page + 1}T10:00:00.000Z',
                'mode': 'cash',
                'items_json': '[]',
                'item_count': 1,
                'total_amount': 100,
                'deleted': false,
                'client_updated_at': '2026-09-0${page + 1}T10:00:00.000Z',
              }
            ]
          },
          'cursor': {},
          'more': page < 2,
          'pushed': {},
        });
      }
      final r = await CloudSync.run(db: db);
      expect(r.pulled, 3);
      expect((await db.query('lots')).length, 3);
    });

    test('a revoked session stops the sync and says so', () async {
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      replies.add({'ok': false, 'code': 'no_session'});
      final r = await CloudSync.run(db: db);
      expect(r.ok, isFalse);
      expect(r.code, 'no_session');

      // And the mark must NOT have advanced — the row still has to go.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_pushed_high_water'), isNull);
    });

    test('accounts are applied before collections', () async {
      // A collection names an account number and the khata joins the two. The
      // other order shows handovers against customers that do not exist yet.
      replies.add({
        'ok': true,
        'pull': {
          'accounts': [
            {
              'account_number': '020000000009',
              'customer_name': 'NEW CUSTOMER',
              'denomination_amount': 1000,
              'next_due_date': '2026-10-01T00:00:00.000Z',
              'months_paid': 2,
              'client_updated_at': '2026-09-02T09:00:00.000Z',
            }
          ],
          'collections': [
            {
              'uid': 'c9',
              'account_number': '020000000009',
              'amount': 1000,
              'installments': 1,
              'collected_at': '2026-09-02T09:00:00.000Z',
              'cycle_ym': '2026-09',
              'deleted': false,
              'client_updated_at': '2026-09-02T09:00:00.000Z',
            }
          ],
        },
        'cursor': {},
        'more': false,
        'pushed': {},
      });
      await CloudSync.run(db: db);
      final joined = await db.rawQuery(
          'SELECT a.customer_name FROM collections c '
          'JOIN accounts a ON a.account_number = c.account_number');
      expect(joined.single['customer_name'], 'NEW CUSTOMER');
    });

    test('resetCursors forces a full re-pull without deleting anything',
        () async {
      await collection('u1', 500, '2026-09-01T10:00:00.000Z');
      await CloudSync.run(db: db);
      await CloudSync.resetCursors();
      sent.clear();
      await CloudSync.run(db: db);
      expect(pushedRows('collections').map((r) => r['uid']), ['u1']);
      expect((await db.query('collections')).length, 1,
          reason: 'a reset must never drop local rows');
    });
  });
}

/// A throw the http client will surface as "offline" without dragging
/// `dart:io` into a test that otherwise does not need it.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
