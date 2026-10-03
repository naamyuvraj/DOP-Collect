import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';


/// How the day stands on the collect sheet.
///
/// [closedUncounted] exists so the sheet can never show a "Counted ✓" for a day
/// he closed without counting a single note.
enum DayCloseState { open, closedUncounted, reconciled }

/// Small key-value settings kept on the device (agent's ASLAAS number, etc.).
class AppSettings {
  static const _kAslaas = 'aslaas_number';
  static const _kAgentName = 'agent_name';

  static Future<String> aslaas() async =>
      (await SharedPreferences.getInstance()).getString(_kAslaas) ?? '';

  static Future<void> setAslaas(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kAslaas, v.trim());

  static Future<String> agentName() async =>
      (await SharedPreferences.getInstance()).getString(_kAgentName) ?? '';

  static Future<void> setAgentName(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kAgentName, v.trim());

  // The app used to carry TWO names — a "Name" for display and a separate
  // "Agent Name" for the DOP paperwork. Agents filled one, the other, or both
  // with the same thing, and the dashboard then had to guess which to show.
  // There is now ONE name: [agentName].
  static const _kDisplayName = 'display_name'; // legacy — read once, then dropped

  /// One-time fold of the retired `display_name` into `agent_name`.
  ///
  /// Runs at startup. Only fills a BLANK agent name, so an agent who set both
  /// keeps the one that appears on his receipts; the legacy key is then removed
  /// so this never runs twice. Safe on a fresh install (both are empty).
  static Future<void> migrateLegacyName() async {
    final p = await SharedPreferences.getInstance();
    final legacy = p.getString(_kDisplayName);
    if (legacy == null) return;
    if ((p.getString(_kAgentName) ?? '').trim().isEmpty && legacy.trim().isNotEmpty) {
      await p.setString(_kAgentName, legacy.trim());
    }
    await p.remove(_kDisplayName);
  }

  // The agent's mobile number (digits only), captured at onboarding. Sent with
  // telemetry so the admin dashboard can list/contact agents.
  static const _kMobile = 'mobile_number';
  static Future<String> mobile() async =>
      (await SharedPreferences.getInstance()).getString(_kMobile) ?? '';
  static Future<void> setMobile(String v) async =>
      (await SharedPreferences.getInstance())
          .setString(_kMobile, v.replaceAll(RegExp(r'\D'), ''));

  // The book-wide daily rule used to live here — a day count and a
  // flat-amount mode, both settable from Settings. It is now fixed at
  // DailyRule.defaultDays, and the only override left is per-customer, set
  // from the collect sheet in front of the customer it applies to.
  //
  // The old keys (daily_rule_flat / _days / _amount) are left unread rather
  // than migrated. Nothing writes them now, and clearing a saved value is not
  // worth a migration for a setting that no longer exists.

  // Day close: the last day he counted his cash against the ledger, and the
  // figure he counted. Kept in prefs rather than the DB — it's a one-line
  // "have I done this today?" marker, and the collections themselves are
  // already the record of what happened.
  static const _kDayClosed = 'day_closed_on';
  static const _kDayCounted = 'day_closed_counted';
  static const _kDayTotal = 'day_closed_total';

  /// What the ledger held when the day was closed. The sheet compares this
  /// against today's running total, so collecting again after a count re-arms
  /// the button — a tick that says "counted" while the bag has since grown is
  /// worse than no tick at all.
  static Future<int> dayClosedTotal() async =>
      (await SharedPreferences.getInstance()).getInt(_kDayTotal) ?? -1;

  /// `yyyy-MM-dd` of the last closed day, or '' if he has never closed one.
  static Future<String> dayClosedOn() async =>
      (await SharedPreferences.getInstance()).getString(_kDayClosed) ?? '';

  /// The figure he actually counted, or **-1 when the day was closed without
  /// counting**. The sentinel matters: closing without a count is allowed (he
  /// may just want the day marked), but it must never be reported back as a
  /// reconciliation he never performed.
  static Future<int> dayClosedCounted() async =>
      (await SharedPreferences.getInstance()).getInt(_kDayCounted) ?? -1;

  static Future<void> setDayClosed(DateTime day,
      {required int? counted, required int recorded}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDayClosed, _dayKey(day));
    await p.setInt(_kDayCounted, counted ?? -1);
    await p.setInt(_kDayTotal, recorded);
  }

  static String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// True when [day] has been closed — whether or not the cash was counted.
  static Future<bool> isDayClosed(DateTime day) async {
    final on = await dayClosedOn();
    return on.isNotEmpty && on == _dayKey(day);
  }

  /// Where [day] stands against a ledger currently totalling [recorded].
  ///
  /// Three states, not two, because "closed" and "counted" are different
  /// claims. A day closed without a count is closed; only a day closed WITH a
  /// figure that still matches the ledger is reconciled — and collecting again
  /// afterwards drops it back to open, since the bag has grown since the count.
  static Future<DayCloseState> dayCloseState(DateTime day, int recorded) async {
    if (!await isDayClosed(day)) return DayCloseState.open;
    if (await dayClosedTotal() != recorded) return DayCloseState.open;
    return await dayClosedCounted() < 0
        ? DayCloseState.closedUncounted
        : DayCloseState.reconciled;
  }

  /// Which amount one swipe on the collect sheet takes. He flips this once for
  /// the round he is walking, so it belongs on the device, not in screen state
  /// that resets every launch.
  static const _kCollectDaily = 'collect_daily_mode';
  static Future<bool> collectDailyMode() async =>
      (await SharedPreferences.getInstance()).getBool(_kCollectDaily) ?? true;
  static Future<void> setCollectDailyMode(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kCollectDaily, v);

  static const _kOnboarded = 'onboarded';
  static Future<bool> onboarded() async =>
      (await SharedPreferences.getInstance()).getBool(_kOnboarded) ?? false;
  static Future<void> setOnboarded(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kOnboarded, v);

  /// Agent's profile photo as a base64 JPEG (set via image picker). Empty = none.
  static const _kPhoto = 'profile_photo';
  static Future<String> profilePhoto() async =>
      (await SharedPreferences.getInstance()).getString(_kPhoto) ?? '';
  static Future<void> setProfilePhoto(String b64) async =>
      (await SharedPreferences.getInstance()).setString(_kPhoto, b64);

  /// Whether the guided product tour has been shown. Replayable from Settings.
  static const _kTourSeen = 'tour_seen';
  static Future<bool> tourSeen() async =>
      (await SharedPreferences.getInstance()).getBool(_kTourSeen) ?? false;
  static Future<void> setTourSeen(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kTourSeen, v);

  // "Offline-only AI" used to be a manual switch. It is gone: the assistant now
  // decides per question — every common question is still answered by the
  // on-device intent engine first, and the cloud is only consulted when that
  // engine has no match AND the network is actually reachable. An agent with no
  // signal gets the offline answer without having flipped anything.
  // See AssistantConfig.cloudActive / AssistantService.ask.

  /// "New Accounts" window in months (1/2/3), default 1.
  static const _kNewMonths = 'new_account_months';
  static Future<int> newAccountMonths() async =>
      (await SharedPreferences.getInstance()).getInt(_kNewMonths) ?? 1;
  static Future<void> setNewAccountMonths(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kNewMonths, v);

  // Anonymous usage analytics no longer has a Settings toggle — it is always on
  // and is disclosed up front in the Privacy Policy the agent must accept before
  // signing up. What it sends is unchanged and still excludes every customer
  // detail (see Analytics.identify). The kill switch that remains is the remote
  // one: RemoteConfig.analyticsDefault, so it can be stopped fleet-wide without
  // an app update.

  /// Lot ids whose report has been downloaded/printed (for the Downloads tab's
  /// "Download / Downloaded" state).
  static const _kDownloaded = 'downloaded_lot_ids';
  static Future<Set<int>> downloadedLotIds() async {
    final raw =
        (await SharedPreferences.getInstance()).getStringList(_kDownloaded) ??
            const [];
    return raw.map(int.tryParse).whereType<int>().toSet();
  }

  static Future<void> setDownloadedLotIds(Set<int> ids) async =>
      (await SharedPreferences.getInstance())
          .setStringList(_kDownloaded, ids.map((e) => '$e').toList());

  /// Timestamp of the last successful portal sync (ms since epoch, 0 = never).
  static const _kLastSync = 'last_sync_ms';
  static Future<int> lastSyncMs() async =>
      (await SharedPreferences.getInstance()).getInt(_kLastSync) ?? 0;
  static Future<void> setLastSyncNow() async =>
      (await SharedPreferences.getInstance())
          .setInt(_kLastSync, DateTime.now().millisecondsSinceEpoch);

  /// User-edited RD rate history as JSON (empty = use the built-in table).
  static const _kRdRates = 'rd_rate_history_v1';
  static Future<String> rdRatesJson() async =>
      (await SharedPreferences.getInstance()).getString(_kRdRates) ?? '';
  static Future<void> setRdRatesJson(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kRdRates, v);

  // Light, dark, or follow the phone. Read at startup BEFORE the first frame,
  // so a dark-mode agent never gets a white flash on a cold launch.
  static const _kThemeMode = 'theme_mode';

  static Future<ThemeMode> themeMode() async {
    switch ((await SharedPreferences.getInstance()).getString(_kThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Future<void> setThemeMode(ThemeMode m) async =>
      (await SharedPreferences.getInstance()).setString(
          _kThemeMode,
          switch (m) {
            ThemeMode.light => 'light',
            ThemeMode.dark => 'dark',
            ThemeMode.system => 'system',
          });
}
