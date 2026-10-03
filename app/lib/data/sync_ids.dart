import 'dart:math';

/// Stable row identity for anything that syncs between the agent's devices.
///
/// WHY A UUID AND NOT THE ROW ID
/// -----------------------------
/// `collections.id` and `lots.id` are INTEGER AUTOINCREMENT, and both devices
/// start counting from 1. The phone takes cash from a customer on Tuesday and
/// writes row 41; the desktop saves a list the same afternoon and also writes
/// row 41. Any merge keyed on that id has to discard one of them, and for the
/// collections ledger the thing discarded is a rupee amount an agent actually
/// took at a door.
///
/// A uuid v4 collides with nothing, so a merge is a union: two devices working
/// the same day produce two rows, not one row and a silent loss.
///
/// The value is generated ONCE, on the device that first created the row, and
/// never changes afterwards — not on edit, not on restore from a backup, not
/// when the row is soft-deleted. That is what lets a tombstone find its
/// original on the other device.
String newUid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
      '-${h.substring(16, 20)}-${h.substring(20)}';
}

/// The stamp that decides who wins when two devices touched the same row.
///
/// UTC on purpose. The comparison happens on the server against another
/// device's stamp, and a phone in IST versus a browser reporting local time
/// would otherwise resolve conflicts by timezone rather than by which edit
/// came second.
String syncStamp([DateTime? at]) =>
    (at ?? DateTime.now()).toUtc().toIso8601String();
