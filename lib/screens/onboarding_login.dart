import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../assets_b64.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../services/analytics.dart';
import '../services/otp_service.dart';
import '../services/remote_config.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';
import 'otp_verify_screen.dart';
import 'privacy_screen.dart';

/// First-run onboarding.
///  - First run + phone verification ON  -> Log in / Sign up tabs.
///  - First run + verification OFF        -> a single Sign-up form (no OTP).
///  - [editMode] (from the profile screen) -> a plain edit form, no OTP.
///
/// The DOP login (Agent ID + password) is always stored ONLY on this device
/// (encrypted Keystore) — never sent to our server.
class OnboardingLogin extends StatefulWidget {
  const OnboardingLogin({super.key, this.onDone, this.editMode = false});
  final VoidCallback? onDone;
  final bool editMode;

  @override
  State<OnboardingLogin> createState() => _OnboardingLoginState();
}

class _OnboardingLoginState extends State<OnboardingLogin> {
  final _agentName = TextEditingController();
  final _userId = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController(); // sign-up / edit
  final _loginPhone = TextEditingController(); // log-in tab
  bool _busy = false;
  bool _obscure = true;
  bool _agreed = false; // privacy policy accepted (sign up)
  String _photo = '';
  bool _otpOn = RemoteConfig.otpRequired;

  @override
  void initState() {
    super.initState();
    RemoteConfig.refresh().then((_) {
      if (mounted && _otpOn != RemoteConfig.otpRequired) {
        setState(() => _otpOn = RemoteConfig.otpRequired);
      }
    });
    AppSettings.agentName().then((v) => _agentName.text = v);
    AppSettings.mobile().then((v) {
      if (v.isNotEmpty && mounted) _phone.text = v;
    });
    AppSettings.profilePhoto().then((v) {
      if (mounted) setState(() => _photo = v);
    });
    Credentials.load().then((c) {
      _userId.text = c.agentId;
      _password.text = c.password;
    });
    if (OtpService.signedOutRemotely) {
      OtpService.signedOutRemotely = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _snack('Signed out here — your account is now active on '
            '${RemoteConfig.devicesPhrase}. Log out on one of those phones '
            'first, then verify again here.');
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_agentName, _userId, _password, _phone, _loginPhone]) {
      c.dispose();
    }
    super.dispose();
  }

  String _digits(TextEditingController c) => c.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _pickPhoto() async {
    try {
      final x = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 75);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _photo = base64Encode(bytes));
    } catch (_) {
      _snack('Could not open the photo.');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  /// Button content: a white spinner while busy, otherwise the label.
  Widget _btnChild(String label) => _busy
      ? const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
      : Text(label);

  /// Push the OTP screen for [phone] bound to [agentId]. Returns true if verified.
  Future<bool> _verifyPhone(String phone, String agentId) async {
    if (!mounted) return false;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => OtpVerifyScreen(phone: phone, agentId: agentId),
    ));
    return ok == true;
  }

  Future<void> _persist({required String agentId, required String phone}) async {
    await AppSettings.setAgentName(_agentName.text);
    await AppSettings.setProfilePhoto(_photo);
    if (phone.isNotEmpty) await AppSettings.setMobile(phone);
    // DOP login: on-device only, in the encrypted Keystore.
    await Credentials(agentId: agentId, password: _password.text).save();
  }

  Future<void> _finish() async {
    await AppSettings.setOnboarded(true);
    Analytics.identify(force: true);
    Analytics.track('login');
    if (!mounted) return;
    widget.onDone?.call();
  }

  // --- actions --------------------------------------------------------------

  /// Sign up: full details (+ OTP when verification is on) + privacy consent.
  Future<void> _signup() async {
    final agentId = _userId.text.trim();
    if (_agentName.text.trim().isEmpty || agentId.isEmpty || _password.text.isEmpty) {
      _snack('Please fill your Agent name, Agent ID and password.');
      return;
    }
    if (!_agreed) {
      _snack('Please accept the Privacy Policy to continue.');
      return;
    }
    if (_otpOn) {
      if (_digits(_phone).length != 10) {
        _snack('Enter a valid 10-digit mobile number.');
        return;
      }
      if (!await _verifyPhone(_digits(_phone), agentId)) return;
    }
    setState(() => _busy = true);
    await _persist(agentId: agentId, phone: _digits(_phone));
    await _finish();
  }

  /// Log in: mobile number + OTP only. The DOP login stays whatever is already
  /// on this device (entered at Sync if this is a fresh phone — never stored on
  /// our server).
  Future<void> _login() async {
    if (_digits(_loginPhone).length != 10) {
      _snack('Enter your registered 10-digit mobile number.');
      return;
    }
    final agentId = (await Credentials.load()).agentId; // '' on a new device
    if (!await _verifyPhone(_digits(_loginPhone), agentId)) return;
    await AppSettings.setMobile(_digits(_loginPhone));
    if (!mounted) return;
    // Option A: the DOP login lives only on the device. On a fresh phone it
    // isn't here yet, so collect it now (profile form) before entering the app —
    // otherwise Sync would run with no credentials and fail on the captcha.
    if (!await ensureDopLogin(context)) return;
    setState(() => _busy = true);
    await _finish();
  }

  /// Edit profile (no OTP) — just save the details.
  Future<void> _saveEdit() async {
    final agentId = _userId.text.trim();
    if (agentId.isEmpty || _password.text.isEmpty) {
      _snack('User ID and Password are required.');
      return;
    }
    setState(() => _busy = true);
    await _persist(agentId: agentId, phone: _digits(_phone));
    await _finish();
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (widget.editMode) {
      return _formScaffold(
        title: 'Edit profile',
        subtitle: 'Update your details. Saved on this phone only.',
        onSave: _saveEdit,
        saveLabel: 'Save',
        showPhone: true,
        showPrivacy: false,
      );
    }
    if (_otpOn) return _tabbed();
    return _formScaffold(
      title: 'Welcome',
      subtitle: 'Set up your agent profile and DOP login. Saved on this phone '
          'only — you just type the captcha each sync.',
      onSave: _signup,
      saveLabel: 'Create account',
      showPhone: false,
      showPrivacy: true,
    );
  }

  Widget _tabbed() {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: Container(
          decoration: AppTheme.canvas,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
                  child: Row(
                    children: [
                      _logo(48),
                      const SizedBox(width: 12),
                      Text('DOP Collect',
                          style: AppTheme.display(20, weight: FontWeight.w800)),
                    ],
                  ),
                ),
                TabBar(
                  labelColor: AppTheme.black,
                  unselectedLabelColor: AppTheme.inkMuted,
                  indicatorColor: AppTheme.black,
                  labelStyle: AppTheme.body(14, weight: FontWeight.w800),
                  tabs: const [Tab(text: 'Log in'), Tab(text: 'Sign up')],
                ),
                Expanded(
                  child: TabBarView(
                    children: [_loginTab(), _signupTab()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _loginTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
      children: [
        Text('Welcome back',
            style: AppTheme.display(24, weight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'Enter your registered mobile number — we\'ll send a code to log you '
          'in. Works on up to ${RemoteConfig.devicesPhrase}.',
          style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 22),
        _phoneField(_loginPhone, 'Registered mobile number'),
        const SizedBox(height: 24),
        PushButton(
          onPressed: _busy ? null : _login,
          color: AppTheme.black,
          child: _btnChild('Send code & log in'),
        ),
      ],
    );
  }

  Widget _signupTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 32),
      children: [
        Center(child: _photoPicker()),
        const SizedBox(height: 22),
        _sectionLabel('YOUR PROFILE'),
        _field(_agentName, 'Agent name', Icons.person_outline),
        const SizedBox(height: 18),
        _sectionLabel('DOP LOGIN'),
        _field(_userId, 'User ID (Agent ID)', Icons.tag),
        _passwordField(),
        const SizedBox(height: 18),
        _sectionLabel('PHONE VERIFICATION'),
        _phoneField(_phone, 'Mobile number'),
        _securedNote(),
        const SizedBox(height: 14),
        _privacyTick(),
        const SizedBox(height: 20),
        PushButton(
          onPressed: _busy ? null : _signup,
          color: AppTheme.black,
          child: _btnChild('Create account'),
        ),
      ],
    );
  }

  /// Single-form layout for edit mode and the OTP-off first-run sign up.
  Widget _formScaffold({
    required String title,
    required String subtitle,
    required Future<void> Function() onSave,
    required String saveLabel,
    required bool showPhone,
    required bool showPrivacy,
  }) {
    return Scaffold(
      appBar: widget.editMode ? AppBar(title: const Text('Edit profile')) : null,
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
            children: [
              if (!widget.editMode) ...[
                _logo(64),
                const SizedBox(height: 18),
                Text(title, style: AppTheme.display(30, weight: FontWeight.w800)),
                const SizedBox(height: 6),
              ],
              Text(subtitle,
                  style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.4)),
              const SizedBox(height: 24),
              Center(child: _photoPicker()),
              const SizedBox(height: 26),
              _sectionLabel('YOUR PROFILE'),
              _field(_agentName, 'Agent name', Icons.person_outline),
              const SizedBox(height: 18),
              _sectionLabel('DOP LOGIN'),
              _field(_userId, 'User ID (Agent ID)', Icons.tag),
              _passwordField(),
              if (showPhone) ...[
                const SizedBox(height: 18),
                _sectionLabel('PHONE'),
                _phoneField(_phone, 'Mobile number'),
              ],
              if (showPrivacy) ...[
                const SizedBox(height: 16),
                _privacyTick(),
              ],
              const SizedBox(height: 24),
              PushButton(
                onPressed: _busy ? null : onSave,
                color: AppTheme.black,
                child: _btnChild(saveLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- pieces ---------------------------------------------------------------

  Widget _logo(double size) => Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: AppTheme.black, borderRadius: BorderRadius.circular(size / 3.5)),
        child: Image.memory(base64Decode(logoBase64), fit: BoxFit.cover),
      );

  Widget _privacyTick() {
    return GestureDetector(
      onTap: () => setState(() => _agreed = !_agreed),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: _agreed,
            onChanged: (v) => setState(() => _agreed = v ?? false),
            activeColor: AppTheme.black,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text.rich(
                TextSpan(
                  style: AppTheme.body(12.5, color: AppTheme.inkMuted, height: 1.4),
                  children: [
                    const TextSpan(
                        text: 'My customers\' details stay encrypted on this '
                            'phone and are never uploaded. I agree to the '),
                    TextSpan(
                      text: 'Privacy & Data Policy',
                      style: AppTheme.body(12.5,
                              weight: FontWeight.w700, color: AppTheme.black)
                          .copyWith(decoration: TextDecoration.underline),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const PrivacyScreen())),
                    ),
                    const TextSpan(
                        text: ', including the anonymous usage data it '
                            'describes.'),
                  ],
                ),
              ),
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
                ? const Icon(Icons.person_rounded, size: 44, color: AppTheme.inkFaint)
                : Image.memory(base64Decode(_photo), fit: BoxFit.cover),
          ),
          Container(
            padding: const EdgeInsets.all(7),
            decoration:
                const BoxDecoration(color: AppTheme.black, shape: BoxShape.circle),
            child: const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(text,
            style: AppTheme.body(11.5,
                weight: FontWeight.w800, color: AppTheme.inkFaint)),
      );

  Widget _securedNote() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4, left: 4),
        child: Row(
          children: [
            const Icon(Icons.verified_user_outlined,
                size: 15, color: AppTheme.inkFaint),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'One code confirms this is you. Works on up to '
                '${RemoteConfig.devicesPhrase}.',
                style: AppTheme.body(11.5, color: AppTheme.inkFaint, height: 1.3),
              ),
            ),
          ],
        ),
      );

  Widget _phoneField(TextEditingController c, String label) {
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
                controller: c,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: AppTheme.body(15, weight: FontWeight.w600),
                decoration: InputDecoration(
                  labelText: label,
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

/// Ensures the DOP portal login (Agent ID + password) is on THIS device before
/// a portal action (Sync/Deep Sync/ASLAAS). If it's missing — e.g. after a
/// phone-only login on a fresh phone — it routes to the profile form to fill it
/// in, then returns true once present. Keeps the DOP login on-device only.
Future<bool> ensureDopLogin(BuildContext context) async {
  var c = await Credentials.load();
  if (c.agentId.trim().isNotEmpty && c.password.isNotEmpty) return true;
  if (!context.mounted) return false;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(const SnackBar(
        content: Text('Add your DOP portal login (Agent ID + password) first.')));
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (ctx) => OnboardingLogin(
        editMode: true, onDone: () => Navigator.of(ctx).maybePop()),
  ));
  c = await Credentials.load();
  return c.agentId.trim().isNotEmpty && c.password.isNotEmpty;
}
