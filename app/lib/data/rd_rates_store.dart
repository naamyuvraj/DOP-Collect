import 'dart:convert';

import '../calc/po_calc.dart';
import 'app_settings.dart';

/// Bridges the persisted RD rate history to [PoCalc]'s live table.
///
/// [load] runs once at startup so every synchronous `rdRateOn` call downstream
/// (account maturity, calculator) sees the user's edits without going async.
class RdRatesStore {
  /// Apply any stored edits to [PoCalc] before the UI reads rates.
  static Future<void> load() async {
    final raw = await AppSettings.rdRatesJson();
    if (raw.isEmpty) return;
    try {
      final rows = (jsonDecode(raw) as List)
          .map((e) => ((e[0] as num).toInt(), (e[1] as num).toDouble()))
          .toList();
      PoCalc.setRdRates(rows);
    } catch (_) {
      // Corrupt data -> keep the built-in table.
    }
  }

  /// Persist [rows] and apply them live.
  static Future<void> save(List<(int, double)> rows) async {
    PoCalc.setRdRates(rows);
    await AppSettings.setRdRatesJson(
        jsonEncode(PoCalc.rdRates.map((e) => [e.$1, e.$2]).toList()));
  }

  /// Restore the built-in table.
  static Future<void> reset() async {
    PoCalc.resetRdRates();
    await AppSettings.setRdRatesJson('');
  }
}
