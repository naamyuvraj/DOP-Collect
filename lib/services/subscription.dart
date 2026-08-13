import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/credentials.dart';
import '../data/session.dart';
import 'analytics.dart';
import 'remote_config.dart';
import 'supabase_config.dart';

/// A plan the app can offer.
class Plan {
  final String code, name;
  final num priceInr;
  final int durationDays;
  Plan(this.code, this.name, this.priceInr, this.durationDays);
  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        j['code'] as String,
        (j['name'] ?? j['code']) as String,
        (j['price_inr'] as num?) ?? 0,
        (j['duration_days'] as num?)?.toInt() ?? 0,
      );
  bool get isFree => priceInr <= 0;
}

/// Current entitlement for this agent.
class SubStatus {
  final String status; // trial | active | expired | unknown
  final String planCode;
  final List<Plan> plans;

  /// When access runs out. Kept so [daysLeft] can be recomputed as the clock
  /// moves: the server's count is only true at the instant it answered, and
  /// this status is cached to disk and read back on a later cold start. Without
  /// it an agent offline for a week still read "12 days left". Null only for
  /// an older cache written before this field existed.
  final DateTime? periodEnd;

  /// What the server said when it last answered — the fallback for a cache with
  /// no [periodEnd].
  final int _reportedDaysLeft;

  SubStatus(this.status, this.planCode, int daysLeft, this.plans,
      {this.periodEnd})
      : _reportedDaysLeft = daysLeft;

  /// Whole days of access remaining, counting a part-day as a day.
  int get daysLeft {
    final end = periodEnd;
    if (end == null) return _reportedDaysLeft;
    final ms = end.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / Duration.millisecondsPerDay).ceil();
  }

  /// Server-driven on purpose. A local clock that has run past [periodEnd] is
  /// NOT treated as expired — the device may simply be offline or its clock
  /// wrong, and locking a paying agent out on that basis is the one failure
  /// this whole flow is built to avoid.
  bool get expired => status == 'expired';
}

/// Order details returned by the server, handed to the native checkout.
class RazorpayOrder {
  final String orderId, keyId, planCode, planName;
  final int amount; // paise
  RazorpayOrder(this.orderId, this.keyId, this.planCode, this.planName, this.amount);
}

/// What the native checkout returns on success.
class RazorpayResult {
  final String orderId, paymentId, signature;
  RazorpayResult(this.orderId, this.paymentId, this.signature);
}

/// Opens the Razorpay checkout sheet. This is a SEAM: it stays null in
/// patch builds (razorpay_flutter is native) and is set in the release build
/// to the real plugin call. Returns null if the user cancels.
typedef RazorpayOpener = Future<RazorpayResult?> Function(RazorpayOrder order);

/// Subscription / paywall client. Talks to the `pay` edge function; the app
/// never holds the Razorpay secret. Entitlement is keyed by the DOP agent_id.
class Subscription {
  Subscription._();

  static SubStatus? _current;
  static const _cacheKey = 'sub_status_v1';

  /// Set by the release build to the real razorpay_flutter implementation.
  static RazorpayOpener? opener;

  /// Last failure reason (order / checkout / verify), for surfacing to the user.
  static String? lastError;

  /// Fired whenever [current] changes. The app root listens so the hard gate
  /// can appear (or clear) the moment the background refresh lands, rather than
  /// waiting for the next cold start.
  static void Function()? onChanged;

  static SubStatus? get current => _current;

  /// True only when payments are switched on AND we KNOW the plan expired.
  /// Fail-open: no status yet / offline / error never blocks a paying agent.
  static bool get blocked =>
      RemoteConfig.paymentsEnabled && (_current?.expired ?? false);

  static Future<String> _agentId() async => (await Credentials.load()).agentId;

  /// Test seam — see [OtpService.client].
  @visibleForTesting
  static http.Client client = http.Client();

  /// Every `pay` call carries this device's verified session token when there
  /// is one; the server derives the agent id from it and ignores anything the
  /// client claims.
  ///
  /// Without a session the call still goes out: `status` answers with the
  /// public plan list (and no entitlement), which is what the paywall needs to
  /// render before anyone has signed in. `order` and `verify` 401, correctly.
  static Future<Map<String, dynamic>?> _call(Map<String, Object?> body) async {
    if (!SupabaseConfig.configured) return null;
    final session = await SessionStore.load();
    try {
      final res = await client
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/pay'),
            headers: {
              'apikey': SupabaseConfig.anonKey,
              'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
              'Content-Type': 'application/json',
              'x-device-id': await Analytics.deviceId(),
            },
            body: jsonEncode({
              ...body,
              if (session != null) 'token': session.token,
            }),
          )
          .timeout(const Duration(seconds: 12));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Load the cached status instantly (for the gate at startup).
  ///
  /// Authoritative: no cache (or an unreadable one) means "we don't know", NOT
  /// "keep whatever was in memory". Entitlement is per-agent and this is a
  /// static, so leaving a stale value here would carry one agent's plan into
  /// the next agent to sign in on the same phone.
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cacheKey);
    _current = null;
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        _current = SubStatus(
          j['status'] as String,
          j['planCode'] as String,
          (j['daysLeft'] as num).toInt(),
          const [],
          periodEnd: DateTime.tryParse((j['periodEnd'] as String?) ?? ''),
        );
      } catch (_) {/* unreadable cache — stay at "unknown" */}
    }
    unawaited(refresh());
  }

  /// Drop this agent's entitlement, in memory and on disk. Called on logout so
  /// the next agent on this phone starts from "unknown" and re-fetches their
  /// own, rather than inheriting the last one's.
  static Future<void> forget() async {
    _current = null;
    onChanged?.call();
    try {
      await (await SharedPreferences.getInstance()).remove(_cacheKey);
    } catch (_) {/* best effort — memory is already cleared */}
  }

  /// Pull fresh entitlement + plans from the server.
  static Future<SubStatus?> refresh() async {
    final j = await _call({'action': 'status'});
    if (j == null || j['ok'] != true) return _current;
    final plans = ((j['plans'] as List?) ?? const [])
        .map((e) => Plan.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final status = (j['status'] as String?) ?? 'unknown';

    // `unknown` means "nobody is signed in on this device", so the server told
    // us the prices and nothing about any agent. Take the plans — the paywall
    // needs them to render — but leave the entitlement exactly as it was
    // instead of overwriting a known plan with a non-answer, and don't cache a
    // non-answer over a real one.
    if (status == 'unknown') {
      _current = SubStatus(
        _current?.status ?? 'unknown',
        _current?.planCode ?? '',
        _current?.daysLeft ?? 0,
        plans,
        periodEnd: _current?.periodEnd,
      );
      onChanged?.call();
      return _current;
    }

    final periodEnd = DateTime.tryParse((j['periodEnd'] as String?) ?? '');
    _current = SubStatus(status, (j['planCode'] as String?) ?? '',
        (j['daysLeft'] as num?)?.toInt() ?? 0, plans,
        periodEnd: periodEnd);
    onChanged?.call();
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _cacheKey,
        jsonEncode({
          'status': _current!.status,
          'planCode': _current!.planCode,
          'daysLeft': _current!.daysLeft,
          // Stored so a later cold start can age the count instead of
          // replaying whatever number the server happened to send.
          if (periodEnd != null) 'periodEnd': periodEnd.toIso8601String(),
        }));
    return _current;
  }

  /// Full purchase flow: create order -> open Razorpay -> verify -> refresh.
  /// Returns true on a verified payment. Throws [CheckoutUnavailable] if the
  /// native checkout isn't wired yet (patch build).
  static Future<bool> purchase(String planCode) async {
    lastError = null;
    if ((await _agentId()).isEmpty) {
      lastError = 'No agent id — sign in first.';
      return false;
    }
    final o = await _call({'action': 'order', 'planCode': planCode});
    if (o == null || o['ok'] != true) {
      lastError = 'Order failed: ${o?['error'] ?? o?['detail'] ?? 'no response from server'}';
      return false;
    }
    final order = RazorpayOrder(o['orderId'] as String, o['keyId'] as String,
        planCode, (o['planName'] ?? '') as String, (o['amount'] as num).toInt());
    final open = opener;
    if (open == null) throw const CheckoutUnavailable();
    final res = await open(order); // sets lastError on a sheet error
    if (res == null) return false; // cancelled or sheet error
    final v = await _call({
      'action': 'verify', 'planCode': planCode,
      'orderId': res.orderId, 'paymentId': res.paymentId, 'signature': res.signature,
    });
    final ok = v != null && v['ok'] == true;
    if (!ok) lastError = 'Verify failed: ${v?['error'] ?? 'no response'}';
    if (ok) await refresh();
    return ok;
  }
}

class CheckoutUnavailable implements Exception {
  const CheckoutUnavailable();
}
