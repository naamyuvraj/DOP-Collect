import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../theme/app_theme.dart';
import '../widgets/press.dart';
import '../widgets/push_button.dart';
import 'change_mobile_screen.dart';
import 'onboarding_login.dart';

/// View the agent's own profile (name, agent name, login id, ASLAAS, photo),
/// with an Edit action and a tap-to-view-full-photo.
class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  String _agent = '', _userId = '', _photo = '', _mobile = '';
  Uint8List? _photoBytes; // decoded once (P4)
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final agent = await AppSettings.agentName();
    final photo = await AppSettings.profilePhoto();
    final mobile = await AppSettings.mobile();
    final creds = await Credentials.load();
    if (!mounted) return;
    setState(() {
      _agent = agent;
      _photo = photo;
      _mobile = mobile;
      _photoBytes = photo.isEmpty ? null : base64Decode(photo);
      _userId = creds.agentId;
      _loading = false;
    });
  }

  String get _initials {
    final n = _agent.trim().isEmpty ? 'Agent' : _agent.trim();
    final parts = n.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return parts.isEmpty
        ? 'A'
        : parts.take(2).map((w) => w[0]).join().toUpperCase();
  }

  void _viewFullPhoto() {
    if (_photoBytes == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: InteractiveViewer(
            child: Image.memory(_photoBytes!),
          ),
        ),
      ),
    ));
  }

  Future<void> _edit() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OnboardingLogin(
          editMode: true, onDone: () => Navigator.of(context).pop()),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                Center(
                  child: GestureDetector(
                    onTap: _viewFullPhoto,
                    child: Container(
                      width: 120,
                      height: 120,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                          color: AppTheme.black, shape: BoxShape.circle),
                      child: _photoBytes == null
                          ? Center(
                              child: Text(_initials,
                                  style: AppTheme.display(40,
                                      weight: FontWeight.w800,
                                      color: AppTheme.onAccent)),
                            )
                          : Image.memory(_photoBytes!, fit: BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(_agent.isEmpty ? 'Agent' : _agent,
                      style: AppTheme.display(24, weight: FontWeight.w800)),
                ),
                const SizedBox(height: 24),
                _row('User ID', _userId.isEmpty ? '—' : _mask(_userId)),
                _row('Mobile', _mobile.isEmpty ? '—' : _mobile),
                _row(
                    'Photo', _photo.isEmpty ? 'Not set' : 'Tap avatar to view'),
                const SizedBox(height: 26),
                PushButton(
                  onPressed: _edit,
                  color: AppTheme.black,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.edit_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Edit Profile'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Both of these were on Settings. They are facts about the person
                // using the app, not things the app does, so they belong with the
                // rest of his details.
                PushButton(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const ChangeMobileScreen()));
                    _load();
                  },
                  color: AppTheme.surface,
                  foreground: AppTheme.ink,
                  child: const Text('Update mobile number'),
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                  child: Text('APPEARANCE',
                      style: AppTheme.label(AppTheme.inkMuted)),
                ),
                _themeToggle(),
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 6),
                  child: Text(
                      'Dark is easier on the eyes at night. Auto follows your phone.',
                      style: AppTheme.body(12, color: AppTheme.inkFaint)),
                ),
              ],
            ),
    );
  }

  /// Light / Dark / Auto, as one segmented control rather than a switch — a
  /// two-state toggle cannot express "follow the phone".
  Widget _themeToggle() {
    final options = <(ThemeMode, String, IconData)>[
      (ThemeMode.light, 'Light', Icons.light_mode_rounded),
      (ThemeMode.dark, 'Dark', Icons.dark_mode_rounded),
      (ThemeMode.system, 'Auto', Icons.brightness_auto_rounded),
    ];
    final current = AppTheme.mode.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: AppTheme.card(radius: 16),
        child: Row(
          children: [
            for (final (mode, label, icon) in options)
              Expanded(
                child: PressFace(
                  // The app root listens to this, persists it, and repaints the
                  // whole tree — nothing to plumb from here.
                  onTap: () => AppTheme.mode.value = mode,
                  height: 46,
                  alignment: Alignment.center,
                  rest: mode == current ? AppTheme.faceOffsetPressed : 0,
                  pressedFace: 0,
                  decoration: (face) => mode == current
                      ? AppTheme.card(
                          fill: AppTheme.black, radius: 12, offset: face)
                      : const BoxDecoration(),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon,
                          size: 17,
                          color: mode == current
                              ? AppTheme.onAccent
                              : AppTheme.inkFaint),
                      const SizedBox(width: 7),
                      Text(label,
                          style: AppTheme.body(13.5,
                              weight: FontWeight.w700,
                              color: mode == current
                                  ? AppTheme.onAccent
                                  : AppTheme.inkFaint)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _mask(String s) =>
      s.length <= 3 ? s : '${'•' * (s.length - 3)}${s.substring(s.length - 3)}';

  Widget _row(String k, String v) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: AppTheme.card(radius: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: AppTheme.body(13, color: AppTheme.inkMuted)),
            Text(v, style: AppTheme.body(15, weight: FontWeight.w700)),
          ],
        ),
      );
}
