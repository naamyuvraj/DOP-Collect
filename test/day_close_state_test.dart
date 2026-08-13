import 'package:dop_collect/data/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Closing the day and counting the cash are two different claims.
///
/// The sheet used to store `counted = expected` when he closed without
/// counting, then compare the two, find them equal, and show a green
/// "Counted ✓" — a reconciliation it had never performed. These tests hold the
/// three states apart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final day = DateTime(2026, 8, 13, 19, 30);

  test('a day never closed is open', () async {
    expect(await AppSettings.dayCloseState(day, 0), DayCloseState.open);
  });

  test('closed with a matching count is reconciled', () async {
    await AppSettings.setDayClosed(day, counted: 18400, recorded: 18400);
    expect(await AppSettings.dayCloseState(day, 18400),
        DayCloseState.reconciled);
  });

  test('closed WITHOUT counting is not reconciled', () async {
    await AppSettings.setDayClosed(day, counted: null, recorded: 18400);
    expect(await AppSettings.dayCloseState(day, 18400),
        DayCloseState.closedUncounted);
  });

  test('a count that disagreed with the ledger still closes the day', () async {
    // He counted ₹18,000 against a recorded ₹18,400 and closed anyway — the
    // day is reconciled against what the ledger held at that moment.
    await AppSettings.setDayClosed(day, counted: 18000, recorded: 18400);
    expect(await AppSettings.dayCloseState(day, 18400),
        DayCloseState.reconciled);
  });

  test('collecting again after a count re-arms the button', () async {
    await AppSettings.setDayClosed(day, counted: 18400, recorded: 18400);
    // One more ₹500 handover: the bag has grown, so the earlier count is stale.
    expect(await AppSettings.dayCloseState(day, 18900), DayCloseState.open);
  });

  test('yesterday\'s close says nothing about today', () async {
    await AppSettings.setDayClosed(DateTime(2026, 8, 12),
        counted: 9000, recorded: 9000);
    expect(await AppSettings.dayCloseState(day, 9000), DayCloseState.open);
  });

  test('the collect toggle is remembered', () async {
    expect(await AppSettings.collectDailyMode(), isTrue); // daily by default
    await AppSettings.setCollectDailyMode(false);
    expect(await AppSettings.collectDailyMode(), isFalse);
  });
}
