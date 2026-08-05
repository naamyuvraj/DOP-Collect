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
  static bool _wired = false;

  static void _ensure() {
    if (_wired) return;
    _rzp.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
      _finish(RazorpayResult(
          r.orderId ?? '', r.paymentId ?? '', r.signature ?? ''));
    });
    _rzp.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse _) {
      _finish(null); // cancelled or failed
    });
    _rzp.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {
      _finish(null); // external wallet gives no signature to verify
    });
    _wired = true;
  }

  static void _finish(RazorpayResult? r) {
    final c = _pending;
    _pending = null;
    if (c != null && !c.isCompleted) c.complete(r);
  }

  /// Opens the checkout sheet for [order] and resolves when the sheet closes:
  /// a [RazorpayResult] on success, null on cancel/failure.
  static Future<RazorpayResult?> open(RazorpayOrder order) {
    _ensure();
    _finish(null); // resolve any stale attempt first
    final c = _pending = Completer<RazorpayResult?>();
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
