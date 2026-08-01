import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../assets_b64.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../services/analytics.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';

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
  bool _saving = false;
  String _photo = '';

  @override
  void initState() {
    super.initState();
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
    for (final c in [_name, _agentName, _userId, _password, _aslaas]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_userId.text.trim().isEmpty || _password.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('User ID and Password are required.')));
      return;
    }
    setState(() => _saving = true);
    await AppSettings.setDisplayName(_name.text);
    await AppSettings.setAgentName(_agentName.text);
    await AppSettings.setAslaas(_aslaas.text);
    await AppSettings.setProfilePhoto(_photo);
    await Credentials(agentId: _userId.text.trim(), password: _password.text)
        .save();
    await AppSettings.setOnboarded(true);
    Analytics.identify(force: true); // re-send now that the agent name is set
    Analytics.track('login');
    if (!mounted) return;
    widget.onDone?.call();
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
                'Set up your agent profile and DOP login. Saved on this phone '
                'only — you just type the captcha each sync.',
                style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 22),
              Center(child: _photoPicker()),
              const SizedBox(height: 22),
              _field(_name, 'Name', Icons.badge_outlined),
              _field(_agentName, 'Agent Name', Icons.person_outline),
              _field(_userId, 'User ID (Agent ID)', Icons.tag),
              _field(_password, 'Password', Icons.lock_outline, obscure: true),
              _field(_aslaas, 'ASLAAS Number', Icons.numbers,
                  keyboard: TextInputType.number),
              const SizedBox(height: 24),
              PushButton(
                onPressed: _saving ? null : _save,
                color: AppTheme.black,
                child: Text(_saving ? 'Saving…' : 'Save & Continue'),
              ),
            ],
          ),
        ),
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
