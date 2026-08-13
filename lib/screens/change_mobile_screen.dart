import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';
import 'otp_verify_screen.dart';

/// Change the agent's mobile number, re-verified over WhatsApp. On success the
/// server moves this agent's 1:1 binding to the new number (see the `otp`
/// function's changePhone path) and the old number is freed.
class ChangeMobileScreen extends StatefulWidget {
  const ChangeMobileScreen({super.key});

  @override
  State<ChangeMobileScreen> createState() => _ChangeMobileScreenState();
}

class _ChangeMobileScreenState extends State<ChangeMobileScreen> {
  final _phone = TextEditingController();
  String _agentId = '';
  String _current = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Credentials.load().then((c) => _agentId = c.agentId);
    AppSettings.mobile().then((m) {
      if (mounted) setState(() => _current = m);
    });
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');
  String get _maskedCurrent {
    final p = _current.replaceAll(RegExp(r'\D'), '');
    if (p.length < 4) return p.isEmpty ? '—' : p;
    return '+91 ●●●●● ${p.substring(p.length - 4)}';
  }

  Future<void> _verify() async {
    if (_digits.length != 10) {
      _snack('Enter a valid 10-digit mobile number.');
      return;
    }
    if (_digits == _current.replaceAll(RegExp(r'\D'), '')) {
      _snack('That\'s already your number.');
      return;
    }
    if (_agentId.isEmpty) {
      _snack('Sign in first.');
      return;
    }
    setState(() => _busy = true);
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => OtpVerifyScreen(
        phone: _digits,
        agentId: _agentId,
        changePhone: true,
      ),
    ));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      await AppSettings.setMobile(_digits); // session phone already updated by verify
      if (!mounted) return;
      Navigator.of(context).pop(true);
      _snack('Mobile number updated.');
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Update mobile number')),
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
            children: [
              // Current number chip
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: AppTheme.card(fill: AppTheme.surfaceSoft, radius: 14),
                child: Row(children: [
                  const Icon(Icons.smartphone_outlined,
                      size: 20, color: AppTheme.inkMuted),
                  const SizedBox(width: 12),
                  Text('Current: ',
                      style: AppTheme.body(13, color: AppTheme.inkMuted)),
                  Text(_maskedCurrent,
                      style: AppTheme.body(13.5, weight: FontWeight.w700)),
                ]),
              ),
              const SizedBox(height: 22),
              Text('New mobile number',
                  style: AppTheme.display(17, weight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'We\'ll send a code to confirm you own it. Your account '
                'then moves to this number (works on up to 2 phones).',
                style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 16),
              _phoneField(),
              const SizedBox(height: 24),
              PushButton(
                onPressed: _busy ? null : _verify,
                color: AppTheme.black,
                child: Text(_busy ? 'Please wait…' : 'Send code & verify'),
              ),
            ],
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
              autofocus: true,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: AppTheme.body(15, weight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'New mobile number',
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
