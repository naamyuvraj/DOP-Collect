import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'package:shared_preferences/shared_preferences.dart';

import '../data/credentials.dart';
import '../data/session.dart';
import 'analytics.dart';
import 'supabase_config.dart';

/// Result of an OTP action, carrying a machine `code` (for logic) and a
/// human-readable `message` (for the UI).
class OtpResult {
  final bool ok;
  final String? code; // machine code from the server, or a local one
  final String message; // user-facing
  final int cooldown; // seconds before a resend is allowed
  const OtpResult(this.ok, {this.code, this.message = '', this.cooldown = 30});
}

/// Client for the `otp` edge function (WhatsApp OTP + device sessions).
/// The app holds no MSG91 secret; everything goes through the function with the
/// public anon key. Entitlement/session enforcement is server-side.
class OtpService {
  OtpService._();

  /// Set by the startup heartbeat when this device's session was revoked
  /// remotely (kicked by the 2-device limit, or disabled). The onboarding screen
  /// reads it once to explain why the agent was signed out.
  static bool signedOutRemotely = false;

  /// The agent id whose bind has been settled on this device — see [bindAgent].
  static const _kBound = 'otp_agent_bound';

  /// Test seam: every request goes through this client, so a test can assert
  /// exactly what reaches the wire — notably that a `changePhone` verify really
  /// does carry the session token the server now demands.
  @visibleForTesting
  static http.Client client = http.Client();

  static Future<Map<String, dynamic>?> _call(Map<String, Object?> body) async {
    if (!SupabaseConfig.configured) return null;
    try {
      final res = await client
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/otp'),
            headers: {
              'apikey': SupabaseConfig.anonKey,
              'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Send (or resend) a code to [phone] over WhatsApp.
  static Future<OtpResult> send(String phone, {bool resend = false}) async {
    final device = await Analytics.deviceId();
    final j = await _call({
      'action': resend ? 'resend' : 'send',
      'phone': phone,
      'deviceId': device,
    });
    if (j == null) {
      return const OtpResult(false,
          code: 'network',
          message: 'No connection. Check your internet and try again.');
    }
    if (j['ok'] == true) {
      return OtpResult(true, cooldown: (j['cooldown'] as num?)?.toInt() ?? 30);
    }
    return OtpResult(false, code: j['code'] as String?, message: _sendMsg(j));
  }

  /// Verify [otp] for [phone], binding to [agentId]. On success the session
  /// token is stored in the Keystore and returned.
  ///
  /// A [changePhone] verify additionally carries THIS device's existing session
  /// token: the OTP proves the agent controls the new number, and the token
  /// proves they already own the account being moved. The server refuses the
  /// rebind without both, so knowing an agent id can't take an account over.
  static Future<OtpResult> verify(
    String phone,
    String otp, {
    required String agentId,
    bool changePhone = false,
  }) async {
    final device = await Analytics.deviceId();
    final existing = changePhone ? await SessionStore.load() : null;
    final j = await _call({
      'action': 'verify',
      'phone': phone,
      'otp': otp,
      'agentId': agentId,
      'deviceId': device,
      'appVersion': SupabaseConfig.buildVersion,
      if (changePhone) 'changePhone': true,
      if (existing != null) 'token': existing.token,
    });
    if (j == null) {
      return const OtpResult(false,
          code: 'network',
          message: 'No connection. Check your internet and try again.');
    }
    if (j['ok'] == true) {
      await SessionStore.save(Session(
        j['token'] as String? ?? '',
        j['accountId'] as String? ?? '',
        phone.replaceAll(RegExp(r'\D'), ''),
        agentId,
      ));
      return const OtpResult(true, message: 'Verified.');
    }
    return OtpResult(false, code: j['code'] as String?, message: _verifyMsg(j));
  }

  /// Attach this device's DOP agent id to its verified account.
  ///
  /// The "Log in" tab verifies the phone BEFORE the agent id exists on a fresh
  /// handset — `_login()` reads it from [Credentials], which is empty, and only
  /// collects it afterwards through `ensureDopLogin`. The account was therefore
  /// created with `agent_id` null, and nothing filled it in later, so the 1:1
  /// phone<->agent binding the device limit rests on was never established.
  ///
  /// This is the repair, and it runs at startup rather than only in onboarding
  /// because every affected install is already onboarded and would never pass
  /// through that screen again.
  ///
  /// Best-effort and silent by design: it must never block, delay or fail a
  /// launch. A refusal is a real conflict (this agent id is already bound to a
  /// different number) and is reported to the dashboard's Errors tab, because
  /// that is a situation only a human can untangle — the app must not resolve it
  /// by rewriting someone's binding.
  ///
  /// Marked done in prefs once settled so a launch costs at most one request,
  /// and only for a settled answer — a network failure retries next launch.
  static Future<void> bindAgent() async {
    try {
      final session = await SessionStore.load();
      if (session == null) return; // not verified — nothing to bind to
      final agentId = (await Credentials.load()).agentId.trim();
      if (agentId.isEmpty) return; // DOP login not entered yet

      final p = await SharedPreferences.getInstance();
      if (p.getString(_kBound) == agentId) return;

      final j = await _call({
        'action': 'bind_agent',
        'token': session.token,
        'agentId': agentId,
      });
      if (j == null) return; // offline — try again next launch

      if (j['ok'] == true) {
        await p.setString(_kBound, agentId);
        return;
      }
      final code = j['code'] as String?;
      if (code == 'agent_mismatch' || code == 'already_linked') {
        // Settled, just not in our favour. Stop asking, and make it visible.
        await p.setString(_kBound, agentId);
        unawaited(Analytics.error(
          'identity',
          'Agent id could not be bound to this account: $code',
          detail: 'agentId=$agentId phone=${session.phone}',
          screen: 'bind_agent',
        ));
      }
      // no_session / bind_failed: transient or fixed by re-verifying. Retry.
    } catch (_) {
      // Identity repair must never affect a launch.
    }
  }

  /// Heartbeat: is this device's session still live? Returns true when we can't
  /// reach the server (fail-open — never lock a user out on a network blip).
  static Future<bool> sessionValid() async {
    final s = await SessionStore.load();
    if (s == null) return false;
    final j = await _call({'action': 'session_check', 'token': s.token});
    if (j == null) return true; // offline → don't sign out
    return j['ok'] == true;
  }

  /// Revoke this device's session on the server, then clear it locally.
  static Future<void> logout() async {
    final s = await SessionStore.load();
    if (s != null) {
      await _call({'action': 'logout', 'token': s.token});
    }
    await SessionStore.clear();
    // Forget the bind verdict too. The next verify may land on a different
    // account, where the same agent id is an open question again — leaving the
    // marker behind would skip the repair on the very install that needs it.
    try {
      await (await SharedPreferences.getInstance()).remove(_kBound);
    } catch (_) {/* the marker is an optimisation, not state we depend on */}
  }

  // --- error code -> friendly copy ------------------------------------------
  static String _sendMsg(Map<String, dynamic> j) {
    switch (j['code']) {
      case 'bad_phone':
        return 'That doesn\'t look like a valid 10-digit mobile number.';
      case 'cooldown':
        final c = (j['cooldown'] as num?)?.toInt() ?? 30;
        return 'Please wait ${c}s before requesting another code.';
      case 'rate_limited':
        return 'Too many codes requested. Try again in a little while.';
      case 'not_configured':
        return 'OTP isn\'t set up yet. Please contact support.';
      case 'provider_down':
        return 'Couldn\'t send the WhatsApp code right now. Try again shortly.';
      default:
        return 'Couldn\'t send the code. Please try again.';
    }
  }

  static String _verifyMsg(Map<String, dynamic> j) {
    switch (j['code']) {
      case 'invalid_otp':
        return 'Wrong code. Check it and try again.';
      case 'expired':
        return 'That code expired. Tap Resend for a new one.';
      case 'too_many_attempts':
        return 'Too many wrong tries. Tap Resend for a new code.';
      case 'already_linked':
        return j['detail'] == 'agent'
            ? 'This Agent ID is already linked to a different phone number.'
            : 'This phone is already linked to a different Agent ID.';
      case 'account_disabled':
        return 'This account has been disabled. Please contact support.';
      case 'reauth_required':
        return 'For your security, change your number from a phone that is '
            'already signed in to this account.';
      case 'bad_phone':
        return 'That doesn\'t look like a valid mobile number.';
      default:
        return 'Couldn\'t verify the code. Please try again.';
    }
  }
}
