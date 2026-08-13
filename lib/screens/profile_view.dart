import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';
import 'onboarding_login.dart';

/// View the agent's own profile (name, agent name, login id, ASLAAS, photo),
/// with an Edit action and a tap-to-view-full-photo.
class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  String _name = '', _agent = '', _userId = '', _photo = '';
  Uint8List? _photoBytes; // decoded once (P4)
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await AppSettings.displayName();
    final agent = await AppSettings.agentName();
    final photo = await AppSettings.profilePhoto();
    final creds = await Credentials.load();
    if (!mounted) return;
    setState(() {
      _name = name;
      _agent = agent;
      _photo = photo;
      _photoBytes = photo.isEmpty ? null : base64Decode(photo);
      _userId = creds.agentId;
      _loading = false;
    });
  }

  String get _initials {
    final n = _name.trim().isEmpty ? 'Agent' : _name.trim();
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
      builder: (_) =>
          OnboardingLogin(editMode: true, onDone: () => Navigator.of(context).pop()),
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
                decoration: const BoxDecoration(
                    color: AppTheme.black, shape: BoxShape.circle),
                child: _photoBytes == null
                    ? Center(
                        child: Text(_initials,
                            style: AppTheme.display(40,
                                weight: FontWeight.w800, color: Colors.white)),
                      )
                    : Image.memory(_photoBytes!, fit: BoxFit.cover),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(_name.isEmpty ? 'Agent' : _name,
                style: AppTheme.display(24, weight: FontWeight.w800)),
          ),
          if (_agent.isNotEmpty)
            Center(
              child: Text(_agent,
                  style: AppTheme.body(14, color: AppTheme.inkMuted)),
            ),
          const SizedBox(height: 24),
          _row('User ID', _userId.isEmpty ? '—' : _mask(_userId)),
          _row('Photo', _photo.isEmpty ? 'Not set' : 'Tap avatar to view'),
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
        ],
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
