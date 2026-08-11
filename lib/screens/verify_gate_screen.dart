import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';
import 'otp_verify_screen.dart';

/// Blocks an already-onboarded user until they verify their phone, shown when
/// OTP is switched on but this device has no verified session yet (e.g. they
/// onboarded before OTP existed, or were signed out by the 2-device limit).
/// New users hit the same verify step inside onboarding; this covers everyone
/// else so the agent↔phone pair is enforced for all users, not just new ones.
class VerifyGateScreen extends StatefulWidget {
  const VerifyGateScreen({
    super.key,
    required this.onVerified,
    this.onLogout,
    this.reason,
  });
  final VoidCallback onVerified;
  final VoidCallback? onLogout;
  final String? reason; // e.g. "signed out on another device"

  @override
  State<VerifyGateScreen> createState() => _VerifyGateScreenState();
}

class _VerifyGateScreenState extends State<VerifyGateScreen> {
  final _phone = TextEditingController();
  String _agentId = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Credentials.load().then((c) => _agentId = c.agentId);
    AppSettings.mobile().then((m) {
      if (m.isNotEmpty && mounted) _phone.text = m;
    });
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _verify() async {
    if (_digits.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter your 10-digit mobile number.')));
      return;
    }
    setState(() => _busy = true);
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => OtpVerifyScreen(phone: _digits, agentId: _agentId),
    ));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      await AppSettings.setMobile(_digits);
      widget.onVerified();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.verified_user_outlined,
                      color: Color(0xFF25D366), size: 28),
                ),
                const SizedBox(height: 20),
                Text('Verify your phone',
                    style: AppTheme.display(28, weight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  widget.reason ??
                      'To keep your account secure, confirm your WhatsApp number '
                          'once. It links to your Agent ID and works on up to 2 '
                          'phones.',
                  style:
                      AppTheme.body(14, color: AppTheme.inkMuted, height: 1.45),
                ),
                const SizedBox(height: 28),
                _phoneField(),
                const Spacer(),
                PushButton(
                  onPressed: _busy ? null : _verify,
                  color: AppTheme.black,
                  child: Text(_busy ? 'Please wait…' : 'Send code & verify'),
                ),
                const SizedBox(height: 10),
                if (widget.onLogout != null)
                  Center(
                    child: TextButton(
                      onPressed: widget.onLogout,
                      child: Text('Log out',
                          style: AppTheme.body(13, color: AppTheme.inkMuted)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _phoneField() {
    return Container(
      decoration: AppTheme.card(radius: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.smartphone_outlined,
              color: AppTheme.inkFaint, size: 20),
          const SizedBox(width: 12),
          Text('+91',
              style: AppTheme.body(15,
                  weight: FontWeight.w700, color: AppTheme.inkMuted)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: AppTheme.body(15, weight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'WhatsApp mobile number',
                labelStyle: AppTheme.body(13, color: AppTheme.inkMuted),
                counterText: '',
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
