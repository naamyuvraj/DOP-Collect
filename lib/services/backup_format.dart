import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// The on-disk shape of a khata backup file, and the crypto around it.
///
/// This is deliberately pure: no database, no plugins, no `dart:io`. Everything
/// here is a function of its inputs, so the whole format — including the failure
/// modes that matter (wrong passphrase, truncated file, a backup from a newer
/// app) — is testable on the CI machine rather than only on a handset.
///
/// WHY THIS EXISTS
/// ---------------
/// Uninstalling the app erases the `collections` ledger — every rupee the agent
/// took at a door. The portal can re-supply accounts via Deep Sync; it has never
/// heard of that money, and neither has our server. The app is also excluded
/// from cloud backup and device transfer on purpose, so there is no
/// Android-level safety net. This file is the safety net.
class BackupFormat {
  BackupFormat._();

  /// Bumped only when the JSON body changes shape in a way an older app cannot
  /// read. [restore] refuses anything above what it knows, because silently
  /// half-reading a backup is worse than declining it.
  static const int version = 1;

  static const String magic = 'DOPBACKUP';

  /// PBKDF2 rounds. High enough to make a stolen file expensive to attack,
  /// low enough that an entry-level handset finishes in about a second.
  static const int kdfRounds = 120000;

  static const int _saltBytes = 16;
  static const int _ivBytes = 12; // GCM standard

  /// Build the plaintext body. [tables] is the raw row data. [prefs] is carried
  /// by the format but empty for a khata backup — kept so the container can hold
  /// settings later without a version bump.
  static String encode({
    required Map<String, List<Map<String, Object?>>> tables,
    required Map<String, Object?> prefs,
    required DateTime takenAt,
    required String appVersion,
  }) {
    return jsonEncode({
      'magic': magic,
      'version': version,
      'taken_at': takenAt.toUtc().toIso8601String(),
      'app_version': appVersion,
      'tables': tables,
      'prefs': prefs,
    });
  }

  /// Parse a decrypted body. Throws [BackupError] on anything unreadable.
  static BackupPayload decode(String body) {
    late final Map<String, Object?> obj;
    try {
      obj = jsonDecode(body) as Map<String, Object?>;
    } catch (_) {
      throw const BackupError(BackupFault.corrupt);
    }
    if (obj['magic'] != magic) throw const BackupError(BackupFault.corrupt);

    final v = (obj['version'] as num?)?.toInt() ?? 0;
    // A backup written by a NEWER app may contain tables or columns this build
    // has never heard of. Restoring it partially would look like success and
    // quietly drop data, so refuse and say why.
    if (v > version) throw const BackupError(BackupFault.tooNew);
    if (v < 1) throw const BackupError(BackupFault.corrupt);

    final rawTables = obj['tables'];
    if (rawTables is! Map) throw const BackupError(BackupFault.corrupt);

    final tables = <String, List<Map<String, Object?>>>{};
    rawTables.forEach((k, v) {
      if (v is! List) throw const BackupError(BackupFault.corrupt);
      tables['$k'] = v
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList(growable: false);
    });

    return BackupPayload(
      version: v,
      takenAt: DateTime.tryParse('${obj['taken_at']}')?.toLocal(),
      appVersion: '${obj['app_version'] ?? ''}',
      tables: tables,
      prefs: Map<String, Object?>.from((obj['prefs'] as Map?) ?? const {}),
    );
  }

  /// Encrypt [body] under [passphrase].
  ///
  /// Layout: `DOPBACKUP1` ‖ salt(16) ‖ iv(12) ‖ AES-256-GCM ciphertext+tag.
  /// The header is plaintext on purpose — a restore has to be able to tell
  /// "this isn't one of our files" apart from "wrong passphrase", and the salt
  /// must be readable before any key exists.
  static Uint8List seal(String body, String passphrase) {
    final rnd = Random.secure();
    final salt =
        Uint8List.fromList(List<int>.generate(_saltBytes, (_) => rnd.nextInt(256)));
    final iv = Uint8List.fromList(
        List<int>.generate(_ivBytes, (_) => rnd.nextInt(256)));

    final key = enc.Key(_deriveKey(passphrase, salt));
    final sealer = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final cipher = sealer.encrypt(body, iv: enc.IV(iv)).bytes;

    return Uint8List.fromList([
      ...utf8.encode(magic),
      version,
      ...salt,
      ...iv,
      ...cipher,
    ]);
  }

  /// Reverse [seal]. Throws [BackupError] with the specific reason so the UI can
  /// say "wrong password" instead of a generic failure — the agent will mistype
  /// far more often than he will hand us a corrupt file.
  static String open(Uint8List bytes, String passphrase) {
    final head = utf8.encode(magic);
    // Identity BEFORE integrity. "You picked the wrong file" and "your backup is
    // damaged" send the agent to two different places, and a short file must not
    // masquerade as the second — the common case by far is a mis-tap in the file
    // picker, not a corrupt backup.
    if (bytes.length < head.length) {
      throw const BackupError(BackupFault.notABackup);
    }
    for (var i = 0; i < head.length; i++) {
      if (bytes[i] != head[i]) throw const BackupError(BackupFault.notABackup);
    }
    // From here it IS one of ours, so anything wrong with it is damage.
    final min = head.length + 1 + _saltBytes + _ivBytes;
    if (bytes.length <= min) throw const BackupError(BackupFault.corrupt);
    if (bytes[head.length] > version) {
      throw const BackupError(BackupFault.tooNew);
    }

    var at = head.length + 1;
    final salt = Uint8List.sublistView(bytes, at, at + _saltBytes);
    at += _saltBytes;
    final iv = Uint8List.sublistView(bytes, at, at + _ivBytes);
    at += _ivBytes;
    final cipher = Uint8List.sublistView(bytes, at);

    final key = enc.Key(_deriveKey(passphrase, salt));
    final opener = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    try {
      return opener.decrypt(enc.Encrypted(cipher), iv: enc.IV(iv));
    } catch (_) {
      // GCM authentication failed. Overwhelmingly the passphrase; possibly a
      // damaged file. We cannot tell the two apart, and saying "wrong password"
      // is the more useful guess.
      throw const BackupError(BackupFault.wrongPassphrase);
    }
  }

  /// PBKDF2-HMAC-SHA256. Hand-rolled over `crypto` rather than pulling a second
  /// KDF package in: the loop is six lines and this is the only caller.
  static Uint8List _deriveKey(String passphrase, Uint8List salt) {
    final hmac = Hmac(sha256, utf8.encode(passphrase));
    // 32-byte key => exactly one PBKDF2 block (SHA-256 output is 32 bytes).
    var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.from(block);
    for (var i = 1; i < kdfRounds; i++) {
      block = hmac.convert(block).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= block[j];
      }
    }
    return Uint8List.fromList(out);
  }

  /// `DOP-khata-2026-08-14.dopbackup` — dated so a folder of them sorts, and
  /// so the agent can tell at a glance how old his newest one is.
  static String fileNameFor(DateTime when) {
    final y = when.year.toString().padLeft(4, '0');
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    return 'DOP-khata-$y-$m-$d.dopbackup';
  }
}

enum BackupFault {
  /// Header didn't match — the agent picked some other file.
  notABackup,

  /// Header matched but decryption failed.
  wrongPassphrase,

  /// Written by a newer app than this one.
  tooNew,

  /// Truncated, or the JSON inside is not what we wrote.
  corrupt,
}

class BackupError implements Exception {
  const BackupError(this.fault);
  final BackupFault fault;

  /// Plain-language, for a man holding a phone — not a stack trace.
  String get message => switch (fault) {
        BackupFault.notABackup =>
          'That file is not a DOP Collect backup. Pick the file ending in '
              '.dopbackup.',
        BackupFault.wrongPassphrase =>
          'Wrong password. This is the password you set when you made the '
              'backup — not your DOP login.',
        BackupFault.tooNew =>
          'This backup was made by a newer version of the app. Update DOP '
              'Collect, then restore again.',
        BackupFault.corrupt =>
          'This backup file is damaged and cannot be read. Try an older one.',
      };

  @override
  String toString() => 'BackupError(${fault.name}): $message';
}

class BackupPayload {
  const BackupPayload({
    required this.version,
    required this.takenAt,
    required this.appVersion,
    required this.tables,
    required this.prefs,
  });

  final int version;
  final DateTime? takenAt;
  final String appVersion;
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object?> prefs;

  int get accounts => tables['accounts']?.length ?? 0;
  int get collections => tables['collections']?.length ?? 0;
  int get lots => tables['lots']?.length ?? 0;
}
