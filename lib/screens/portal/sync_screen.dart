import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/account_repository.dart';
import '../../data/credentials.dart';
import '../../data/portal/agent_detail_parser.dart';
import '../../data/portal/captcha_solver.dart';
import '../../data/portal/portal.dart';
import '../../services/analytics.dart';
import '../../data/portal/portal_sync.dart';
import '../../theme/app_theme.dart';

/// One-touch Sync. The WebView identifies as desktop Chrome (the legacy portal
/// breaks under a mobile UA), auto-fills the saved Agent ID/password so only the
/// captcha is typed, then on Sync it auto-navigates to the account list and
/// walks all pages into the local DB.
class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.repo,
    this.prepareAccounts,
    this.prepareMode,
    this.detailAccount,
    this.detailSerial,
  });
  final AccountRepository repo;

  /// If set, fetch this one account's exact detail (last-deposit date, total
  /// deposit, pending/default installments) and save it.
  final String? detailAccount;
  final int? detailSerial;

  /// If set, the screen runs "prepare list" instead of a data sync: after login
  /// it selects the payment mode, ticks these account numbers across the portal
  /// pages, and clicks Save. The agent then finishes installments + Pay All.
  final Set<String>? prepareAccounts;
  final String? prepareMode; // 'C' | 'DC' | 'NDC'

  bool get isPrepare => prepareAccounts != null;
  bool get isDetail => detailAccount != null;

  // Desktop Chrome UA — makes the Finacle portal render its full desktop pages.
  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final WebViewController _controller;
  late final PortalSyncEngine _engine;
  final CaptchaSolver _captcha = CaptchaSolver();
  Credentials _creds = const Credentials();
  bool _busy = false;
  bool _filling = false;
  bool _stopFill = false;
  bool _autoStarted = false;
  bool _solvingCaptcha = false;
  String? _progress;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(SyncScreen._desktopUa)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _engine.notifyPageFinished();
          _autofillIfLogin();
          // Fresh page — let the captcha <img> finish loading, then read it.
          _captchaTries = 0;
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted) _autofillCaptcha();
          });
          _maybeAutoStart();
        },
      ))
      ..loadRequest(Uri.parse(Portal.agentLoginUrl));
    _engine = PortalSyncEngine(_controller);
    Credentials.load().then((c) => _creds = c);
  }

  @override
  void dispose() {
    _captcha.dispose();
    super.dispose();
  }

  // --- Auto captcha (on-device OCR) ----------------------------------------
  // Reads the login captcha image locally with ML Kit and pre-fills the code.
  // The image is drawn to a canvas in-page and passed out as a data URL, so no
  // image ever leaves the phone. Best-effort — the user still taps Login, so a
  // wrong read is easy to correct (and we never auto-retry a bank login).

  // Robust captcha finder: the DOP captcha <img> has no reliable src/id, so we
  // score EVERY image by captcha-like traits (small, wide, keyword hints) and
  // render the best complete one to a canvas. Returns a JSON string
  // {data, loading, dbg} — dbg surfaces what was found so failures are
  // diagnosable on-device.
  static const _captchaExtractJs = r'''
    (function(){
      function toData(img){
        try{
          var w=img.naturalWidth||img.width, h=img.naturalHeight||img.height;
          if(!w||!h) return '';
          // Captcha imgs are tiny (~120x22); ML Kit needs a bigger, cleaner
          // image. Upscale to ~180px tall, greyscale, then binarize (drops the
          // grey background + colour so only the glyphs remain).
          var scale=Math.max(3, Math.min(8, Math.round(180/h)));
          var c=document.createElement('canvas'); c.width=w*scale; c.height=h*scale;
          var ctx=c.getContext('2d');
          ctx.imageSmoothingEnabled=true; ctx.imageSmoothingQuality='high';
          ctx.drawImage(img,0,0,c.width,c.height);
          var id=ctx.getImageData(0,0,c.width,c.height), d=id.data, sum=0, n=d.length/4;
          for(var i=0;i<d.length;i+=4){
            var g=0.299*d[i]+0.587*d[i+1]+0.114*d[i+2];
            d[i]=d[i+1]=d[i+2]=g; sum+=g;
          }
          var th=(sum/n)*0.82;
          for(var j=0;j<d.length;j+=4){
            var v=d[j]<th?0:255; d[j]=d[j+1]=d[j+2]=v; d[j+3]=255;
          }
          ctx.putImageData(id,0,0);
          return c.toDataURL('image/png');
        }catch(e){ return 'TAINT'; }
      }
      var imgs=Array.prototype.slice.call(document.querySelectorAll('img'));
      var scored=imgs.map(function(img){
        var w=img.naturalWidth||img.width||0, h=img.naturalHeight||img.height||0;
        var meta=((img.getAttribute('src')||'')+' '+(img.id||'')+' '+
                  (img.className||'')+' '+(img.alt||'')+' '+(img.name||''));
        var s=0;
        if(/captcha|verif|random|securimage|seccode|imgtext|numimg/i.test(meta)) s+=5;
        if(w>=55&&w<=340&&h>=16&&h<=120) s+=3;   // captcha-sized
        if(h>0 && w>h*1.5) s+=1;                 // wide
        return {img:img,w:w,h:h,s:s,done:img.complete};
      }).sort(function(a,b){return b.s-a.s;});
      var loading=false, data='', taint=false, chosen=null;
      for(var i=0;i<scored.length;i++){
        if(scored[i].s<3) break;
        if(!scored[i].done){ loading=true; continue; }
        var d=toData(scored[i].img);
        if(d==='TAINT'){ taint=true; continue; }
        if(d && d.indexOf('data:')===0){ data=d; chosen=scored[i]; break; }
      }
      var top=scored[0];
      var dbg=imgs.length+' imgs; top '+(top?top.w+'x'+top.h+' s'+top.s:'none')+
              (chosen?'; used '+chosen.w+'x'+chosen.h:'')+
              (taint?'; TAINT':'')+(loading&&!data?'; loading':'');
      return JSON.stringify({data:data, loading:(data===''&&loading), dbg:dbg});
    })();
  ''';

  String _fillCaptchaJs(String code) => '''
    (function(){
      var f=document.querySelector('[name*="VERIFICATION_CODE" i]')
         || document.querySelector('input[name*="CAPTCHA" i]')
         || document.querySelector('input[id*="captcha" i]');
      if(!f) return 'false';
      f.value=${jsonEncode(code)};
      ['input','change','keyup','blur'].forEach(function(t){
        f.dispatchEvent(new Event(t,{bubbles:true}));});
      return 'true';
    })();
  ''';

  int _captchaTries = 0;
  int _loginClicks = 0; // hard cap on auto-submits (lockout guard)

  /// The portal's Log in button. Finacle names it VALIDATE_CREDENTIALS; fall
  /// back to value/text matching so a relabelled deployment still works.
  static const _loginJs = r'''
    (function(){
      var b=document.querySelector('input[name*="VALIDATE_CREDENTIALS" i]')
        || document.querySelector('input[type="submit"][value*="Log" i]')
        || document.querySelector('input[type="button"][value*="Log" i]')
        || document.querySelector('input[value="Log in" i]');
      if(!b){
        var els=document.querySelectorAll('a,button,input');
        for(var i=0;i<els.length;i++){
          var t=(els[i].innerText||els[i].value||'').trim().toLowerCase();
          if(t==='log in'||t==='login'){ b=els[i]; break; }
        }
      }
      if(!b || b.disabled) return 'false';
      b.click(); return 'true';
    })();
  ''';

  Future<void> _autofillCaptcha({bool manual = false}) async {
    if (_solvingCaptcha) return;
    _solvingCaptcha = true;
    if (manual) _captchaTries = 0;
    try {
      final raw = _decode(
          await _controller.runJavaScriptReturningResult(_captchaExtractJs));
      Map<String, dynamic> res;
      try {
        res = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        res = {'data': '', 'loading': false, 'dbg': 'parse-fail'};
      }
      final data = (res['data'] as String?) ?? '';
      final loading = res['loading'] == true;
      final dbg = (res['dbg'] as String?) ?? '';

      if (data.isEmpty && loading && _captchaTries < 6) {
        _captchaTries++;
        _solvingCaptcha = false;
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) _autofillCaptcha(manual: manual);
        });
        return;
      }
      if (!data.startsWith('data:')) {
        if (manual) _snack('No captcha image found · $dbg');
        return;
      }
      final guess = await _captcha.solveFromDataUrl(data);
      if (guess == null || guess.isEmpty) {
        if (manual) _snack('Captcha unreadable — type it · $dbg');
        return;
      }
      final ok = _decode(
          await _controller.runJavaScriptReturningResult(_fillCaptchaJs(guess)));
      if (!ok.contains('true')) {
        if (manual) _snack('Captcha box not found to fill · $dbg');
        return;
      }
      // Auto-submit. Capped at 2 tries per screen so a bad OCR read can never
      // burn through the portal's 10-attempt lockout — after that it's manual.
      if (_loginClicks < 2) {
        _loginClicks++;
        final clicked =
            _decode(await _controller.runJavaScriptReturningResult(_loginJs));
        if (clicked.contains('true')) {
          if (mounted) _snack('Captcha $guess — logging in…');
          return;
        }
      }
      if (mounted) _snack('Captcha filled: $guess — tap Login.');
    } catch (e) {
      if (manual) _snack('Captcha auto-fill failed: $e');
    } finally {
      _solvingCaptcha = false;
    }
  }

  String _decode(Object result) {
    var s = result.toString();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {/* leave as-is */}
    }
    return s;
  }

  /// Fill Agent ID + password on the Agent Login page (leaves the captcha).
  /// Targets the portal's exact field names and fires input/change/keyup so the
  /// portal's own scripts (which read/encrypt the value on submit) pick it up.
  /// Runs on page-finish plus one short retry, since the page wires its virtual
  /// keypad after load.
  Future<void> _autofillIfLogin() async {
    if (!_creds.hasAny) return;
    final idVal = jsonEncode(_creds.agentId);
    final pwVal = jsonEncode(_creds.password);
    final js = '''
      (function() {
        function fire(el){['input','change','keyup','blur'].forEach(function(t){
          el.dispatchEvent(new Event(t,{bubbles:true}));});}
        var id = document.querySelector('[name="AuthenticationFG.USER_PRINCIPAL"]');
        var pw = document.querySelector('[name="AuthenticationFG.ACCESS_CODE"]');
        if (!id && !pw) return; // not the login page
        if (id && !id.value && $idVal) { id.value = $idVal; fire(id); }
        if (pw && !pw.value && $pwVal) { pw.value = $pwVal; fire(pw); }
      })();
    ''';
    await _controller.runJavaScript(js);
    // Retry once: the login page finishes its keypad wiring shortly after load.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) _controller.runJavaScript(js);
    });
  }

  /// Once login succeeds (we're inside the authenticated portal), kick off the
  /// sync automatically so the agent only has to type the captcha. The sync
  /// itself navigates Dashboard → Accounts → Enquire → the list. Fires once.
  Future<void> _maybeAutoStart() async {
    if (_busy || _autoStarted) return;
    final authed = await _engine.isAuthenticated();
    if (authed && !_busy && !_autoStarted) {
      _autoStarted = true;
      if (widget.isDetail) {
        _fetchDetail();
      } else if (widget.isPrepare) {
        _prepare();
      } else {
        _sync();
      }
    }
  }

  /// After the fast list sync, fill in the exact per-account figures (real
  /// last-deposit date, total deposit, pending/default installments) for every
  /// account still missing them. Runs in the same logged-in session, saves each
  /// account as it lands, and can be stopped at any point — whatever was
  /// fetched is kept and the next sync picks up the rest.
  Future<void> _fillDetails() async {
    final all = await widget.repo.all();
    final pending = all.where((a) => !a.hasExactDetail).toList();
    if (pending.isEmpty || !mounted) return;

    final needed = pending.map((a) => a.accountNumber).toSet();
    // Resume where we left off: jump to the page holding the first account
    // that still needs detail (10 rows per page, portal order).
    final firstSerial = pending
        .map((a) => a.serial)
        .where((s) => s > 0)
        .fold<int>(1 << 30, (m, s) => s < m ? s : m);
    final startPage =
        firstSerial == 1 << 30 ? 1 : ((firstSerial - 1) ~/ 10) + 1;

    _stopFill = false;
    setState(() {
      _filling = true;
      _progress = 'Reading deposit report…';
    });

    var diag = '';
    try {
      // One call first: the "View Saved Installments" report can cover many
      // accounts' last-deposit dates in a single page load.
      var bulk = 0;
      final report = await _engine.fetchSavedInstallments(
          onDiag: (r) => diag = 'report: $r');
      for (final e in report.entries) {
        if (!needed.contains(e.key)) continue;
        await widget.repo
            .applyDetail(AccountDetail(accountNumber: e.key, lastDepositDate: e.value));
        bulk++;
      }
      if (bulk > 0) {
        needed.removeWhere(report.containsKey);
        if (!mounted) return;
        setState(() => _progress = 'Got $bulk from the report…');
      }
      if (needed.isEmpty) {
        if (mounted) {
          _snack('Last-deposit dates filled for $bulk accounts in one call.');
        }
        return;
      }

      final done = await _engine.fillDetails(
        needed: needed,
        startPage: startPage,
        onAccount: (d) => widget.repo.applyDetail(d),
        shouldStop: () => _stopFill || !mounted,
        onDiag: (r) => diag = r,
        onProgress: (done, target) => setState(() =>
            _progress = 'Filling in details $done of $target… '
                '(${needed.length} left overall)'),
      );
      if (!mounted) return;
      final left = needed.length - done;
      _snack(done == 0
          ? 'Details failed${diag.isEmpty ? '' : ' · $diag'}'
          : left > 0
              ? 'Filled $done. $left left — the next sync continues.'
              : 'All account details are up to date.');
    } catch (_) {
      // Partial progress is already saved; the next sync resumes.
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  /// Pull ONE account's exact figures from its portal detail page and save.
  Future<void> _fetchDetail() async {
    setState(() {
      _busy = true;
      _progress = 'Finding the account…';
    });
    try {
      final detail = await _engine.fetchAccountDetail(
        accountNumber: widget.detailAccount!,
        serialHint: widget.detailSerial,
        onProgress: (m) => setState(() => _progress = m),
      );
      if (detail == null) {
        _snack('Could not read that account on the portal.');
        return;
      }
      await widget.repo.applyDetail(detail);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      _snack('Details updated from the portal.');
    } catch (e) {
      _snack('Detail fetch failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Prepare-list mission: pick mode, tick this lot's accounts across pages,
  /// Save. Leaves the WebView on the installment screen for manual Pay All.
  Future<void> _prepare() async {
    setState(() {
      _busy = true;
      _progress = 'Opening account list…';
    });
    try {
      final res = await _engine.prepareList(
        accountNumbers: widget.prepareAccounts!,
        mode: widget.prepareMode ?? 'C',
        onProgress: (page, total, selected) => setState(
            () => _progress = 'Page $page of $total · $selected selected'),
      );
      if (!mounted) return;
      if (res.selected.isEmpty) {
        _snack(res.error ?? 'No matching accounts found on the portal.');
        return;
      }
      final miss = res.missing(widget.prepareAccounts!);
      final missNote = miss.isEmpty ? '' : ' (${miss.length} not found)';
      if (res.saved) {
        _snack('Selected & saved ${res.selected.length}$missNote. Now enter '
            'installments + ASLAAS and tap Pay All on the portal.');
      } else {
        _snack('Selected ${res.selected.length}$missNote. '
            '${res.error ?? 'Tap Save on the portal.'}');
      }
    } catch (e) {
      _snack('Prepare failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _progress = 'Opening account list…';
    });
    try {
      final result = await _engine.syncAllPages(
        onProgress: (page, total, count) =>
            setState(() => _progress = 'Page $page of $total · $count accounts'),
      );
      if (result.accounts.isEmpty) {
        _snack(result.error ?? 'No accounts found.');
        return;
      }
      await widget.repo.replaceAll(result.accounts);
      unawaited(
          Analytics.track('sync_done', {'accounts': result.accounts.length}));
      if (!mounted) return;
      _snack(result.error ?? 'Synced ${result.accounts.length} accounts.');
      // Accounts are safely stored — now top up the exact per-account figures
      // in the same session. Stoppable, and resumes on the next sync.
      await _fillDetails();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _snack('Sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editLogin() async {
    final idCtrl = TextEditingController(text: _creds.agentId);
    final pwCtrl = TextEditingController(text: _creds.password);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Saved login', style: AppTheme.display(18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(labelText: 'Agent ID'),
            ),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 8),
            Text('Stored only on this phone. Captcha is always typed manually.',
                style: AppTheme.body(11, color: AppTheme.inkMuted)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      _creds = Credentials(agentId: idCtrl.text.trim(), password: pwCtrl.text);
      await _creds.save();
      await _autofillIfLogin();
      _snack('Login saved.');
    }
  }

  /// Debug: dump the current page HTML so auto-nav can be tuned if it stalls.
  Future<void> _capture() async {
    try {
      final html = await _engine.currentPageHtml();
      final dir = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/portal_capture.html');
      await file.writeAsString(html);
      _snack('Saved page (${html.length} chars) to ${file.path}');
    } catch (e) {
      _snack('Capture failed: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isDetail
            ? 'Account Details'
            : widget.isPrepare
                ? 'Prepare List'
                : 'Sync'),
        actions: [
          IconButton(
              tooltip: 'Auto-fill captcha',
              icon: const Icon(Icons.auto_fix_high_outlined),
              onPressed: () => _autofillCaptcha(manual: true)),
          IconButton(
              tooltip: 'Saved login',
              icon: const Icon(Icons.key_outlined),
              onPressed: _editLogin),
          IconButton(
              tooltip: 'Capture page (debug)',
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: _capture),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _progress ??
                    'Log in and type the captcha — sync starts automatically.',
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
              color: Colors.black.withValues(alpha: 0.45),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(_progress ?? 'Syncing…',
                      style: AppTheme.body(14, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text(
                      _filling
                          ? 'Accounts are already saved — this just adds exact '
                              'figures. You can stop anytime.'
                          : 'Keep this screen open',
                      textAlign: TextAlign.center,
                      style: AppTheme.body(11, color: Colors.white70)),
                  if (_filling) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppTheme.ink,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => setState(() => _stopFill = true),
                      child: const Text('Stop & finish'),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy
            ? null
            : (widget.isPrepare ? _prepare : _sync),
        icon: Icon(widget.isPrepare ? Icons.playlist_add_check : Icons.sync,
            size: 18),
        label: Text(widget.isPrepare ? 'Prepare' : 'Sync'),
      ),
    );
  }
}
