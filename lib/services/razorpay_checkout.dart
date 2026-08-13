import 'dart:async';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'subscription.dart';

/// Native Razorpay checkout — the concrete implementation of the
/// [RazorpayOpener] seam. Razorpay reports the result through event callbacks;
/// this bridges them to a Future so [Subscription.purchase] can await it.
///
/// Only compiled into FULL builds (the plugin is native). Wire it in main():
///   Subscription.opener = RazorpayCheckout.open;
class RazorpayCheckout {
  RazorpayCheckout._();

  static final Razorpay _rzp = Razorpay();
  static Completer<RazorpayResult?>? _pending;

  /// The order the open sheet is for — the server-issued id is the fallback
  /// when the success callback doesn't carry its own copy.
  static RazorpayOrder? _pendingOrder;
  static bool _wired = false;

  static void _ensure() {
    if (_wired) return;
    _rzp.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
      // Prefer the callback's order id (it is what Razorpay actually signed),
      // but fall back to the one we opened the sheet with. An empty order id
      // makes `verify` hash `|pay_xyz`, miss the signature, and tell an agent
      // who has just been charged that the payment didn't go through.
      final orderId = (r.orderId?.isNotEmpty ?? false)
          ? r.orderId!
          : (_pendingOrder?.orderId ?? '');
      _finish(RazorpayResult(orderId, r.paymentId ?? '', r.signature ?? ''));
    });
    _rzp.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
      // A genuine user-cancel stays null; a real error surfaces its code+message
      // so we can see what actually failed.
      Subscription.lastError = r.code == Razorpay.PAYMENT_CANCELLED
          ? null
          : 'Razorpay ${r.code}: ${r.message ?? 'error'}';
      _finish(null);
    });
    _rzp.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {
      _finish(null); // external wallet gives no signature to verify
    });
    _wired = true;
  }

  static void _finish(RazorpayResult? r) {
    final c = _pending;
    _pending = null;
    _pendingOrder = null;
    if (c != null && !c.isCompleted) c.complete(r);
  }

  /// Opens the checkout sheet for [order] and resolves when the sheet closes:
  /// a [RazorpayResult] on success, null on cancel/failure.
  static Future<RazorpayResult?> open(RazorpayOrder order) {
    _ensure();
    _finish(null); // resolve any stale attempt first (this clears _pendingOrder)
    final c = _pending = Completer<RazorpayResult?>();
    _pendingOrder = order;
    _rzp.open(<String, dynamic>{
      'key': order.keyId,
      'order_id': order.orderId,
      'amount': order.amount,
      'currency': 'INR',
      'name': 'DOP Collect',
      'description': order.planName,
      'theme': {'color': '#121412'},
    });
    return c.future;
  }
}
