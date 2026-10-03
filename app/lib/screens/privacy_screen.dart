import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/developer_card.dart';

/// In-app Privacy Policy & Safety summary. Plain-language, and the canonical
/// statement of the app's data practices (also linked from the Play listing).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Safety')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
        children: [
          _intro(),
          const SizedBox(height: 14),
          _section('Encrypted local store & Cloud Sync', [
            'Your customers, account numbers, amounts and dues are stored '
                'encrypted (AES-256) on this device.',
            'To support multi-device sync between your phone and desktop app, '
                'your customer book is securely backed up to an isolated, '
                'encrypted database accessible only via your authenticated session.',
            'That cloud store has Row Level Security (RLS) enabled, so no '
                'unauthorized third party can access your book.',
          ], tone: AppTheme.greenSoft, dot: AppTheme.green),
          _section('Your DOP login (Never Uploaded)', [
            'Your Agent ID and DOP portal password stay strictly inside your phone\'s '
                'hardware-backed Keystore in encrypted form.',
            'They are used ONLY on-device to log into the official India Post '
                'portal on your behalf. They are NEVER uploaded to our cloud server or any third party.',
            'Tap Logout in Settings to remove them from your phone at any time.',
          ], tone: AppTheme.blueSoft, dot: AppTheme.accent),
          _section('The AI assistant', [
            'Common questions are answered fully offline, on your phone.',
            'For other questions, only the question and a description of the '
                'data structure (never customer names, numbers or amounts) are '
                'sent to the AI service to work out the answer.',
            'With no network, the assistant answers on-device by itself — there '
                'is nothing to switch on.',
          ], tone: AppTheme.focal, dot: AppTheme.amberOnFocal),
          _section('Account & Telemetry Data', [
            'About you: your Agent name, your Agent ID, your post-office '
                'region (SOL), your phone model and your mobile number. This '
                'runs your account and limits it to your own devices.',
            'About usage: device IDs, app version, and event diagnostics '
                'like "sync completed" or "calculator used".',
            'Your mobile number is stored as a one-way hashed code.',
          ], tone: AppTheme.surfaceSoft, dot: AppTheme.inkMuted),
          _section('Security', [
            'The account database on this phone is encrypted at rest with '
                'AES-256 (SQLCipher).',
            'Your DOP password never leaves the encrypted Keystore, and the '
                'captcha is read on-device.',
            'All network traffic uses HTTPS.',
            'No advertising or tracking SDKs are included.',
          ], tone: AppTheme.greenSoft, dot: AppTheme.green),
          _section('Permissions', [
            'Internet — to reach the DOP portal and sync your encrypted book.',
            'Microphone — only when you tap the mic to ask the assistant by '
                'voice.',
          ], tone: AppTheme.blueSoft, dot: AppTheme.accent),
          const SizedBox(height: 18),
          Text(
            'This app is an independent tool to help India Post RD collection '
            'agents manage their own accounts. It is not affiliated with or '
            'endorsed by the Department of Posts.',
            style: AppTheme.body(11.5, color: AppTheme.inkFaint, height: 1.5),
          ),
          const SizedBox(height: 18),
          const DeveloperCard(),
        ],
      ),
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your data stays yours',
              style: AppTheme.display(20, weight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'DOP Collect is designed for privacy and reliability. Your book is '
            'encrypted on this phone and securely synced to your devices. '
            'Your DOP portal password never leaves your handset.',
            style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<String> points,
      {required Color tone, required Color dot}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: AppTheme.panel(tone, radius: 8),
                child: Icon(Icons.check_rounded, size: 16, color: dot),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: AppTheme.display(15.5, weight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...points.map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 7, left: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration:
                            BoxDecoration(color: dot, shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(
                      child: Text(p,
                          style: AppTheme.body(12.5,
                              color: AppTheme.ink, height: 1.4)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
