import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/account_repository.dart';
import '../../data/credentials.dart';
import '../../data/portal/portal.dart';
import '../../data/portal/portal_sync.dart';
import '../../theme/app_theme.dart';

/// Deep Sync: after login, crawls each account's detail page to pull opening
/// date, exact total deposit, pending/default installments — the data the list
/// screen lacks. One-time-ish (opening date & term never change); slow (~10-15
/// min for the whole book) but resumable — each account is saved as it loads.
class DeepSyncScreen extends StatefulWidget {
  const DeepSyncScreen({super.key, required this.repo});
  final AccountRepository repo;

  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  @override
  State<DeepSyncScreen> createState() => _DeepSyncScreenState();
}

class _DeepSyncScreenState extends State<DeepSyncScreen> {
  late final WebViewController _controller;
  late final PortalSyncEngine _engine;
  Credentials _creds = const Credentials();
  late final Future<void> _credsReady;
  bool _busy = false;
  String? _progress;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(DeepSyncScreen._desktopUa)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _engine.notifyPageFinished();
          _autofillIfLogin();
        },
      ))
      ..loadRequest(Uri.parse(Portal.agentLoginUrl));
    _engine = PortalSyncEngine(_controller);
    _credsReady = Credentials.load().then((c) => _creds = c);
  }

  // Credentials are only ever typed on the real portal origin — the guard is
  // inside the injected script below (see SyncScreen for why the navigation
  // allowlist was removed: it broke the portal's post-login window flow).
  Future<void> _autofillIfLogin() async {
    await _credsReady;
    if (!_creds.hasAny) return;
    final idVal = jsonEncode(_creds.agentId);
    final pwVal = jsonEncode(_creds.password);
    final js = '''
      (function() {
        if (location.origin !== 'https://dopagent.indiapost.gov.in') return;
        function fire(el){['input','change','keyup','blur'].forEach(function(t){
          el.dispatchEvent(new Event(t,{bubbles:true}));});}
        var id = document.querySelector('[name="AuthenticationFG.USER_PRINCIPAL"]');
        var pw = document.querySelector('[name="AuthenticationFG.ACCESS_CODE"]');
        if (!id && !pw) return;
        if (id && !id.value && $idVal) { id.value = $idVal; fire(id); }
        if (pw && !pw.value && $pwVal) { pw.value = $pwVal; fire(pw); }
      })();
    ''';
    await _controller.runJavaScript(js);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) _controller.runJavaScript(js);
    });
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _progress = 'Opening account list…';
    });
    try {
      final n = await _engine.deepSync(
        onAccount: (d) => widget.repo.applyDetail(d),
        onProgress: (page, total, done) => setState(
            () => _progress = 'Page $page/$total · $done accounts read'),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      _snack('Deep sync complete · $n accounts detailed.');
    } catch (e) {
      _snack('Deep sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deep Sync'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _progress ??
                    'Log in, type the captcha, then Start. Takes ~10-15 min.',
                style: AppTheme.body(11, color: AppTheme.inkMuted),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_busy)
            Container(
              color: Colors.black.withValues(alpha: 0.5),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(_progress ?? 'Reading details…',
                      style: AppTheme.body(14, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('Keep this screen open',
                      style: AppTheme.body(11, color: Colors.white70)),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _run,
        icon: const Icon(Icons.download_for_offline_outlined, size: 18),
        label: const Text('Start'),
      ),
    );
  }
}
