import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../dev_profile.dart';
import '../theme/app_theme.dart';

/// "About the developer" card shown in Settings.
class DeveloperCard extends StatelessWidget {
  const DeveloperCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ABOUT THE DEVELOPER',
              style: AppTheme.label(AppTheme.inkMuted)),
          const SizedBox(height: 14),
          Row(
            children: [
              _avatar(context),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(devName,
                        style: AppTheme.display(19, weight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(devRole,
                        style: AppTheme.body(13,
                            weight: FontWeight.w600, color: AppTheme.green)),
                    Text(devEducation,
                        style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(devBio,
              style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.45)),
        ],
      ),
    );
  }

  void _viewFullPhoto(BuildContext context) {
    if (devPhotoBase64.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: InteractiveViewer(
            child: Image.memory(base64Decode(devPhotoBase64),
                filterQuality: FilterQuality.high),
          ),
        ),
      ),
    ));
  }

  Widget _avatar(BuildContext context) {
    const size = 64.0;
    if (devPhotoBase64.isNotEmpty) {
      final Uint8List bytes = base64Decode(devPhotoBase64);
      return GestureDetector(
        onTap: () => _viewFullPhoto(context),
        child: ClipOval(
          child: Image.memory(bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              cacheWidth: (size * 3).round()),
        ),
      );
    }
    // Monogram fallback until the photo is embedded.
    final initials = devName.trim().isEmpty
        ? '?'
        : devName.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
          color: AppTheme.black, shape: BoxShape.circle),
      child: Text(initials.toUpperCase(),
          style: AppTheme.display(24, weight: FontWeight.w800, color: Colors.white)),
    );
  }
}
