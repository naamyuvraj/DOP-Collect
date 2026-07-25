import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/portal/portal.dart';
import '../../data/portal/portal_sync.dart';
import '../../theme/app_theme.dart';

/// Phase-0 recon tool. Loads the DOP portal in a WebView; the agent logs in
/// (typing the captcha) and navigates to Accounts -> Agent Inquire and Update.
/// Tapping "Capture" dumps that page's rendered HTML to a file we can inspect,
/// so the parser can be pinned to the real table markup. The same DOM read is
/// what the Sync engine uses in Phase 2.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final WebViewController _controller;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(Portal.agentLoginUrl));
  }

  Future<void> _capture() async {
    setState(() => _busy = true);
    try {
      final engine = PortalSyncEngine(_controller);
      final html = await engine.currentPageHtml();
      final rows = await engine.parseCurrentPage();

      // Prefer external app dir on Android so it's pullable via a file manager
      // or `adb pull` without root; fall back to the private docs dir.
      final dir = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/agent_capture.html');
      await file.writeAsString(html);

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Captured', style: AppTheme.display(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('HTML size', '${html.length} chars'),
              _kv('Rows parsed', '${rows.length}'),
              _kv('Saved to', file.path),
              const SizedBox(height: 8),
              Text(
                'Send this file to the developer to finish data sync.',
                style: AppTheme.body(12, color: AppTheme.inkMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: file.path));
                Navigator.pop(context);
              },
              child: const Text('Copy path'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Capture failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 84, child: Text(k, style: AppTheme.label(AppTheme.inkMuted))),
            Expanded(child: Text(v, style: AppTheme.body(12))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Portal Capture'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Log in → Accounts → Agent Inquire and Update → Capture',
                style: AppTheme.body(11, color: AppTheme.inkMuted),
              ),
            ),
          ),
        ),
      ),
      body: WebViewWidget(controller: _controller),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _capture,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download, size: 18),
        label: Text(_busy ? 'Capturing…' : 'Capture'),
      ),
    );
  }
}
