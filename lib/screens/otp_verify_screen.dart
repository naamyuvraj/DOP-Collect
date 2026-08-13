import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/otp_service.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';

/// Phone OTP verification (code delivered over WhatsApp). Sends a code on open, lets the agent enter it in
/// segmented boxes, verifies (binding phone <-> agentId), and pops `true` on
/// success. Reusable for first-time onboarding and re-verification.
class OtpVerifyScreen extends StatefulWidget {
  const OtpVerifyScreen({
    super.key,
    required this.phone,
    required this.agentId,
    this.codeLength = 4,
    this.changePhone = false,
  });

  /// 10-digit mobile number (India). Country code is added server-side.
  final String phone;
  final String agentId;
  final int codeLength;

  /// True when verifying a NEW number for the "update mobile" flow — lets the
  /// server rebind this agent to the new number.
  final bool changePhone;

  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  bool _sending = true; // sending the initial code
  bool _verifying = false;
  String? _error;
  int _resendIn = 0; // seconds left before resend is allowed
  Timer? _timer;

  String get _masked {
    final p = widget.phone.replaceAll(RegExp(r'\D'), '');
    if (p.length < 4) return p;
    return '+91 ●●●●● ${p.substring(p.length - 4)}';
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    _sendInitial();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _sendInitial() async {
    setState(() => _sending = true);
    final r = await OtpService.send(widget.phone);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = r.ok ? null : r.message;
    });
    if (r.ok) {
      _startCooldown(r.cooldown);
      FocusScope.of(context).requestFocus(_focus);
    }
  }

  Future<void> _resend() async {
    if (_resendIn > 0) return;
    setState(() => _error = null);
    final r = await OtpService.send(widget.phone, resend: true);
    if (!mounted) return;
    if (r.ok) {
      _ctrl.clear();
      _startCooldown(r.cooldown);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A new code is on its way.')));
      FocusScope.of(context).requestFocus(_focus);
    } else {
      setState(() => _error = r.message);
      if (r.code == 'cooldown') _startCooldown(r.cooldown);
    }
  }

  void _startCooldown(int secs) {
    _timer?.cancel();
    setState(() => _resendIn = secs);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _resendIn = _resendIn > 0 ? _resendIn - 1 : 0);
      if (_resendIn == 0) t.cancel();
    });
  }

  void _onChanged() {
    if (_error != null) setState(() => _error = null);
    setState(() {}); // repaint boxes
    if (_ctrl.text.length == widget.codeLength && !_verifying) _verify();
  }

  Future<void> _verify() async {
    final code = _ctrl.text.trim();
    if (code.length != widget.codeLength) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _verifying = true;
      _error = null;
    });
    final r = await OtpService.verify(widget.phone, code,
        agentId: widget.agentId, changePhone: widget.changePhone);
    if (!mounted) return;
    if (r.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _verifying = false;
      _error = r.message;
      _ctrl.clear();
    });
    FocusScope.of(context).requestFocus(_focus);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(color: AppTheme.ink),
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              const SizedBox(height: 12),
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppTheme.accentSoft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.sms_outlined,
                    color: AppTheme.black, size: 30),
              ),
              const SizedBox(height: 20),
              Text('Verify your phone',
                  style: AppTheme.display(28, weight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  style:
                      AppTheme.body(14.5, color: AppTheme.inkMuted, height: 1.45),
                  children: [
                    const TextSpan(text: 'We sent a code to '),
                    TextSpan(
                        text: _masked,
                        style: AppTheme.body(14.5,
                            weight: FontWeight.w700, color: AppTheme.ink)),
                    const TextSpan(text: '. Enter it below.'),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              _codeField(),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: AppTheme.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: AppTheme.body(13, color: AppTheme.red)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 28),
              PushButton(
                onPressed: (_verifying ||
                        _sending ||
                        _ctrl.text.length != widget.codeLength)
                    ? null
                    : _verify,
                color: AppTheme.black,
                child: Text(_verifying ? 'Verifying…' : 'Verify'),
              ),
              const SizedBox(height: 18),
              Center(child: _resendRow()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resendRow() {
    if (_sending) {
      return Text('Sending code…',
          style: AppTheme.body(13, color: AppTheme.inkMuted));
    }
    if (_resendIn > 0) {
      return Text('Resend code in ${_resendIn}s',
          style: AppTheme.body(13, color: AppTheme.inkMuted));
    }
    return GestureDetector(
      onTap: _resend,
      child: Text("Didn't get it?  Resend code",
          style: AppTheme.body(13.5,
              weight: FontWeight.w700, color: AppTheme.black)),
    );
  }

  /// Segmented code entry: a Row of boxes reading from one hidden TextField, so
  /// paste + keyboard autofill still work.
  Widget _codeField() {
    return Stack(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.codeLength, (i) {
            final filled = i < _ctrl.text.length;
            final active = i == _ctrl.text.length && _focus.hasFocus;
            return Container(
              width: 58,
              height: 66,
              margin: EdgeInsets.only(right: i == widget.codeLength - 1 ? 0 : 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _error != null
                      ? AppTheme.red
                      : active
                          ? AppTheme.black
                          : AppTheme.line,
                  width: active || _error != null ? 2 : 1.4,
                ),
              ),
              child: Text(
                filled ? _ctrl.text[i] : '',
                style: AppTheme.display(26, weight: FontWeight.w800),
              ),
            );
          }),
        ),
        // Transparent capture field over the boxes.
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: widget.codeLength,
              showCursor: false,
              enableInteractiveSelection: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(counterText: '', border: InputBorder.none),
            ),
          ),
        ),
      ],
    );
  }
}
