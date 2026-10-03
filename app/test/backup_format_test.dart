import 'dart:convert';
import 'dart:typed_data';

import 'package:dop_collect/services/backup_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// A book roughly the shape of a real one: accounts from the portal, a ledger of
/// cash taken at the door, and the lists built from it.
Map<String, List<Map<String, Object?>>> _book() => {
      'accounts': [
        {
          'account_number': '1234567890',
          'customer_name': 'Sita Devi',
          'denomination_amount': 500,
          'next_due_date': '2026-08-01',
          'months_paid': 12,
          'serial': 1,
          'status': 'pending',
          'aslaas': 'A-9',
          'route_order': 3,
          'daily_amount': null,
        },
      ],
      'collections': [
        {
          'id': 1,
          'account_number': '1234567890',
          'amount': 500,
          'installments': 1,
          'collected_at': '2026-08-14T09:30:00.000',
          'cycle_ym': '2026-08',
          'note': null,
        },
      ],
      'lots': [
        {
          'id': 1,
          'created_at': '2026-08-14T10:00:00.000',
          'mode': 'Cash',
          'items_json': '[{"a":"1234567890","d":500,"i":1}]',
          'reference_number': 'C123',
          'submitted_at': '2026-08-14T10:05:00.000',
          'item_count': 1,
          'total_amount': 500,
        },
      ],
    };

Map<String, Object?> _prefs() => {
      'agent_name': 'Rita Devi',
      'aslaas_number': 'A-9',
      'daily_rule_days': 30,
      'day_closed_on': '2026-08-14',
      'rd_rate_history_v1': '',
    };

String _body() => BackupFormat.encode(
      tables: _book(),
      prefs: _prefs(),
      takenAt: DateTime.utc(2026, 8, 14, 12),
      appVersion: '0.9.52+26',
    );

void main() {
  group('round trip', () {
    test('a sealed backup opens with the same passphrase and is unchanged', () {
      final sealed = BackupFormat.seal(_body(), 'chai-garam-42');
      final out = BackupFormat.decode(BackupFormat.open(sealed, 'chai-garam-42'));

      expect(out.accounts, 1);
      expect(out.collections, 1);
      expect(out.lots, 1);
      expect(out.prefs['agent_name'], 'Rita Devi');
      // The ledger is the whole point — check a value, not just a count.
      expect(out.tables['collections']!.first['amount'], 500);
      expect(out.tables['lots']!.first['reference_number'], 'C123');
      expect(out.tables['accounts']!.first['route_order'], 3,
          reason: 'route_order exists nowhere but this phone');
    });

    test('a null column survives as null, not as a missing key', () {
      final out = BackupFormat.decode(
          BackupFormat.open(BackupFormat.seal(_body(), 'pw'), 'pw'));
      final acc = out.tables['accounts']!.first;
      expect(acc.containsKey('daily_amount'), isTrue);
      expect(acc['daily_amount'], isNull);
    });

    test('an empty book round-trips rather than throwing', () {
      final body = BackupFormat.encode(
        tables: const {'accounts': [], 'collections': [], 'lots': []},
        prefs: const {},
        takenAt: DateTime.utc(2026, 1, 1),
        appVersion: '0.9.52+26',
      );
      final out =
          BackupFormat.decode(BackupFormat.open(BackupFormat.seal(body, 'x'), 'x'));
      expect(out.accounts, 0);
      expect(out.collections, 0);
    });

    test('two seals of the same body differ — salt and iv are per-file', () {
      final a = BackupFormat.seal(_body(), 'pw');
      final b = BackupFormat.seal(_body(), 'pw');
      expect(a, isNot(equals(b)));
      // ...and both still open.
      expect(BackupFormat.decode(BackupFormat.open(a, 'pw')).accounts, 1);
      expect(BackupFormat.decode(BackupFormat.open(b, 'pw')).accounts, 1);
    });
  });

  group('the ways an agent actually fails', () {
    test('wrong passphrase says so, and does not leak a partial read', () {
      final sealed = BackupFormat.seal(_body(), 'right');
      expect(
        () => BackupFormat.open(sealed, 'wrong'),
        throwsA(isA<BackupError>()
            .having((e) => e.fault, 'fault', BackupFault.wrongPassphrase)),
      );
    });

    test('an empty passphrase is still just a wrong one', () {
      final sealed = BackupFormat.seal(_body(), 'right');
      expect(
        () => BackupFormat.open(sealed, ''),
        throwsA(isA<BackupError>()
            .having((e) => e.fault, 'fault', BackupFault.wrongPassphrase)),
      );
    });

    test('picking some other file is told apart from a bad password', () {
      final notOurs = Uint8List.fromList(utf8.encode('just a photo, really'));
      expect(
        () => BackupFormat.open(notOurs, 'pw'),
        throwsA(isA<BackupError>()
            .having((e) => e.fault, 'fault', BackupFault.notABackup)),
      );
    });

    test('a truncated file is corrupt, not silently half-restored', () {
      final sealed = BackupFormat.seal(_body(), 'pw');
      final cut = Uint8List.sublistView(sealed, 0, 20);
      expect(() => BackupFormat.open(cut, 'pw'), throwsA(isA<BackupError>()));
    });

    test('a flipped byte in the ciphertext fails GCM rather than restoring', () {
      final sealed = BackupFormat.seal(_body(), 'pw');
      sealed[sealed.length - 5] ^= 0xFF;
      expect(
        () => BackupFormat.open(sealed, 'pw'),
        throwsA(isA<BackupError>()),
      );
    });

    test('a backup from a NEWER app is refused, not partly read', () {
      final sealed = BackupFormat.seal(_body(), 'pw');
      sealed[BackupFormat.magic.length] = BackupFormat.version + 1;
      expect(
        () => BackupFormat.open(sealed, 'pw'),
        throwsA(isA<BackupError>()
            .having((e) => e.fault, 'fault', BackupFault.tooNew)),
      );
    });

    test('a body that is not our JSON is corrupt', () {
      expect(() => BackupFormat.decode('{"hello":1}'),
          throwsA(isA<BackupError>()
              .having((e) => e.fault, 'fault', BackupFault.corrupt)));
      expect(() => BackupFormat.decode('not json at all'),
          throwsA(isA<BackupError>()));
    });

    test('every fault explains itself without jargon', () {
      for (final f in BackupFault.values) {
        final m = BackupError(f).message;
        expect(m, isNotEmpty);
        expect(m, isNot(contains('Exception')));
        expect(m.endsWith('.'), isTrue, reason: '$f reads as a sentence');
      }
    });
  });

  test('the file name is dated so a folder of them sorts', () {
    expect(BackupFormat.fileNameFor(DateTime(2026, 8, 14)),
        'DOP-khata-2026-08-14.dopbackup');
    expect(BackupFormat.fileNameFor(DateTime(2026, 1, 5)),
        'DOP-khata-2026-01-05.dopbackup');
  });

  test('the passphrase is not recoverable from the file', () {
    final sealed = BackupFormat.seal(_body(), 'chai-garam-42');
    final asText = utf8.decode(sealed, allowMalformed: true);
    expect(asText.contains('chai-garam-42'), isFalse);
    expect(asText.contains('Sita Devi'), isFalse,
        reason: 'customer names must not appear in the clear');
  });
}
