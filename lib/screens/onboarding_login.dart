import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../assets_b64.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../data/session.dart';
import '../services/analytics.dart';
import '../services/otp_service.dart';
import '../services/remote_config.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';
import 'otp_verify_screen.dart';

/// First-run setup: capture the agent's profile + DOP login once. Stored on the
/// device and used to auto-fill Sync (only the captcha is typed each time).
class OnboardingLogin extends StatefulWidget {
  const OnboardingLogin({super.key, this.onDone});
  final VoidCallback? onDone;

  @override
  State<OnboardingLogin> createState() => _OnboardingLoginState();
}

class _OnboardingLoginState extends State<OnboardingLogin> {
  final _name = TextEditingController();
  final _agentName = TextEditingController();
  final _userId = TextEditingController();
  final _password = TextEditingController();
  final _aslaas = TextEditingController();
  final _phone = TextEditingController();
  bool _saving = false;
  String _photo = '';
  bool _obscure = true;
  // Captured ONCE so the phone field's visibility and the save-time validation
  // always agree (RemoteConfig loads async; reading it in two places caused the
  // "asks for phone but shows no field" race). Refreshed reactively below.
  bool _otpOn = RemoteConfig.otpRequired;

  @override
  void initState() {
    super.initState();
    // The remote config may still be refreshing from startup; re-read it once
    // it settles so the phone step appears (and validation matches) reliably.
    RemoteConfig.refresh().then((_) {
      if (mounted && _otpOn != RemoteConfig.otpRequired) {
        setState(() => _otpOn = RemoteConfig.otpRequired);
      }
    });
    // Pre-fill if returning to edit.
    AppSettings.displayName().then((v) => _name.text = v);
    AppSettings.agentName().then((v) => _agentName.text = v);
    AppSettings.aslaas().then((v) => _aslaas.text = v);
    AppSettings.profilePhoto().then((v) {
      if (mounted) setState(() => _photo = v);
    });
    Credentials.load().then((c) {
      _userId.text = c.agentId;
      _password.text = c.password;
    });
    SessionStore.load().then((s) {
      if (s != null && s.phone.isNotEmpty && mounted) _phone.text = s.phone;
    });
    // If the startup heartbeat signed us out (kicked by the 2-device limit),
    // explain why — once.
    if (OtpService.signedOutRemotely) {
      OtpService.signedOutRemotely = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _snack('Signed out here — your account is now active on 2 other phones. '
            'Verify again to use it on this one.');
      });
    }
  }

  Future<void> _pickPhoto() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      setState(() => _photo = base64Encode(bytes));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open the photo.')));
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _agentName, _userId, _password, _aslaas, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _phoneDigits => _phone.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _save() async {
    final agentId = _userId.text.trim();
    if (agentId.isEmpty || _password.text.isEmpty) {
      _snack('User ID and Password are required.');
      return;
    }
    final otpOn = _otpOn;
    if (otpOn && _phoneDigits.length != 10) {
      _snack('Enter your 10-digit mobile number to verify on WhatsApp.');
      return;
    }

    // Secured step: verify the phone over WhatsApp before finishing. Re-verify
    // whenever there's no session OR the Agent ID differs from the one this
    // device's session is bound to — so the agent↔phone pair can't be silently
    // swapped under an existing session (the server enforces the 1:1 pair, and
    // rejects a conflicting pair with "already linked"). Skipped when otp is off.
    if (otpOn) {
      final session = await SessionStore.load();
      final needVerify = session == null || session.agentId != agentId;
      if (needVerify) {
        if (!mounted) return;
        final verified = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => OtpVerifyScreen(phone: _phoneDigits, agentId: agentId),
        ));
        if (verified != true) return; // backed out / failed / pair conflict
      }
    }

    setState(() => _saving = true);
    await AppSettings.setDisplayName(_name.text);
    await AppSettings.setAgentName(_agentName.text);
    await AppSettings.setAslaas(_aslaas.text);
    if (_phoneDigits.isNotEmpty) await AppSettings.setMobile(_phoneDigits);
    await AppSettings.setProfilePhoto(_photo);
    await Credentials(agentId: agentId, password: _password.text).save();
    await AppSettings.setOnboarded(true);
    Analytics.identify(force: true); // re-send now that the agent name is set
    Analytics.track('login');
    if (!mounted) return;
    widget.onDone?.call();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
            children: [
              Container(
                width: 64,
                height: 64,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppTheme.black,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Image.memory(base64Decode(logoBase64),
                    fit: BoxFit.cover),
              ),
              const SizedBox(height: 18),
              Text('Welcome',
                  style: AppTheme.display(30, weight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                _otpOn
                    ? 'Set up your profile and DOP login, then verify your phone '
                        'on WhatsApp. Saved on this phone only.'
                    : 'Set up your agent profile and DOP login. Saved on this '
                        'phone only — you just type the captcha each sync.',
                style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 24),
              Center(child: _photoPicker()),
              const SizedBox(height: 26),

              _sectionLabel('YOUR PROFILE'),
              _field(_name, 'Name', Icons.badge_outlined),
              _field(_agentName, 'Agent Name', Icons.person_outline),

              const SizedBox(height: 18),
              _sectionLabel('DOP LOGIN'),
              _field(_userId, 'User ID (Agent ID)', Icons.tag),
              _passwordField(),

              const SizedBox(height: 18),
              _sectionLabel('COLLECTION'),
              _field(_aslaas, 'ASLAAS Number', Icons.numbers,
                  keyboard: TextInputType.number),

              if (_otpOn) ...[
                const SizedBox(height: 18),
                _sectionLabel('PHONE · WHATSAPP VERIFICATION'),
                _phoneField(),
                _securedNote(),
              ],

              const SizedBox(height: 28),
              PushButton(
                onPressed: _saving ? null : _save,
                color: AppTheme.black,
                child: Text(_saving
                    ? 'Saving…'
                    : _otpOn
                        ? 'Verify & Continue'
                        : 'Save & Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Phone number with a fixed +91 prefix; only 10 digits are accepted.
  Widget _phoneField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
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
      ),
    );
  }

  Widget _passwordField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: AppTheme.card(radius: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _password,
          obscureText: _obscure,
          style: AppTheme.body(15, weight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: 'Password',
            labelStyle: AppTheme.body(13, color: AppTheme.inkMuted),
            prefixIcon:
                const Icon(Icons.lock_outline, color: AppTheme.inkFaint, size: 20),
            suffixIcon: IconButton(
              icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: AppTheme.inkFaint,
                  size: 20),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text,
        style: AppTheme.body(11.5,
            weight: FontWeight.w800, color: AppTheme.inkFaint),
      ),
    );
  }

  Widget _securedNote() {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4, left: 4),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined,
              size: 15, color: AppTheme.inkFaint),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              'One WhatsApp code confirms this is you. Works on up to 2 phones.',
              style: AppTheme.body(11.5, color: AppTheme.inkFaint, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _photoPicker() {
    return GestureDetector(
      onTap: _pickPhoto,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Container(
            width: 96,
            height: 96,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.surfaceSoft,
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.line, width: 2),
            ),
            child: _photo.isEmpty
                ? const Icon(Icons.person_rounded,
                    size: 44, color: AppTheme.inkFaint)
                : Image.memory(base64Decode(_photo), fit: BoxFit.cover),
          ),
          Container(
            padding: const EdgeInsets.all(7),
            decoration: const BoxDecoration(
                color: AppTheme.black, shape: BoxShape.circle),
            child: const Icon(Icons.photo_camera_rounded,
                size: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {bool obscure = false, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: AppTheme.card(radius: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: c,
          obscureText: obscure,
          keyboardType: keyboard,
          style: AppTheme.body(15, weight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: AppTheme.body(13, color: AppTheme.inkMuted),
            prefixIcon: Icon(icon, color: AppTheme.inkFaint, size: 20),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }
}
