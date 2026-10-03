import 'dart:convert';

import 'package:dop_collect/data/database.dart';
import 'package:dop_collect/services/cloud_sync.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One book per agent.
///
/// The bug this file exists for: logging out of agent A and into agent B on the
/// same phone merged both books into one table, and the closure guard then
/// refused to close anything ever again, so it never recovered. Everything
/// below is about the two things that stop it — a file key that cannot be
/// shared, and sync marks that travel with the book they describe rather than
/// with the device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('agentKeyFor', () {
    // The three forms Credentials.normaliseAgentId already exists to
    // reconcile. If they keyed different files, one agent would own three
    // books and none of them would be complete.
    test('the prefixed, bare and lower-case forms are ONE book', () {
      const canonical = 'DOP.MI847235010005';
      final key = AppDatabase.agentKeyFor(canonical);
      for (final form in const [
        'MI847235010005',
        'dop.mi847235010005',
        '  DOP.MI847235010005  ',
        'DOP.DOP.MI847235010005',
      ]) {
        expect(AppDatabase.agentKeyFor(form), key, reason: form);
      }
    });

    test('two agents never share a key', () {
      // One digit apart on purpose: these two ids are a real pair from this
      // deployment, and they are the case a truncated hash has to separate.
      expect(AppDatabase.agentKeyFor('DOP.MI847235010005'),
          isNot(AppDatabase.agentKeyFor('DOP.MI8472350100005')));
    });

    test('an empty id has no key, so it can never claim a book', () {
      expect(AppDatabase.agentKeyFor(''), '');
      expect(AppDatabase.agentKeyFor('   '), '');
      expect(AppDatabase.agentKeyFor('DOP.'), '');
    });

    test('the book file is named per agent, and the legacy name is kept', () {
      AppDatabase.testAgentKey = null;
      expect(AppDatabase.instance.fileName, 'dop_collect.db',
          reason: 'every pre-v13 install still has this file');
      AppDatabase.testAgentKey = 'abc123abc123abc1';
      expect(AppDatabase.instance.fileName, 'dop_collect_abc123abc123abc1.db');
      AppDatabase.testAgentKey = null;
    });

    test('an empty agent id never re-keys the open book', () async {
      // Credentials.load() degrades to empty when the Keystore will not open.
      // Treating that as "no agent" would swap a working book for an empty one
      // and invite the agent to sync over it.
      AppDatabase.testAgentKey = 'aaaa111122223333';
      await AppDatabase.instance.useAgent('');
      await AppDatabase.instance.useAgent('   ');
      await AppDatabase.instance.useAgent('DOP.');
      expect(AppDatabase.instance.agentKey, 'aaaa111122223333');
      AppDatabase.testAgentKey = null;
    });

    test('the key is 16 hex characters and reveals no agent id', () {
      final key = AppDatabase.agentKeyFor('DOP.MI847235010005');
      expect(key, hasLength(16));
      expect(key, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(key.toUpperCase(), isNot(contains('MI847')));
    });
  });

  group('sync marks are keyed per agent', () {
    late Database db;
    late List<Map<String, dynamic>> replies;

    Future<Database> freshDb() async {
      final d = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await d.execute('''
        CREATE TABLE accounts (
          account_number TEXT PRIMARY KEY, customer_name TEXT NOT NULL,
          denomination_amount INTEGER NOT NULL, next_due_date TEXT NOT NULL,
          months_paid INTEGER NOT NULL, serial INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending', aslaas TEXT,
          opening_date TEXT, total_deposit INTEGER,
          pending_installments INTEGER, default_installments INTEGER,
          last_deposit_date TEXT, route_order INTEGER, daily_amount INTEGER,
          closed_at TEXT, updated_at TEXT)''');
      await d.execute('''
        CREATE TABLE collections (
          id INTEGER PRIMARY KEY AUTOINCREMENT, account_number TEXT NOT NULL,
          amount INTEGER NOT NULL, installments INTEGER NOT NULL DEFAULT 1,
          collected_at TEXT NOT NULL, cycle_ym TEXT NOT NULL, note TEXT,
          uid TEXT, updated_at TEXT, deleted INTEGER NOT NULL DEFAULT 0)''');
      await d.execute('''
        CREATE TABLE lots (
          id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL,
          mode TEXT NOT NULL, items_json TEXT NOT NULL,
          reference_number TEXT, submitted_at TEXT,
          item_count INTEGER NOT NULL DEFAULT 0,
          total_amount INTEGER NOT NULL DEFAULT 0,
          uid TEXT, updated_at TEXT, deleted INTEGER NOT NULL DEFAULT 0)''');
      return d;
    }

    setUp(() async {
      db = await freshDb();
      replies = [];
      SharedPreferences.setMockInitialValues({});
      SupabaseConfig.testUrl = 'https://stub.test';
      SupabaseConfig.testAnonKey = 'anon-test';
      CloudSync.client = MockClient((req) async {
        final body = replies.isNotEmpty
            ? replies.removeAt(0)
            : {
                'ok': true,
                'pull': {},
                'cursor': {},
                'more': false,
                'pushed': {}
              };
        return http.Response(jsonEncode(body), 200);
      });
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

    tearDown(() async {
      await db.close();
      AppDatabase.testAgentKey = null;
      SupabaseConfig.testUrl = null;
      SupabaseConfig.testAnonKey = null;
    });

    Future<void> anAccount(String number, String stamp) => db.insert('accounts', {
          'account_number': number,
          'customer_name': 'Someone',
          'denomination_amount': 500,
          'next_due_date': '2026-10-15T00:00:00.000',
          'months_paid': 12,
          'updated_at': stamp,
        });

    test('the cursors are written under the open agent, not the device',
        () async {
      AppDatabase.testAgentKey = 'aaaa111122223333';
      await anAccount('020000000001', '2026-09-01T10:00:00.000Z');
      replies.add({
        'ok': true,
        'pushed': {'accounts': 1},
        'pull': {},
        'cursor': {'accounts': 'c-1'},
        'more': false,
      });
      await CloudSync.run(db: db);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_pushed_high_water_aaaa111122223333'),
          isNotNull);
      // The device-wide names must stay empty, or the next agent inherits them.
      expect(prefs.getString('sync_pushed_high_water'), isNull);
      expect(prefs.getString('sync_cursor'), isNull);
    });

    test("agent B never inherits agent A's high-water mark", () async {
      // A syncs.
      AppDatabase.testAgentKey = 'aaaa111122223333';
      await anAccount('020000000001', '2030-01-01T00:00:00.000Z');
      await CloudSync.run(db: db);
      final prefs = await SharedPreferences.getInstance();
      final aMark = prefs.getString('sync_pushed_high_water_aaaa111122223333');
      expect(aMark, isNotNull);

      // B signs in on the same phone with his own (empty) book.
      AppDatabase.testAgentKey = 'bbbb444455556666';
      expect(prefs.getString('sync_pushed_high_water_bbbb444455556666'), isNull,
          reason: "B starts with no mark, so B's first pull is not skipped");

      // ...and A's mark is still there for A, so switching back is cheap.
      expect(
          prefs.getString('sync_pushed_high_water_aaaa111122223333'), aMark);
    });

    test('a pulled account with no due date is skipped, not fatal', () async {
      // book_accounts.next_due_date is nullable on the server;
      // accounts.next_due_date is TEXT NOT NULL here. One null used to abort
      // the whole pull, and the cursor is only saved afterwards — so the same
      // page was refetched forever and sync silently stopped working.
      AppDatabase.testAgentKey = 'aaaa111122223333';
      replies.add({
        'ok': true,
        'pushed': {},
        'pull': {
          'accounts': [
            {
              'account_number': '020000000009',
              'customer_name': 'No Due Date',
              'denomination_amount': 500,
              'next_due_date': null,
              'months_paid': 3,
              'client_updated_at': '2026-09-02T10:00:00.000Z',
            },
            {
              'account_number': '020000000010',
              'customer_name': 'Perfectly Fine',
              'denomination_amount': 700,
              'next_due_date': '2026-11-15T00:00:00.000',
              'months_paid': 4,
              'client_updated_at': '2026-09-02T10:00:00.000Z',
            },
          ]
        },
        'cursor': {'accounts': 'c-9'},
        'more': false,
      });

      final r = await CloudSync.run(db: db);
      expect(r.ok, isTrue, reason: 'one unusable row must not fail the sync');

      final rows = await db.query('accounts', orderBy: 'account_number');
      expect(rows.map((r) => r['account_number']), ['020000000010'],
          reason: 'the good row lands; the unusable one is dropped');

      // And the cursor advanced, so the page is never refetched.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_cursor_aaaa111122223333'), isNotNull);
    });

    test('run() reports a failure instead of throwing', () async {
      // Its doc says "never throws", and main() + the home dashboard both call
      // it as unawaited(...) — so a throw here is an invisible dead sync.
      AppDatabase.testAgentKey = 'aaaa111122223333';
      await db.close(); // every query below now throws
      final r = await CloudSync.run(db: db);
      expect(r.ok, isFalse);
      expect(r.code, 'error');
      db = await freshDb(); // so tearDown has something to close
    });
  });
}
