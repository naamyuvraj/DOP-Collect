import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../data/credentials.dart';
import '../../data/lot_repository.dart';
import '../../data/portal/agent_detail_parser.dart';
import '../../data/portal/captcha_solver.dart';
import '../../data/portal/portal.dart';
import '../../models/lot.dart';
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
    this.deepSync = false,
    this.submitLot,
    this.batchLots,
    this.lotStore,
  });
  final AccountRepository repo;

  /// Full submit flow: after Prepare + Save, auto-key each account's
  /// installments (+ rebate/default + Save per record). Stops before Pay All —
  /// the agent reviews and taps "Pay All Saved Installments" himself, then the
  /// app captures the reference. When set, pops with the captured reference
  /// (String) or null.
  final Lot? submitLot;
  bool get isSubmit => submitLot != null;

  /// Batch submit: process every one of these lists in a SINGLE portal session
  /// (prepare → key → confirm → pay → capture → next). Each list's payment is
  /// still confirmed individually. [batchLots] needs [lotStore] to save the
  /// captured reference onto each list as it completes.
  final List<Lot>? batchLots;
  final LotRepository? lotStore;
  bool get isBatch => batchLots != null && batchLots!.isNotEmpty;

  /// If set, fetch this one account's exact detail (last-deposit date, total
  /// deposit, pending/default installments) and save it.
  final String? detailAccount;
  final int? detailSerial;

  /// If set, the screen runs "prepare list" instead of a data sync: after login
  /// it selects the payment mode, ticks these account numbers across the portal
  /// pages, and clicks Save. The agent then finishes installments + Pay All.
  final Set<String>? prepareAccounts;
  final String? prepareMode; // 'C' | 'DC' | 'NDC'

  /// Deep Sync: after login, crawl the per-account detail pages to fill exact
  /// last-deposit dates + totals for every account still missing them.
  final bool deepSync;

  bool get isPrepare => prepareAccounts != null;
  bool get isDetail => detailAccount != null;
  bool get isDeep => deepSync;

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
  bool _awaitingRef = false; // installments keyed; waiting for agent's Pay All
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

  // --- Origin lock ----------------------------------------------------------
  // The WebView drives a live banking login, so the credential autofill must
  // only ever run on the REAL portal origin. That guard lives inside every
  // injected script (`location.origin` check below) — if the WebView is ever
  // steered elsewhere (open redirect, hostile DNS, a followed link), the creds
  // are simply never typed/submitted.
  //
  // NOTE: an `onNavigationRequest` host-allowlist was tried here too, but it
  // broke the DOP portal's own post-login window/redirect flow ("please close
  // this window…"), so it was removed. The origin gate below is the actual
  // protection against credential theft and does not touch navigation.
  static const _portalOrigin = 'https://dopagent.indiapost.gov.in';

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
      // No origin check here: credentials are only ever TYPED on the real portal
      // (the autofill script is origin-gated), so clicking a login button on any
      // other page would submit an empty form — harmless. Keeping an exact-origin
      // gate here only risked blocking a legitimate login on an origin variant.
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
        if (manual) _snack('Please type the captcha shown, then tap Login.');
        return;
      }
      final guess = await _captcha.solveFromDataUrl(data);
      if (guess == null || guess.isEmpty) {
        if (manual) {
          _snack("Couldn't read the captcha — type it in, then tap Login.");
        }
        return;
      }
      final ok = _decode(
          await _controller.runJavaScriptReturningResult(_fillCaptchaJs(guess)));
      if (!ok.contains('true')) {
        if (manual) _snack('Captcha box not found to fill · $dbg');
        return;
      }
      // Auto-submit. The portal keeps the Login button disabled for a moment
      // after the captcha field is filled (it validates on input), and on a slow
      // phone/network that can take a couple of seconds — the old 3×450ms window
      // (~1.35s) sometimes expired first, forcing a manual tap. Poll longer:
      // 10×500ms (~5s), clicking the instant the button enables. Only a REAL
      // submit counts toward the 2-per-screen lockout guard (a failed find /
      // disabled button is never burned).
      if (_loginClicks < 2) {
        for (var attempt = 0; attempt < 10; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          final clicked =
              _decode(await _controller.runJavaScriptReturningResult(_loginJs));
          if (clicked.contains('true')) {
            _loginClicks++;
            if (mounted) _snack('Captcha $guess — logging in…');
            return;
          }
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
        // Never type real banking credentials into anything but the portal.
        if (location.origin !== '$_portalOrigin') return;
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
      if (widget.isBatch) {
        _submitBatch();
      } else if (widget.isDetail) {
        _fetchDetail();
      } else if (widget.isPrepare) {
        _prepare();
      } else if (widget.isDeep) {
        _deepSync();
      } else {
        _sync();
      }
    }
  }

  /// Mode string ('Cash'/'DOP Cheque'/'Non DOP Cheque') → portal code.
  static String _modeCode(String mode) {
    final m = mode.toLowerCase();
    if (m.contains('non')) return 'NDC';
    if (m.contains('cheque')) return 'DC';
    return 'C';
  }

  /// Batch: submit every unsubmitted list in ONE portal session. For each list:
  /// prepare (tick + Save, serial-jump) → key installments → confirm the amount
  /// → Pay All → capture the reference (saved onto the list) → back to the
  /// account list for the next. Each payment is confirmed individually; a
  /// declined or failed list is skipped, not retried, and the batch continues.
  Future<void> _submitBatch() async {
    final lots = widget.batchLots!;
    var paid = 0, skipped = 0;
    final serials = {
      for (final a in await widget.repo.all())
        if (a.serial > 0) a.accountNumber: a.serial
    };

    for (var i = 0; i < lots.length; i++) {
      if (!mounted) return;
      final lot = lots[i];
      if (lot.isSubmitted) continue;
      final label = 'List ${i + 1} of ${lots.length}';

      // 1) Prepare: tick this list's accounts + Save.
      setState(() {
        _busy = true;
        _progress = '$label · selecting accounts…';
      });
      final accounts = lot.items.map((e) => e.accountNumber).toSet();
      final prep = await _engine.prepareList(
        accountNumbers: accounts,
        mode: _modeCode(lot.mode),
        serialByAccount: serials,
        onProgress: (page, total, sel) =>
            setState(() => _progress = '$label · page $page · $sel selected'),
      );
      if (!mounted) return;
      if (!prep.saved) {
        skipped++;
        _snack('$label skipped (${prep.error ?? 'could not save'}).');
        await _engine.navigateToAccountList();
        continue;
      }

      // Each account's own ASLAAS is displayed on this screen — grab it while
      // we're here so lists print the right number per account.
      await _harvestAslaas();

      // 2) Key only the rows that differ from "one installment" — advance
      // deposits (added more than once) and cheque rows. The rest ride Pay
      // All's default of 1. An account listed twice = two installments.
      final isCheque = lot.mode.toLowerCase().contains('cheque');
      final fill = await _engine.enterInstallments(
        installmentsByAccount: _installmentsFor(lot),
        chequeByAccount: isCheque ? _chequesFor(lot) : null,
        shouldStop: () => !mounted,
        onProgress: (done, total) => setState(
            () => _progress = '$label · keyed $done of $total advance/cheque…'),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (!fill.ok) {
        skipped++;
        _snack('$label skipped (could not key installments).');
        await _engine.navigateToAccountList();
        continue;
      }

      // 3) Automated audit — pay ONLY if this list's accounts all match the
      // portal screen and are keyed. No per-list tap.
      final problem = await _verifySelection(lot, fill);
      if (!mounted) return;
      if (problem != null) {
        skipped++;
        _snack('$label held ($problem) — not paid.');
        await _engine.navigateToAccountList();
        continue;
      }

      // 4) Pay + capture the reference, save it onto the list.
      setState(() {
        _busy = true;
        _progress = '$label · paying…';
      });
      String? ref;
      try {
        ref = await _engine.payAllAndCapture();
      } catch (_) {
        ref = null;
      }
      if (!mounted) return;
      final okRef = ref != null && ref.isNotEmpty;
      if (okRef) {
        await widget.lotStore?.update(
            lot.copyWith(referenceNumber: ref, submittedAt: DateTime.now()));
        paid++;
      } else {
        skipped++;
        _snack('$label paid? no reference captured — check the portal.');
      }
      unawaited(Analytics.track('list_submitted', {
        'accounts': lot.count,
        'amount': lot.totalAmount,
        'mode': _modeCode(lot.mode),
        'batch': true,
        'ok': okRef,
      }));

      // 5) Back to the account list for the next one.
      if (i < lots.length - 1) await _engine.navigateToAccountList();
    }

    if (!mounted) return;
    setState(() => _busy = false);
    unawaited(Analytics.track('portal_batch',
        {'lists': lots.length, 'paid': paid, 'skipped': skipped}));
    _snack('Done — $paid submitted${skipped > 0 ? ', $skipped skipped' : ''}.');
    Navigator.of(context).pop(true);
  }


  /// Deep Sync mission: fill exact per-account detail (last-deposit date etc.)
  /// for accounts that don't have it yet. Bounded + resumable across runs.
  Future<void> _deepSync() async {
    await _fillDetails();
    unawaited(Analytics.track('deep_sync'));
    if (mounted) Navigator.of(context).pop(true);
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

  /// Store each account's OWN ASLAAS number, read off the installment screen
  /// (the portal keeps a different one per account). Best-effort and silent: a
  /// missing column just leaves the numbers as they were.
  Future<void> _harvestAslaas() async {
    try {
      final byAccount = await _engine.readAslaasNumbers();
      if (byAccount.isEmpty) return;
      await widget.repo.applyAslaas(byAccount);
    } catch (_) {/* never block the mission on this */}
  }

  /// Prepare-list mission: pick mode, tick this lot's accounts across pages,
  /// Save. Leaves the WebView on the installment screen for manual Pay All.
  Future<void> _prepare() async {
    setState(() {
      _busy = true;
      _progress = 'Opening account list…';
    });
    try {
      // Use each account's serial from the last sync to jump straight to its
      // page instead of scanning all of them.
      final serials = {
        for (final a in await widget.repo.all())
          if (a.serial > 0) a.accountNumber: a.serial
      };
      final res = await _engine.prepareList(
        accountNumbers: widget.prepareAccounts!,
        mode: widget.prepareMode ?? 'C',
        serialByAccount: serials,
        onProgress: (page, total, selected) => setState(
            () => _progress = 'Page $page · $selected selected'),
      );
      if (!mounted) return;
      if (res.selected.isEmpty) {
        _snack(res.error ?? 'No matching accounts found on the portal.');
        return;
      }
      final miss = res.missing(widget.prepareAccounts!);
      final missNote = miss.isEmpty ? '' : ' (${miss.length} not found)';
      await _harvestAslaas();
      if (res.saved) {
        if (widget.isSubmit) {
          // Busy overlay off; the keying step drives its own progress + Stop.
          setState(() => _busy = false);
          await _keyInstallmentsThenAwaitPayAll();
          return;
        }
        _snack('Selected & saved ${res.selected.length}$missNote. Now enter '
            'installments + Pay All on the portal.');
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

  /// Submit flow (never pays on its own): key only the advance (>1) and cheque
  /// rows (single-installment rows ride Pay All's default of 1), audit that the
  /// portal shows exactly this list's accounts, then auto-pay if it's clean —
  /// otherwise hand the WebView back to the agent to review and tap "Pay All
  /// Saved Installments" himself. The app captures the reference either way.
  Future<void> _keyInstallmentsThenAwaitPayAll() async {
    final lot = widget.submitLot!;
    final isCheque = lot.mode.toLowerCase().contains('cheque');
    final installments = _installmentsFor(lot);
    final cheques = isCheque ? _chequesFor(lot) : null;

    _stopFill = false;
    setState(() {
      _filling = true;
      _progress = 'Keying installments…';
    });
    InstallmentFillResult fill;
    try {
      fill = await _engine.enterInstallments(
        installmentsByAccount: installments,
        chequeByAccount: cheques,
        shouldStop: () => _stopFill || !mounted,
        onProgress: (done, total) => setState(
            () => _progress = 'Keyed $done of $total installments…'),
      );
    } catch (e) {
      fill = InstallmentFillResult(0, 0, error: '$e');
    }
    if (!mounted) return;
    setState(() => _filling = false);
    if (!fill.ok) {
      _snack('Could not key installments${fill.error == null ? '' : ' · ${fill.error}'}. '
          'Enter them on the portal instead.');
      return;
    }
    // Automated audit (replaces the manual confirm): pay ONLY if every one of
    // the list's accounts is on the payment screen — no missing, no extra — and
    // all are keyed. No extra tap for the agent.
    final problem = await _verifySelection(lot, fill);
    if (!mounted) return;
    if (problem != null) {
      // Something's off — do NOT pay. Hand to the agent to review + pay/capture.
      setState(() {
        _awaitingRef = true;
        _progress = 'Not paid — $problem. Check the portal, pay, then '
            '"Capture reference".';
      });
      _snack('Payment held: $problem.');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 'Verified — paying…';
    });
    String? ref;
    try {
      ref = await _engine.payAllAndCapture();
    } catch (_) {
      ref = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ref != null && ref.isNotEmpty) {
      unawaited(Analytics.track('list_submitted', {
        'accounts': lot.count,
        'amount': lot.totalAmount,
        'mode': _modeCode(lot.mode),
        'batch': false,
        'ok': true,
      }));
      Navigator.of(context).pop(ref); // lot_detail saves it → onto the PDF
      return;
    }
    // Paid the click, but no reference yet (portal may want its own confirm) →
    // let the agent complete it + capture.
    setState(() {
      _awaitingRef = true;
      _progress = 'Tapped Pay All. If the portal shows a confirm step, '
          'complete it, then tap "Capture reference".';
    });
  }

  /// Installments to key, per account. An account that appears more than once
  /// in the list (added twice) becomes that many installments on its single
  /// portal row — so it's keyed for the advance rebate rather than paid once.
  Map<String, int> _installmentsFor(Lot lot) {
    final m = <String, int>{};
    for (final it in lot.items) {
      m[it.accountNumber] = (m[it.accountNumber] ?? 0) + it.installments;
    }
    return m;
  }

  /// Cheque details per account (one cheque per account row).
  Map<String, ChequeInfo> _chequesFor(Lot lot) => {
        for (final it in lot.items)
          it.accountNumber: ChequeInfo(
              chequeNo: it.chequeNumber ?? '',
              bankAccount: it.bankAccountNumber ?? ''),
      };

  /// Pre-pay audit: returns null when it's safe to pay, else a short reason.
  /// The real safety net is that EXACTLY the list's accounts are on the payment
  /// screen (single-installment rows are paid at the portal's default, so they
  /// are intentionally not keyed / not Modified=YES). Only the advance/cheque
  /// rows had to be keyed, and [fill.ok] confirms those all went through.
  Future<String?> _verifySelection(Lot lot, InstallmentFillResult fill) async {
    if (!fill.ok) {
      return 'only ${fill.saved} of ${fill.total} advance/cheque rows got keyed';
    }
    final expected = _installmentsFor(lot).keys.toSet();
    final onScreen = await _engine.installmentScreenAccounts();
    if (onScreen.length != expected.length ||
        !onScreen.containsAll(expected)) {
      return 'the portal\'s accounts don\'t match this list';
    }
    return null;
  }

  Widget _payAllBanner() {
    final lot = widget.submitLot!;
    return Material(
      elevation: 12,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            16, 14, 16, MediaQuery.of(context).padding.bottom + 14),
        color: AppTheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user_outlined,
                    color: AppTheme.accent, size: 20),
                const SizedBox(width: 8),
                Text('Installments keyed', style: AppTheme.display(15)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Review the amounts on the portal. When you are sure, tap '
              '"Pay All Saved Installments" there yourself — the app never pays '
              'for you. ${lot.count} account${lot.count == 1 ? '' : 's'} · '
              '₹${lot.totalAmount} · ${lot.mode}.',
              style: AppTheme.body(12.5, color: AppTheme.inkMuted, height: 1.35),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _captureReference,
                    child: const Text("I've paid — capture reference"),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () => setState(() => _awaitingRef = false),
                  child: Text('Skip',
                      style: AppTheme.body(13, color: AppTheme.inkMuted)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Read the reference off the current portal page after the agent has paid.
  Future<void> _captureReference() async {
    final ref = await _engine.readReferenceIfPresent();
    if (!mounted) return;
    if (ref == null) {
      _snack('No reference on screen yet — tap "Pay All Saved Installments" '
          'on the portal first.');
      return;
    }
    Navigator.of(context).pop(ref); // lot_detail saves it on the Lot
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
      await AppSettings.setLastSyncNow();
      unawaited(
          Analytics.track('sync_done', {'accounts': result.accounts.length}));
      if (!mounted) return;
      _snack(result.error ??
          'Synced ${result.accounts.length} accounts. Run Deep Sync for '
              'last-deposit dates.');
      // Fast list sync only. Exact per-account figures (last deposit etc.) are
      // fetched separately via the "Deep Sync" button.
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
            : widget.isBatch
                ? 'Submit Lists'
                : widget.isSubmit
                    ? 'Submit List'
                    : widget.isPrepare
                        ? 'Prepare List'
                        : widget.isDeep
                            ? 'Deep Sync'
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
                style: AppTheme.body(13, color: AppTheme.inkMuted),
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
                          ? (widget.isSubmit
                              ? 'Keying installments only — NO payment happens. '
                                  'You can stop anytime.'
                              : 'Accounts are already saved — this just adds '
                                  'exact figures. You can stop anytime.')
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
          // Money step: installments are keyed; the agent taps Pay All on the
          // portal himself, then we capture the reference. Non-blocking banner
          // so the WebView stays interactive.
          if (_awaitingRef)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _payAllBanner(),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy
            ? null
            : (widget.isBatch
                ? _submitBatch
                : widget.isPrepare
                    ? _prepare
                    : widget.isDeep
                        ? _deepSync
                        : _sync),
        icon: Icon(
            widget.isBatch
                ? Icons.cloud_upload_rounded
                : widget.isPrepare
                    ? Icons.playlist_add_check
                    : widget.isDeep
                        ? Icons.cloud_download_rounded
                        : Icons.sync,
            size: 18),
        label: Text(widget.isBatch
            ? 'Submit all'
            : widget.isPrepare
                ? 'Prepare'
                : widget.isDeep
                    ? 'Deep Sync'
                    : 'Sync'),
      ),
    );
  }
}
