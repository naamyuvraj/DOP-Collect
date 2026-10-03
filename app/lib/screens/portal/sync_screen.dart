import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../services/screen_security.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/credentials.dart';
import '../../data/database.dart';
import '../../data/lot_repository.dart';
import '../../data/portal/agent_detail_parser.dart';
import '../../data/portal/captcha_solver.dart';
import '../../data/portal/portal.dart';
import '../../data/portal/portal_webview.dart';
import '../../models/lot.dart';
import '../../services/analytics.dart';
import '../../services/cloud_sync.dart';
import '../../services/supabase_config.dart';
import '../../data/portal/portal_sync.dart';
import '../../theme/app_theme.dart';

/// Narrates the login phase into the same trace sink as the page walk. Every
/// report of "it just sits there" happens BEFORE the walk starts, so the walk's
/// own tracing never sees it — this is the only view of that phase.
void _t(String m) => PortalSyncEngine.note(m);

/// One-touch Sync. The WebView identifies as desktop Chrome (the legacy portal
/// breaks under a mobile UA), auto-fills the saved Agent ID/password and a read
/// of the captcha, submits the login, then auto-navigates to the account list
/// and walks all pages into the local DB.
///
/// There is NO daily allowance on that login. There used to be — a per-calendar
/// -day counter that ordinary work spent, so a screen opened in the afternoon
/// would refuse to log in over something that happened in the morning. The key,
/// the counters and the "daily auto-login limit reached" message are gone. The
/// only remaining stop is [_SyncScreenState._loginClicks]: four REJECTED
/// submits on one screen, which exists solely because Finacle locks the account
/// at ten failures, and it resets the moment a login is accepted.
class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.repo,
    this.prepareAccounts,
    this.prepareMode,
    this.detailAccount,
    this.detailSerial,
    this.deepSync = false,
    this.aslaasSync = false,
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

  /// ASLAAS sync: after login, read the portal's "ASLAAS Number Report" and
  /// save each account's ASLAAS number locally (so it's never typed by hand).
  final bool aslaasSync;

  bool get isPrepare => prepareAccounts != null;
  bool get isDetail => detailAccount != null;
  bool get isDeep => deepSync;
  bool get isAslaas => aslaasSync;

  // Desktop Chrome UA — makes the Finacle portal SERVE its full desktop pages.
  // Making the WebView LAY THEM OUT at desktop width is a separate setting and
  // lives in PortalWebView.applyDesktopViewport; the two are only useful
  // together.
  static const _desktopUa = PortalWebView.desktopUa;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final WebViewController _controller;
  late final PortalSyncEngine _engine;
  final CaptchaSolver _captcha = CaptchaSolver();
  Credentials _creds = const Credentials();

  /// Resolves once the saved login has actually been read out of the Keystore.
  ///
  /// `Credentials.load()` is four async hops (prefs, a plaintext migration, then
  /// two Keystore reads) and used to be fired with `.then()` while the login page
  /// was already loading. `_autofillIfLogin` bails on `!_creds.hasAny`, so when
  /// the page won that race — a warm WebView cache is easily faster than the
  /// Keystore — the Agent ID and password were never typed, and nothing retried
  /// until the next page load. That is the "ID doesn't fill" everyone sees.
  late final Future<void> _credsReady;
  bool _busy = false;
  bool _filling = false;
  bool _stopFill = false;
  bool _autoStarted = false;
  bool _solvingCaptcha = false;

  /// A login we submitted is with the portal and has not been judged yet.
  bool _loginInFlight = false;

  /// True from the moment Log in is clicked until the portal has answered.
  ///
  /// The captcha solver runs on EVERY page-finish, and the portal's reply to a
  /// login POST is itself a page-finish — so the solver would wake up, read the
  /// fresh captcha on that reply, and click Log in again on top of a login
  /// still in flight. Two submits, the second carrying a different captcha.
  /// That is the whole of "it fills the right captcha but the login fails":
  /// the app was racing itself, and each lap spent one of the four daily
  /// attempts that stand between the agent and Finacle's account lockout.
  bool _awaitingRef = false; // installments keyed; waiting for agent's Pay All

  /// The portal's own words for why the last login was refused, kept on screen
  /// until the next attempt rather than flashed past in a snackbar.
  String? _loginProblem;
  String? _progress;
  Timer? _keepAliveTimer;

  @override
  void initState() {
    super.initState();
    // The agent types his real DOP banking password into this WebView. Block
    // capture for as long as this screen is up, even if he has turned
    // screenshots on for himself — that setting is about his own convenience,
    // not a licence for a screen recorder to catch a live banking login.
    unawaited(ScreenSecurity.forceOn());
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(SyncScreen._desktopUa)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          _t('page finished: $url');
          _engine.notifyPageFinished();
          unawaited(
              _controller.runJavaScript(PortalWebView.wideViewportMetaJs));
          unawaited(_resolveAutoLoginOutcome());
          _captchaTries = 0;
          unawaited(_armCaptchaSolve());
          unawaited(_noteHumanCheck());
          _maybeAutoStart();
        },
      ));
    // Desktop layout, zoomed out to fit — before the first load, so the login
    // page never gets laid out at phone width even once. Fire-and-forget: the
    // WebView applies these settings to whatever it renders next, and blocking
    // the constructor on a platform channel would only delay the load.
    unawaited(PortalWebView.applyDesktopViewport(_controller));
    unawaited(_controller.loadRequest(Uri.parse(Portal.agentLoginUrl)));
    _engine = PortalSyncEngine(_controller);
    _credsReady = _loadCredentials();
    // The portal gives an authenticated session five minutes of idle
    // (`#sessionTimeout` = 300 on every capture), so a two-minute nudge is the
    // right cadence for a screen the agent is just looking at.
    //
    // It must NEVER fire during a sync. The keep-alive control is a form
    // submit, so clicking it navigates — and a navigation posted on top of the
    // page walk's own post is what made Finacle answer "You clicked on a link
    // or a button when your previous click was still being processed", treat
    // the out-of-sequence token as a replay, and end the session. That is the
    // "sync reaches the account list, then says Session expired" report: the
    // keep-alive was killing the thing it existed to protect. A walk needs no
    // help anyway — every page it turns is itself a post, and a post is what
    // resets the idle timer.
    //
    // Guarded twice on purpose: `_busy` covers everything this screen starts,
    // and `PortalSyncEngine.isDriving` covers the engine's own operations
    // whichever screen started them.
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (!mounted || _busy || _engine.isDriving) return;
      unawaited(_engine.keepSessionAlive());
    });
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _captcha.dispose();
    // Back to whatever the agent chose, however we left this screen.
    unawaited(ScreenSecurity.applySaved());
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
      // One fixed threshold used to decide the whole thing. Captcha glyph/
      // background contrast varies per image, so a single cut either ate thin
      // strokes or kept the noise, and a miss meant the agent typed it himself.
      // Render several and let the OCR pick the one that reads like a code.
      var THRESHOLDS=[0.68,0.82,0.95];
      function toData(img,tf){
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
          var th=(sum/n)*tf;
          for(var j=0;j<d.length;j+=4){
            var v=d[j]<th?0:255; d[j]=d[j+1]=d[j+2]=v; d[j+3]=255;
          }
          ctx.putImageData(id,0,0);
          return c.toDataURL('image/png');
        }catch(e){ return 'TAINT'; }
      }
      function allVariants(img){
        var out=[];
        for(var t=0;t<THRESHOLDS.length;t++){
          var d=toData(img,THRESHOLDS[t]);
          if(d==='TAINT') return 'TAINT';
          if(d && d.indexOf('data:')===0) out.push(d);
        }
        return out;
      }
      // The verification box is the anchor for everything below: a captcha
      // image is the picture NEXT TO the field you type it into, and on this
      // portal both live in the same little table.
      var field=document.querySelector(
        '[name="AuthenticationFG.VERIFICATION_CODE"]')
        || document.querySelector('[name*="VERIFICATION_CODE" i]');
      // Four levels is the whole login table on the live capture without
      // reaching the page banner.
      var near=null;
      if(field){
        near=field;
        for(var u=0; u<4 && near && near.parentElement; u++) near=near.parentElement;
      }
      var imgs=Array.prototype.slice.call(document.querySelectorAll('img'));
      var scored=imgs.map(function(img){
        var w=img.naturalWidth||img.width||0, h=img.naturalHeight||img.height||0;
        // Two strings on purpose. `ident` is machine-chosen (src/id/class/name)
        // and safe to match words against; `meta` adds alt text, which is human
        // prose. The live captcha's alt is "Please Click On The Icon Next For
        // Audio" — matching "icon" in THAT would penalise the one image we are
        // looking for, which is exactly the kind of near-miss that ends with an
        // agent typing captchas by hand again.
        var ident=((img.getAttribute('src')||'')+' '+(img.id||'')+' '+
                   (img.className||'')+' '+(img.name||''));
        var meta=ident+' '+(img.alt||'');
        var s=0;
        if(/captcha|verif|random|securimage|seccode|imgtext|numimg/i.test(meta)) s+=5;
        // Sitting inside the verification field's own block is as strong a
        // hint as the name, and survives a deployment that renames the image.
        if(near && near.contains(img)) s+=4;
        // Decorative furniture that happens to be captcha-shaped. The portal's
        // own reset.jpg is one of these, and it sits right beside the captcha —
        // so proximity alone must not be enough to promote it.
        if(/logo|banner|spacer|header|footer|emblem|reset|refresh|arrow|bullet|icon|btn|button|g20|swachh|azadi/i
           .test(ident)) s-=6;
        if(w>=55&&w<=340&&h>=16&&h<=120) s+=3;   // captcha-sized
        if(h>0 && w>h*1.5) s+=1;                 // wide
        return {img:img,w:w,h:h,s:s,done:img.complete};
      }).sort(function(a,b){return b.s-a.s;});
      var loading=false, variants=[], taint=false, chosen=null;
      for(var i=0;i<scored.length;i++){
        // 5, not 3. Size alone tops out at 4 (3 captcha-sized + 1 wide), so a
        // 120x22 header or spacer gif can no longer qualify on its shape — an
        // image now needs a name that says captcha, or a position beside the
        // box you type it into. Each accepted image costs three canvas
        // upscales and three ML Kit OCR passes, on exactly the low-end phones
        // where pages already stall.
        if(scored[i].s<5) break;
        if(!scored[i].done){ loading=true; continue; }
        var v=allVariants(scored[i].img);
        if(v==='TAINT'){ taint=true; continue; }
        if(v && v.length){ variants=v; chosen=scored[i]; break; }
      }
      var top=scored[0];
      var dbg=imgs.length+' imgs; top '+(top?top.w+'x'+top.h+' s'+top.s:'none')+
              (chosen?'; used '+chosen.w+'x'+chosen.h+' x'+variants.length:'')+
              (taint?'; TAINT':'')+(loading&&!variants.length?'; loading':'');
      return JSON.stringify({variants:variants,
                             loading:(variants.length===0&&loading), dbg:dbg});
    })();
  ''';


  /// Decide whether the login we just submitted was accepted, and say why not.
  ///
  /// Tied to one attempt on purpose: it waits for the portal to answer, then
  /// reads the page ONCE. A verdict attached to the wrong page is worse than no
  /// verdict.
  ///
  /// It counts NOTHING against the day. There is no daily budget any more: the
  /// app does not ration the agent's logins by the calendar, so a screen can
  /// never refuse to log in because of something that happened at breakfast.
  Future<void> _judgeLoginAttempt(String guess) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var onLogin = true;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      try {
        onLogin = _decode(
                await _controller.runJavaScriptReturningResult(_onLoginPageJs))
            .contains('true');
      } catch (_) {
        continue; // mid-navigation; the context will come back
      }
      if (!onLogin) break;
    }
    _loginInFlight = false;
    if (!mounted) return;
    if (!onLogin) {
      _loginClicks = 0;
      _t('auto-login: accepted ("$guess")');
      if (mounted && _loginProblem != null) {
        setState(() => _loginProblem = null);
      }
      return;
    }
    final why =
        _decode(await _controller.runJavaScriptReturningResult(_loginErrorJs));
    _t('auto-login: REJECTED ("$guess") -> $why');
    unawaited(_autoCapture('login_rejected'));
    // SHOW it. The portal states its reason on the page — wrong captcha, wrong
    // password, account locked, session gone — and the app was reading that
    // reason and then discarding it, leaving the agent staring at a login form
    // that had already explained itself.
    if (mounted) {
      setState(() => _loginProblem = why == '(no message on page)'
          ? 'The portal rejected the login but gave no reason.'
          : why);
      _snack(why == '(no message on page)'
          ? 'Login rejected — no reason given. Tap the bug icon to send '
              'diagnostics.'
          : 'Portal says: $why');
    }

    if (_loginClicks < 4 && !_awaitingHuman) {
      _t('auto-login: scheduling auto-retry after rejection (attempt $_loginClicks/4)');
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (mounted && !_busy && !_loginInFlight && !_autoStarted) {
          _armCaptchaSolve();
        }
      });
    }
  }

  /// Whatever the login page is saying after a rejected submit — Finacle puts
  /// its reason in a message block, and we were throwing it away.
  static const _loginErrorJs = r'''
    (function(){
      function t(e){return e?(e.innerText||e.textContent||'')
        .replace(/\s+/g,' ').trim():'';}
      var out=[];
      var sels='[role=alert], #MessageDisplay_TABLE, .orangebg, .redbg,'
        +' .errorbg, span[class*="error" i], div[class*="error" i],'
        +' font[color="red"], .validationError';
      var els=document.querySelectorAll(sels);
      for(var i=0;i<els.length;i++){
        var s=t(els[i]);
        if(s && s.length>2 && out.indexOf(s)===-1) out.push(s);
      }
      return out.length ? out.slice(0,3).join(' | ') : '(no message on page)';
    })();
  ''';



  /// Type the code into the verification box the way a person would.
  ///
  /// This used to assign `.value` and fire four events, none of them a key
  /// event, and never focus the field. Finacle pages of this vintage enable the
  /// Log in button from a key handler on a focused field, so against such a
  /// page the button stayed disabled through all ten polls and the flow fell
  /// through to "tap Login" holding a perfectly good code — the "it filled it
  /// and then just sat there" report.
  ///
  /// The selector is anchored on the portal's real field name first
  /// (`AuthenticationFG.VERIFICATION_CODE`, from the live capture) so a loose
  /// `[id*="captcha"]` match cannot write a junk read into some unrelated box.
  String _fillCaptchaJs(String code) => '''
    (function(){
      var f=document.querySelector('[name="AuthenticationFG.VERIFICATION_CODE"]')
         || document.querySelector('[name*="VERIFICATION_CODE" i]')
         || (function(){
              // The loose fallback, made safe. `[id*="captcha" i]` matches
              // `#g-recaptcha-response` — so on a page carrying BOTH the
              // picture captcha and a Google challenge, an OCR read could be
              // written straight into the reCAPTCHA token field. That was
              // harmless when this portal had no reCAPTCHA. It does now.
              var c=document.querySelectorAll(
                'input[name*="CAPTCHA" i], input[id*="captcha" i]');
              for(var i=0;i<c.length;i++){
                var m=(c[i].id||'')+' '+(c[i].name||'');
                if(/g-recaptcha|h-captcha|captcha-response/i.test(m)) continue;
                var t=(c[i].type||'text').toLowerCase();
                if(t!=='text' && t!=='tel' && t!=='number') continue;
                return c[i];
              }
              return null;
            })();
      if(!f) return 'false';
      try { f.focus(); } catch(e) {}
      f.value=${jsonEncode(code)};
      var last=${jsonEncode(code)}.slice(-1);
      function key(t){
        var e;
        try { e=new KeyboardEvent(t,{bubbles:true,cancelable:true,key:last}); }
        catch(err){ e=document.createEvent('Event'); e.initEvent(t,true,true); }
        f.dispatchEvent(e);
      }
      key('keydown'); key('keypress');
      ['input','change'].forEach(function(t){
        f.dispatchEvent(new Event(t,{bubbles:true}));});
      key('keyup');
      f.dispatchEvent(new Event('blur',{bubbles:true}));
      return 'true';
    })();
  ''';

  int _captchaTries = 0;

  /// Set when a page load asks for a captcha solve while one is already running.
  bool _captchaAgain = false;

  /// Rejected auto-submits on THIS screen. Reset to 0 the moment a login is
  /// accepted, and never written to disk.
  ///
  /// This is not a budget. The old daily counter was: it persisted per calendar
  /// day, was spent by ordinary work, and left the agent at a screen that
  /// refused to log in over something hours old. That is gone — the key, the
  /// counters and the "daily auto-login limit reached" message with it.
  ///
  /// What is left is a stop on a runaway loop inside one screen: a rejected
  /// login re-solves the captcha and submits again, and Finacle locks the
  /// account after ten failures. Four rejections on one screen means something
  /// is wrong that another attempt will not fix, so the app hands over and the
  /// agent taps Log in himself. Every new screen starts fresh.
  int _loginClicks = 0;

  /// An auto-login was submitted and we have not seen the result yet.
  bool _autoLoginPending = false;

  /// Is the login form still on screen? After a submit, still being here means
  /// the attempt was rejected.
  static const _onLoginPageJs = r'''
    (function(){
      var id=document.querySelector('[name="AuthenticationFG.USER_PRINCIPAL"]');
      var pw=document.querySelector('[name="AuthenticationFG.ACCESS_CODE"]');
      return (id||pw) ? 'true' : 'false';
    })();
  ''';

  static const _credsFilledJs = r'''
    (function(){
      var id=document.querySelector('[name="AuthenticationFG.USER_PRINCIPAL"]');
      var pw=document.querySelector('[name="AuthenticationFG.ACCESS_CODE"]');
      if(!id||!pw) return 'false';
      return (id.value && pw.value) ? 'true' : 'false';
    })();
  ''';

  /// Charge nothing, but notice the outcome of a login we submitted.
  ///
  /// Runs off every page-finish. It used to increment a per-day failure counter
  /// here; that counter is gone, so all this does now is release the in-flight
  /// flag and put the portal's own words on screen.
  Future<void> _resolveAutoLoginOutcome() async {
    if (!_autoLoginPending) return;
    _autoLoginPending = false;
    try {
      var stillHere = _decode(
          await _controller.runJavaScriptReturningResult(_onLoginPageJs));
      if (stillHere.contains('true')) {
        // Do not judge off the FIRST page-finish. That event fires at document
        // load, so a login that is succeeding can still be showing the login
        // page at this instant. Give the navigation a moment and ask again.
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!mounted) return;
        stillHere = _decode(
            await _controller.runJavaScriptReturningResult(_onLoginPageJs));
      }
      if (stillHere.contains('true')) {
        final why = _decode(
            await _controller.runJavaScriptReturningResult(_loginErrorJs));
        _t('auto-login: REJECTED by the portal -> $why');
        unawaited(_autoCapture('login_rejected'));
      } else {
        _loginClicks = 0;
        _t('auto-login: accepted');
      }
    } catch (_) {
      // Could not read the page. Nothing is charged either way now.
    }
  }

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

  /// The one place that clicks Log in and books the result. Everything that
  /// wants to submit goes through here.
  Future<bool> _clickLoginAndJudge(String guess) async {
    final clicked =
        _decode(await _controller.runJavaScriptReturningResult(_loginJs));
    if (!clicked.contains('true')) return false;
    _loginClicks++;
    _autoLoginPending = false;
    _loginInFlight = true;
    if (mounted) setState(() => _loginProblem = null);
    if (mounted) _snack('Captcha $guess — logging in…');
    unawaited(_judgeLoginAttempt(guess));
    return true;
  }

  /// A cheap fingerprint of the captcha image currently on the page.
  ///
  /// The login page refreshes its captcha from an image `onload` handler
  /// (`<img id="TEXTIMAGE" onload="captchaRefresh()">`). If that fires after we
  /// have read the picture, the code we are holding answers an image the server
  /// has already thrown away — so the submission is rejected with a captcha
  /// that looks perfectly correct on screen. That is the "right captcha, still
  /// fails" report.
  static const _captchaSigJs = r'''
    (function(){
      var img=document.querySelector('#TEXTIMAGE')
        || document.querySelector('img[src*="captcha" i]')
        || document.querySelector('img[id*="IMAGE" i]');
      if(!img || !img.complete || !img.naturalWidth) return '';
      try{
        var c=document.createElement('canvas');
        c.width=32; c.height=16;
        var x=c.getContext('2d');
        x.drawImage(img,0,0,32,16);
        var d=x.getImageData(0,0,32,16).data;
        var h=0;
        for(var i=0;i<d.length;i+=4){ h=((h<<5)-h+d[i])|0; }
        return String(h);
      }catch(e){ return ''; }
    })();
  ''';

  Future<String> _captchaSignature() async {
    try {
      return _decode(
          await _controller.runJavaScriptReturningResult(_captchaSigJs));
    } catch (_) {
      return '';
    }
  }

  /// Wait for the agent to pass the reCAPTCHA, then finish the login for him.
  ///
  /// Not a bypass and cannot become one: it only ever *observes* the token the
  /// widget writes once a person has passed it. Until then it does nothing.
  ///
  /// Capped at 3 minutes: if he has walked away, the poll stops rather than
  /// waking up to submit a login into a session that has since expired.
  Future<void> _submitAfterHumanCheck(String guess) async {
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || _busy || _loginInFlight) return;
      // He may have submitted it himself while we were waiting.
      final onLogin = _decode(
          await _controller.runJavaScriptReturningResult(_onLoginPageJs));
      if (!onLogin.contains('true')) {
        _t('human check: the page moved on — the login went through');
        if (mounted) setState(() => _awaitingHuman = false);
        return;
      }
      final hc = await _humanCheck();
      if (!hc.present) {
        _t('human check: the reCAPTCHA is gone');
        if (mounted) setState(() => _awaitingHuman = false);
        return;
      }
      if (!hc.solved) continue;
      _t('human check: passed by the agent — submitting the filled form');
      if (mounted) setState(() => _awaitingHuman = false);
      await _clickLoginAndJudge(guess);
      return;
    }
    _t('human check: gave up waiting after 3 minutes');
    if (mounted) setState(() => _awaitingHuman = false);
  }


  // --- The human check (reCAPTCHA) -----------------------------------------
  //
  // The portal raises a Google reCAPTCHA after it has rejected a login. It is
  // NOT the picture captcha and it is not something this app reads, guesses or
  // works around — a reCAPTCHA exists to establish that a person is present,
  // and the honest answer is to put it in front of the person. Everything here
  // is about (a) noticing it, (b) stopping the app from submitting logins that
  // cannot succeed while it stands, and (c) getting it on screen where it can
  // be tapped.
  //
  // Why it looked like "the reCAPTCHA doesn't fill": nothing in this screen
  // knew the widget existed. `_autofillCaptcha` kept OCR'ing the old picture
  // captcha, filling it, finding the Log in button enabled and clicking it —
  // once per page-finish, against a form the portal was never going to accept.
  // Each of those spent one of the ten attempts standing between the agent and
  // a Finacle account lockout, and each rejection is exactly what makes the
  // portal keep the reCAPTCHA up. The app was feeding the thing that blocked
  // it.
  //
  // Reports {present, solved, top, height}. `solved` reads the response token
  // the widget writes when a person passes it — the only reliable signal, and
  // one this app can only ever read, never produce.
  static const _humanCheckJs = r"""
    (function(){
      var host = document.querySelector(
        '.g-recaptcha, #g-recaptcha, .h-captcha, [data-sitekey]');
      var frame = document.querySelector(
        'iframe[src*="recaptcha" i], iframe[src*="hcaptcha" i]');
      var el = host || frame;
      if(!el) return JSON.stringify({present:false});
      var tok = document.querySelector(
        '#g-recaptcha-response, textarea[name="g-recaptcha-response"],'
        +' textarea[name="h-captcha-response"]');
      var r = el.getBoundingClientRect();
      return JSON.stringify({
        present: true,
        solved: !!(tok && String(tok.value||'').length > 0),
        top: Math.round(r.top + (window.pageYOffset||0)),
        height: Math.round(r.height)
      });
    })();
  """;

  /// Bring the widget into view and zoom to it, because on a page laid out at
  /// 980 px and scaled to fit, a 300x78 reCAPTCHA is roughly a thumbnail — it
  /// is visible, but not comfortably tappable.
  static const _showHumanCheckJs = r"""
    (function(){
      var el = document.querySelector(
        '.g-recaptcha, #g-recaptcha, .h-captcha, [data-sitekey]')
        || document.querySelector('iframe[src*="recaptcha" i]');
      if(!el) return 'false';
      try { el.scrollIntoView({block:'center'}); }
      catch(e) { el.scrollIntoView(); }
      return 'true';
    })();
  """;

  ({bool present, bool solved}) _readHumanCheck(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (present: m['present'] == true, solved: m['solved'] == true);
    } catch (_) {
      // A page we could not read is not a page we should auto-submit into.
      return (present: false, solved: false);
    }
  }

  Future<({bool present, bool solved})> _humanCheck() async {
    try {
      return _readHumanCheck(_decode(
          await _controller.runJavaScriptReturningResult(_humanCheckJs)));
    } catch (_) {
      return (present: false, solved: false);
    }
  }

  /// Say so on screen the moment a reCAPTCHA appears, whether or not there is
  /// a picture captcha to solve alongside it.
  ///
  /// `_autofillCaptcha` only runs when the page has the portal's verification
  /// box, so on a challenge page that carries the reCAPTCHA *instead of* the
  /// picture, nothing would have noticed it at all and the screen would have
  /// sat there saying "type the captcha" with no captcha to type.
  Future<void> _noteHumanCheck() async {
    // Login phase only. During a 47-page walk we are already authenticated, so
    // there is no challenge to find and this would just be one more JS
    // round-trip per page on exactly the handsets where pages already stall.
    if (_busy || _engine.isDriving) return;
    final hc = await _humanCheck();
    final waiting = hc.present && !hc.solved;
    if (waiting) {
      _t('human check: the portal is showing a reCAPTCHA');
      await _controller.runJavaScript(_showHumanCheckJs);
    }
    if (!mounted || waiting == _awaitingHuman) return;
    setState(() => _awaitingHuman = waiting);
  }

  /// True while an unsolved reCAPTCHA is on the login page — drives the status
  /// line, so "why is nothing happening" has an answer on screen.
  bool _awaitingHuman = false;

  /// Does this read look like a captcha code rather than OCR noise?
  ///
  /// DOP codes are a single short alphanumeric token. Without this, a stray
  /// read of "5" or a 14-character smear was filled and auto-submitted, spending
  /// one of the ten attempts the portal allows before it locks the agent out.
  static bool _looksLikeCaptcha(String s) =>
      RegExp(r'^[A-Za-z0-9]{4,8}$').hasMatch(s);

  Future<void> _autofillCaptcha({bool manual = false}) async {
    // A request that arrives mid-solve used to be DROPPED. That is the common
    // case, not a rare one: the 900ms timer from the previous page fires while
    // the next page is loading, so the new page's captcha is never read and the
    // agent has to type it himself — "sometimes I have to fill it in". Queue it
    // instead and run once the in-flight solve finishes.
    if (_solvingCaptcha) {
      _captchaAgain = true;
      return;
    }
    // A login is already with the portal. Whatever page just finished is its
    // answer, not a new login form to fill in — leave it alone until the
    // attempt has been judged.
    if (_loginInFlight) {
      _t('captcha: skipped — a login is already in flight');
      return;
    }
    // ONLY on the login page. This fires on every page-finish, so during a
    // 48-page walk it ran the whole image scorer plus three ML Kit OCR passes
    // on every page — against a scorer loose enough to accept a 120x22 spacer
    // gif. That is CPU spent competing with the page walk on exactly the
    // low-end handsets where pages already stall, and it can never find a
    // captcha, because there is no captcha to find outside the login screen.
    if (!manual) {
      const probe = r"""
        (function(){
          return document.querySelector(
            'input[name="AuthenticationFG.VERIFICATION_CODE"]')
            ? 'true' : 'false';
        })();
      """;
      final onLogin =
          _decode(await _controller.runJavaScriptReturningResult(probe));
      if (!onLogin.contains('true')) return;
    }

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
      final variants = ((res['variants'] as List?) ?? const [])
          .whereType<String>()
          .where((v) => v.startsWith('data:'))
          .toList();
      final loading = res['loading'] == true;
      final dbg = (res['dbg'] as String?) ?? '';

      if (variants.isEmpty && loading && _captchaTries < 6) {
        _t('captcha: image still loading, retry ${_captchaTries + 1}/6 ($dbg)');
        _captchaTries++;
        _solvingCaptcha = false;
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) _autofillCaptcha(manual: manual);
        });
        return;
      }
      if (variants.isEmpty) {
        if (manual) _snack('Please type the captcha shown, then tap Login.');
        return;
      }

      // OCR every binarization and make them AGREE before submitting.
      //
      // This used to stop at the first read matching `^[A-Za-z0-9]{4,8}$` and
      // submit it. That is a check on the SHAPE of the answer, not on whether
      // it is right: ML Kit reading "S8HJ" for "58HU" satisfies it perfectly,
      // and the portal answers "enter the characters as you see on the
      // screen" — the exact report this fixes. Three thresholds were already
      // being rendered and then thrown away after the first usable one.
      //
      // Two of three agreeing is what makes a read worth spending one of the
      // day's four attempts on. `5`/`S`, `0`/`O`, `1`/`I` and `8`/`B` are
      // exactly the confusions that flip with the binarization threshold, so
      // disagreement between thresholds is the signal that we are guessing.
      // Agreement is compared case-insensitively — a threshold that changes
      // the case of a letter has still read the same character — and the
      // spelling actually submitted is the most common one.
      final reads = <String>[];
      for (final v in variants) {
        final g = await _captcha.solveFromDataUrl(v);
        if (g == null || g.isEmpty) continue;
        reads.add(g);
      }
      _t('captcha: ${reads.length} OCR reads -> ${reads.join(" | ")}');

      final tally = <String, List<String>>{};
      for (final r in reads.where(_looksLikeCaptcha)) {
        tally.putIfAbsent(r.toUpperCase(), () => <String>[]).add(r);
      }
      String? agreed;
      var votes = 0;
      for (final e in tally.entries) {
        if (e.value.length > votes) {
          votes = e.value.length;
          agreed = e.value.first;
        }
      }

      // Confident only when the thresholds corroborate each other. A lone read
      // is still TYPED for the agent — it is often right, and correcting one
      // character beats typing all six — but it is never submitted.
      final plausible = votes >= 2 ? agreed : null;
      final fallback = agreed ?? (reads.isEmpty ? null : reads.first);
      if (plausible == null && fallback != null) {
        _t('captcha: no agreement across thresholds (best "$fallback" with '
            '$votes vote(s)) — filling it but leaving the submit to a human');
      }
      final guess = plausible ?? fallback;
      if (guess == null || guess.isEmpty) {
        if (manual) {
          _snack("Couldn't read the captcha — type it in, then tap Login.");
        }
        return;
      }
      final ok = _decode(await _controller
          .runJavaScriptReturningResult(_fillCaptchaJs(guess)));
      if (!ok.contains('true')) {
        if (manual) _snack('Captcha box not found to fill · $dbg');
        return;
      }
      // Auto-submit. The portal keeps the Login button disabled for a moment
      // after the captcha field is filled (it validates on input), and on a slow
      // phone/network that can take a couple of seconds — the old 3×450ms window
      if (plausible == null) {
        _t('captcha: "$guess" is a single unconfirmed read — waiting for a '
            'human rather than submitting it');
        if (mounted) {
          _snack('Captcha read as "$guess" — check it against the picture, '
              'fix it if wrong, then tap Login.');
        }
        return;
      }
      _t('captcha: "$guess" agreed by $votes of ${reads.length} reads');
      final sigAtSolve = await _captchaSignature();
      _t('captcha: solved as "$guess"');

      // Gate the auto-submit on the credentials being present. An empty login
      // burns an attempt and cannot possibly succeed.
      if (!await _ensureCredsInForm()) {
        _t('auto-submit: BLOCKED — the login fields are still empty after '
            'waiting on the Keystore and re-typing. Nothing is saved, or the '
            'page renamed its fields.');
        if (mounted) {
          _snack('Captcha filled: $guess — add your Agent ID and password, '
              'then tap Login.');
        }
        return;
      }
      if (!mounted) return;

      // Is the portal asking for a person? If so, no amount of correct picture
      // captcha will get this form accepted, and submitting it anyway is what
      // kept the reCAPTCHA up: every rejection is a reason for the portal to
      // keep demanding one. Stop, show the widget, and wait for the agent.
      final human = await _humanCheck();
      if (human.present && !human.solved) {
        _t('auto-submit: HELD — the portal is asking for a reCAPTCHA. Not '
            'submitting; a rejected login is what keeps it on screen.');
        await _controller.runJavaScript(_showHumanCheckJs);
        if (mounted) {
          setState(() => _awaitingHuman = true);
          _snack('Captcha $guess filled — now tap "I\'m not a robot" on the '
              'page. The login finishes by itself.');
        }
        unawaited(_submitAfterHumanCheck(guess));
        return;
      }

      // No daily budget. The app logs in whenever it has a captcha it believes
      // and a filled form — on the first screen of the day and on the ninth.
      // The only stop is [_loginClicks]: four REJECTED submits on this screen
      // means another one will not help either, and Finacle locks the account
      // at ten failures.
      _t('auto-submit: loginClicks=$_loginClicks');
      if (_loginClicks < 4) {
        for (var attempt = 0; attempt < 10; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          // The picture must still be the one we read. If the portal swapped it
          // under us, our code answers an image the server has discarded.
          final sigNow = await _captchaSignature();
          if (sigAtSolve.isNotEmpty &&
              sigNow.isNotEmpty &&
              sigNow != sigAtSolve) {
            _t('auto-submit: ABORTED — the captcha image changed after we read '
                'it ($sigAtSolve -> $sigNow). Re-solving instead of submitting '
                'a stale code.');
            _solvingCaptcha = false;
            _captchaTries = 0;
            unawaited(
                Future<void>.delayed(const Duration(milliseconds: 400), () {
              if (mounted) _autofillCaptcha();
            }));
            return;
          }
          // Judge THIS attempt from _clickLoginAndJudge rather than from the
          // next page-finish callback, which fires for every load and ended up
          // scoring whatever page happened to be showing later.
          if (await _clickLoginAndJudge(guess)) {
            _t('auto-submit: Log in clicked on poll $attempt');
            return;
          }
        }
      }
      _t(_loginClicks >= 4
          ? 'auto-submit: NOT ATTEMPTED — four submits on this screen were '
              'already rejected. The form is filled; a human tap still works.'
          : 'auto-submit: gave up — the Log in button never enabled in 10 '
              'polls');
      if (mounted) _snack('Captcha filled: $guess — tap Login.');
    } catch (e) {
      _t('captcha: threw $e');
      if (manual) _snack('Captcha auto-fill failed: $e');
    } finally {
      _solvingCaptcha = false;
      if (_captchaAgain) {
        _captchaAgain = false;
        // Fresh page, fresh image — let it paint before reading it.
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) _autofillCaptcha();
        });
      }
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

  /// Read the saved login. Never throws, never hangs.
  ///
  /// `_credsReady` is now a dependency of the captcha solve as well as the
  /// autofill (see [_armCaptchaSolve]), so anything that could leave this
  /// future unresolved or errored would take the whole login phase down rather
  /// than degrade one half of it. `Credentials.load()` already catches, and its
  /// last throwing path was closed alongside this change — the timeout covers
  /// what catching cannot: a Keystore that answers neither way. Direct-boot and
  /// a wedged vendor provider both look like that from here.
  ///
  /// Eight seconds because the point is to bound the wait, not to guess how
  /// slow a cold Keystore is. Timing out means the agent types his own login,
  /// which is exactly what he does today when nothing is saved.
  Future<void> _loadCredentials() async {
    final started = DateTime.now();
    try {
      _creds = await Credentials.load().timeout(const Duration(seconds: 8));
      final ms = DateTime.now().difference(started).inMilliseconds;
      _t('creds: loaded in ${ms}ms (id ${_creds.agentId.isEmpty ? "empty" : "present"}, '
          'password ${_creds.password.isEmpty ? "empty" : "present"})');
    } catch (e) {
      _creds = const Credentials();
      _t('creds: load failed or timed out ($e) — the agent types them himself');
    }
  }

  /// Put the credentials in the form, THEN read the captcha.
  ///
  /// This ordering used to be a wall clock: page-finish fired `_autofillIfLogin`
  /// and, independently, a fixed 900 ms timer that started the captcha solve.
  /// `Credentials.load()` is a SharedPreferences load, a plaintext-migration
  /// pass and two Android Keystore reads; the first Keystore touch on a cold
  /// start routinely costs several hundred milliseconds and can pass a second
  /// on a mid-range handset. When the timer won, the captcha was read and
  /// filled correctly, the credential gate looked at the form, found it empty,
  /// and gave up — and gave up *for good*, because that path scheduled no
  /// retry. The credentials landed half a second later and nothing looked
  /// again. The screen sat there with a valid captcha waiting for a human tap.
  ///
  /// `_credsReady` is built once, in initState, so the only page load that can
  /// lose that race is the first — which is always the login page. Cold start
  /// loses, warm start wins. That was the whole of the "sometimes".
  ///
  /// Chaining removes the race instead of widening the window: there is no
  /// delay that is both long enough for a slow Keystore and short enough not to
  /// feel broken. A warm start is now FASTER than the old 900 ms — `_credsReady`
  /// is already resolved, so the only wait is the settle below.
  Future<void> _armCaptchaSolve() async {
    await _autofillIfLogin();
    if (!mounted) return;
    // A settle, not a race. The captcha <img> is a separate request from the
    // document and may not have painted yet — but if it has not, the extractor
    // reports `loading` and retries itself (6 x 600 ms), so being early here is
    // recoverable in a way that being early on the credentials was not.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    await _autofillCaptcha();
  }

  /// Are the Agent ID and password actually in the form? If not, put them
  /// there and ask once more before handing the screen back to the agent.
  ///
  /// The second half of C3. [_armCaptchaSolve] makes losing the race very
  /// unlikely, but it does not make it impossible — the toolbar's manual
  /// captcha button and the queued re-entry in `_autofillCaptcha`'s `finally`
  /// both reach the gate without going through the arming path. Surrendering
  /// with no retry is what turned a lost race into a dead screen, so the
  /// fallback is to re-arm, not to give up.
  ///
  /// Safe to call repeatedly: the autofill only writes a field that is empty,
  /// so it can never overwrite something the agent typed himself.
  Future<bool> _ensureCredsInForm() async {
    Future<bool> filled() async =>
        _decode(await _controller.runJavaScriptReturningResult(_credsFilledJs))
            .contains('true');

    if (await filled()) return true;
    _t('auto-submit: the login fields read back empty — waiting on the '
        'Keystore and typing them again rather than giving up (C3)');
    await _credsReady;
    if (!mounted) return false;
    await _autofillIfLogin();
    if (!mounted) return false;
    // The autofill's own events have to settle before the DOM read means
    // anything.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return false;
    return filled();
  }

  /// Fill Agent ID + password on the Agent Login page (leaves the captcha).
  /// Targets the portal's exact field names and fires input/change/keyup so the
  /// portal's own scripts (which read/encrypt the value on submit) pick it up.
  /// Runs on page-finish plus one short retry, since the page wires its virtual
  /// keypad after load.
  Future<void> _autofillIfLogin() async {
    await _credsReady; // never lose the race to a fast page load again
    if (!_creds.hasAny) {
      _t('autofill: SKIPPED — no credentials stored (id="${_creds.agentId}", '
          'password ${_creds.password.isEmpty ? "empty" : "present"})');
      return;
    }
    _t('autofill: typing agent id + password');
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

  /// Replace the TYPED agent id with the one the portal states for this
  /// session, whenever they disagree.
  ///
  /// Finacle accepts a login id that is a character off, so a typo logs in
  /// happily — and then the backend binds THAT string. The result was two
  /// accounts for one agent (`DOP.MI8472350100005` and `DOP.MI847235010005`),
  /// a phone on each, and a 1:1 rule that could not object because the two
  /// spellings are genuinely different ids.
  ///
  /// The portal knows the answer and puts it on every authenticated page, so
  /// take it from there. Runs on the page that proved we are logged in, which
  /// is the first moment the value exists.
  Future<void> _adoptPortalAgentId() async {
    try {
      final real = await _engine.portalAgentId();
      if (real.isEmpty) return;
      final typed = (await Credentials.load()).agentId.trim();
      if (typed == real) return;
      _t('agent id: portal says "$real", stored was "$typed" — adopting the '
          'portal\'s');
      await Credentials.saveAgentId(real);
      // The book is keyed on the agent id, so correcting the id has to move
      // the book with it — a RENAME, not a switch. These two ids are the same
      // agent; treating the correction as an agent change would leave him
      // looking at an empty book halfway through his own sync.
      await AppDatabase.instance.adoptAgentId(real);
    } catch (_) {
      // Best-effort. A failure here must never block a sync; the next
      // authenticated page tries again.
    }
  }

  /// Once login succeeds (we're inside the authenticated portal), kick off the
  /// sync automatically so the agent only has to type the captcha. The sync
  /// itself navigates Dashboard → Accounts → Enquire → the list. Fires once.
  /// One poll at a time. `_maybeAutoStart` runs off every page-finish, and the
  /// poll below outlives the callback that started it.
  bool _autoStartPolling = false;

  Future<void> _maybeAutoStart() async {
    if (_busy || _autoStarted || _autoStartPolling) return;
    _autoStartPolling = true;
    try {
      final authed = await _pollAuthenticated();
      if (!mounted) return;
      await _startIfAuthenticated(authed);
    } finally {
      _autoStartPolling = false;
    }
  }

  /// Is the portal logged in? Ask for a few seconds, not once. (A1)
  ///
  /// `onPageFinished` fires at document load. The dashboard menu this probe
  /// looks for — `#Accounts` / `a[name="HREF_Accounts"]` — is written by a
  /// deferred script on this portal, so a single probe at that instant reads
  /// false on a page that is about to be perfectly good. And the post-login
  /// dashboard is the LAST navigation of the session: page-finish never fires
  /// again, so nothing retried. The screen sat on a working, logged-in portal
  /// doing nothing at all, which is the "it just does nothing" report.
  ///
  /// Every other DOM read in the engine settles first; this one did not.
  ///
  /// The poll stops early on the login form, which is the common case — during
  /// the login phase this fires on every page-finish, and spending eight
  /// seconds re-asking a page that is plainly still asking for a password is
  /// eight seconds of nothing. So the full budget is only ever spent on a page
  /// that is neither the login form nor recognisably the dashboard, which is
  /// exactly the deferred-render case it exists for.
  Future<bool> _pollAuthenticated() async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    var settle = const Duration(milliseconds: 400);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(settle);
      if (!mounted || _busy || _autoStarted) return false;
      settle = const Duration(milliseconds: 700);
      try {
        if (await _engine.isAuthenticated()) return true;
        final onLogin = _decode(
            await _controller.runJavaScriptReturningResult(_onLoginPageJs));
        if (onLogin.contains('true')) {
          _t('auto-start: still the login form — not polling further');
          return false;
        }
      } catch (_) {
        // Mid-navigation; the JS context will come back. Keep asking.
      }
    }
    _t('auto-start: not authenticated after 8s of polling');
    return false;
  }

  Future<void> _startIfAuthenticated(bool authed) async {
    _t('auto-start: authenticated=$authed');
    if (authed) {
      unawaited(_adoptPortalAgentId());
      // We are inside the portal, so Finacle has accepted a login and cleared
      // its own failed-attempt counter. The screen's rejection count clears
      // too — and it clears for a MANUAL login as well, so an agent who types
      // his own password is never left on a screen that has stopped trying.
      _autoLoginPending = false;
      _loginClicks = 0;
      if (mounted && _loginProblem != null) {
        setState(() => _loginProblem = null);
      }
    }
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
      } else if (widget.isAslaas) {
        _aslaasSync();
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
    // A ledger of what did NOT go through, and why.
    //
    // Every skip used to be a _snack() — which calls clearSnackBars() first, so
    // in a 33-list run each message was wiped by the next progress update before
    // he could read it. The final tally was snacked and then Navigator.pop()
    // fired immediately, destroying that too. Net result: 12 lists silently did
    // not submit and he had to find them himself.
    //
    // `paymentUnknown` marks the one failure that must NOT simply be retried:
    // Pay All ran but no reference came back, so the money may well have moved.
    final failures = <({String label, String reason, bool paymentUnknown})>[];
    final serials = {
      for (final a in await widget.repo.all())
        if (a.serial > 0) a.accountNumber: a.serial
    };

    for (var i = 0; i < lots.length; i++) {
      if (!mounted) return;
      // Not final: the portal's rebate/default figures are folded in below.
      var lot = lots[i];
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
        failures.add((
          label: label,
          reason: prep.error ?? 'could not select and save the accounts',
          paymentUnknown: false,
        ));
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
            () => _progress = '$label · keyed $done of $total accounts…'),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (!fill.ok) {
        skipped++;
        failures.add((
          label: label,
          reason: fill.error ?? 'could not key the installments',
          paymentUnknown: false,
        ));
        await _engine.navigateToAccountList();
        continue;
      }
      // Capture the fees BEFORE paying: this is the screen that has them, and
      // after Pay All the portal moves on and they are gone for good.
      lot = _withPortalFigures(lot, fill);

      // 3) Automated audit — pay ONLY if this list's accounts all match the
      // portal screen and are keyed. No per-list tap.
      final problem = await _verifySelection(lot, fill);
      if (!mounted) return;
      if (problem != null) {
        skipped++;
        failures.add((label: label, reason: problem, paymentUnknown: false));
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
        // Pay All ran. Without a reference we cannot tell whether it went
        // through, so this one is flagged for a manual check rather than lumped
        // in with the safe failures.
        failures.add((
          label: label,
          reason: 'Pay All ran but no reference came back — check the portal '
              'before submitting this list again',
          paymentUnknown: true,
        ));
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
    if (failures.isEmpty) {
      _snack('Done — $paid submitted.');
      Navigator.of(context).pop(true);
      return;
    }
    // Something did not go. Hold the screen and SAY WHAT, rather than snacking a
    // tally into a navigation that discards it.
    await _showBatchSummary(paid: paid, failures: failures);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// What did not submit, and what to do about it.
  ///
  /// Deliberately a dialog he has to dismiss, not a snackbar: the batch pops its
  /// screen the moment it finishes, so anything transient is gone before it can
  /// be read. Twelve lists out of thirty-three failing quietly is how an agent
  /// ends up re-submitting by hand without knowing which ones.
  Future<void> _showBatchSummary({
    required int paid,
    required List<({String label, String reason, bool paymentUnknown})>
        failures,
  }) async {
    final unknown = failures.where((f) => f.paymentUnknown).toList();
    final safe = failures.where((f) => !f.paymentUnknown).toList();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('$paid submitted, ${failures.length} not',
            style: AppTheme.display(17)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (safe.isNotEmpty) ...[
                Text('Submit these again — nothing was paid:',
                    style: AppTheme.body(13, weight: FontWeight.w700)),
                const SizedBox(height: 6),
                ...safe.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• ${f.label} — ${f.reason}',
                          style: AppTheme.body(12.5,
                              color: AppTheme.inkMuted, height: 1.35)),
                    )),
              ],
              if (unknown.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Check the portal FIRST — these may already be paid:',
                    style: AppTheme.body(13,
                        weight: FontWeight.w700, color: AppTheme.red)),
                const SizedBox(height: 6),
                ...unknown.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• ${f.label} — ${f.reason}',
                          style: AppTheme.body(12.5,
                              color: AppTheme.red, height: 1.35)),
                    )),
              ],
              const SizedBox(height: 10),
              Text(
                'The lists that did not go are still in Lists, ready to submit '
                'again.',
                style:
                    AppTheme.body(12, color: AppTheme.inkFaint, height: 1.35),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Got it')),
        ],
      ),
    );
  }

  /// Deep Sync mission: fill exact per-account detail (last-deposit date etc.)
  /// for accounts that don't have it yet. Bounded + resumable across runs.
  Future<void> _deepSync() async {
    await _fillDetails();
    unawaited(Analytics.track('deep_sync'));
    if (mounted) Navigator.of(context).pop(true);
  }

  /// ASLAAS sync: read the portal's "ASLAAS Number Report" and save each
  /// account's ASLAAS number locally, so it's never entered by hand.
  Future<void> _aslaasSync() async {
    setState(() {
      _busy = true;
      _progress = 'Opening ASLAAS report…';
    });
    var diag = '';
    try {
      final map = await _engine.fetchAslaasReport(
        onProgress: (page, total, found) => setState(() =>
            _progress = 'ASLAAS report · page $page of $total · $found found'),
        onDiag: (r) => diag = r,
      );
      // If it walked, the page that refused the shortcut is the evidence.
      if (PortalSyncEngine.log.any((l) => l.contains('aslaas: controls on'))) {
        unawaited(_autoCapture('aslaas_report'));
      }
      if (map.isEmpty) {
        _snack('No ASLAAS numbers read${diag.isEmpty ? '' : ' · $diag'}.');
        return;
      }
      final written = await widget.repo.applyAslaas(map);
      unawaited(Analytics.track(
          'aslaas_sync', {'read': map.length, 'written': written}));
      if (!mounted) return;
      _snack('Saved ASLAAS numbers for $written accounts.');
      Navigator.of(context).pop(true);
    } catch (e) {
      _snack('ASLAAS sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
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
        await widget.repo.applyDetail(
            AccountDetail(accountNumber: e.key, lastDepositDate: e.value));
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
        onProgress: (done, target) =>
            setState(() => _progress = 'Filling in details $done of $target… '
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
      String? why;
      final detail = await _engine.fetchAccountDetail(
        accountNumber: widget.detailAccount!,
        serialHint: widget.detailSerial,
        onProgress: (m) => setState(() => _progress = m),
        onDiag: (r) => why = r,
      );
      if (detail == null) {
        // Say WHICH failure it was. "Could not read that account" sent him
        // hunting for a problem with the customer when the session was simply
        // dead, which is a thing he can fix in ten seconds.
        _snack(why ?? 'Could not read that account on the portal.');
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
        onProgress: (page, total, selected) =>
            setState(() => _progress = 'Page $page · $selected selected'),
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

  /// Submit flow (never pays on its own): key EVERY row — the Get-Rebate-&-
  /// Default click is the only place the portal states a default fee, and
  /// skipping it for ordinary single-installment rows is what printed lists
  /// short of the fine — audit that the portal shows exactly this list's
  /// accounts, then auto-pay if it's clean —
  /// otherwise hand the WebView back to the agent to review and tap "Pay All
  /// Saved Installments" himself. The app captures the reference either way.
  Future<void> _keyInstallmentsThenAwaitPayAll() async {
    // Not final: the portal's rebate/default figures are folded back into it
    // once installments are keyed.
    var lot = widget.submitLot!;
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
        onProgress: (done, total) =>
            setState(() => _progress = 'Keyed $done of $total installments…'),
      );
    } catch (e) {
      fill = InstallmentFillResult(0, 0, error: '$e');
    }
    if (!mounted) return;
    setState(() => _filling = false);
    if (!fill.ok) {
      _snack(
          'Could not key installments${fill.error == null ? '' : ' · ${fill.error}'}. '
          'Enter them on the portal instead.');
      return;
    }

    // Keep what the portal just computed — this screen is the only place it is
    // ever shown.
    if (fill.rebates.isNotEmpty) {
      lot = _withPortalFigures(lot, fill);
      await widget.lotStore?.update(lot);
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
  /// Fold the portal's rebate / default-fee figures onto a lot's items.
  ///
  /// Both submit paths must call this. The single-lot path did and the BATCH
  /// path did not, so every list submitted through "Submit Lists" — the flow
  /// actually used — kept printing blank fees while the code looked fixed.
  ///
  /// The portal derives these from each account's own history on the
  /// installment-entry screen. They appear nowhere on its printed report (the
  /// official PDF leaves both columns empty), so this screen is the only place
  /// they can ever be captured.
  static Lot _withPortalFigures(Lot lot, InstallmentFillResult fill) {
    if (fill.rebates.isEmpty) return lot;
    return lot.copyWith(items: [
      for (final it in lot.items)
        fill.rebates[it.accountNumber] == null
            ? it
            : it.copyWith(
                rebate: fill.rebates[it.accountNumber]!.rebate,
                defaultFee: fill.rebates[it.accountNumber]!.defaultFee,
              ),
    ]);
  }

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
  /// Two things have to hold: EXACTLY the list's accounts are on the payment
  /// screen, and every one of them reached Modified=YES — which [fill.ok] now
  /// covers, because every row is keyed rather than only the advance and cheque
  /// ones.
  Future<String?> _verifySelection(Lot lot, InstallmentFillResult fill) async {
    if (!fill.ok) {
      return 'only ${fill.saved} of ${fill.total} rows got keyed';
    }
    final expected = _installmentsFor(lot).keys.toSet();
    final onScreen = await _engine.installmentScreenAccounts();
    if (onScreen.length != expected.length || !onScreen.containsAll(expected)) {
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
                Icon(Icons.verified_user_outlined,
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
              '₹${lot.totalNetAmount} · ${lot.mode}.',
              style:
                  AppTheme.body(12.5, color: AppTheme.inkMuted, height: 1.35),
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
        onProgress: (page, total, count) => setState(
            () => _progress = 'Page $page of $total · $count accounts'),
      );
      if (result.accounts.isEmpty) {
        // Nothing read at all. Keep the page that caused it — a failed sync
        // costs a real login, so it must leave evidence behind.
        await _autoCapture('empty');
        _snack(result.error ?? 'No accounts found.');
        return;
      }
      // Merge whatever was read — replaceAll never removes a row, and the
      // accounts it did reach are worth keeping.
      //
      // `complete` is what decides whether absence MEANS anything. Only a walk
      // that started at page 1 and read every page the portal advertised can
      // conclude that a missing account has matured and closed; a short read
      // holds a prefix of the book, so absence there is just the pages it never
      // got to. Passing the flag through is the whole difference between
      // "closed accounts finally leave the book" and "a stalled sync empties
      // it".
      final merge = await widget.repo.replaceAll(result.accounts,
          complete: result.complete, alsoSeen: result.rejectedAccounts);
      final closed = merge.closed;

      // ...but a partial run is NOT a sync. Stamping last_sync would silence the
      // "you haven't synced" nag on a run that failed, and `sync_done` is what
      // the admin dashboard reads as the agent's book size — it takes the most
      // recent one per device, so a short count would overwrite a good figure
      // and under-report him until a full sync happened to follow.
      if (!result.complete) {
        if (!mounted) return;
        _snack(result.error ?? 'Sync did not finish — please run it again.');
        return;
      }

      await AppSettings.setLastSyncNow();
      unawaited(CloudSync.run());
      unawaited(Analytics.track('sync_done', {
        'accounts': result.accounts.length,
        // The "Monthly Book" — total ₹ of monthly RD installments across the
        // whole book (sum of denominations), matching the app's home hero. NOT
        // cumulative deposited (denomination × months paid), which is ~20-30×
        // larger and not what "book value" means here.
        'total_amount':
            result.accounts.fold<int>(0, (s, a) => s + a.denominationAmount),
        // A count, like `accounts` — no names, no numbers. Lets the dashboard
        // tell a book that shrank because accounts matured from one that shrank
        // because a sync went wrong.
        'closed': closed.length,
      }));
      if (!mounted) return;
      // Name the closures rather than letting accounts vanish quietly — this is
      // the agent's book, and a wrong closure must be something he can SEE.
      // They stay readable under Settings → Matured Accounts for a month.
      final closedNote = closed.isEmpty
          ? ''
          : closed.length == 1
              ? ' ${closed.first.customerName} has closed — see Settings → '
                  'Matured Accounts.'
              : ' ${closed.length} accounts have closed — see Settings → '
                  'Matured Accounts.';
      // The guard fired: the walk claimed to be complete but wanted to close a
      // chunk of the book. Nothing was closed.
      //
      // There are exactly two things this means, and the agent is the only one
      // who can tell them apart. Either the sync misread the portal — run it
      // again — or the book on this phone belongs to a different Agent ID, in
      // which case no number of re-syncs will ever clear it: the foreign rows
      // are never in the listing, so `missing` never shrinks and this same
      // refusal fires forever. That latch is what stranded books before the
      // per-agent split, and a pre-v13 book carries no owner to check against,
      // so asking is the only honest way out.
      if (merge.refused) {
        await _offerFreshBook(merge.refusedClosures);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      // Past the guard: a complete walk that agreed with the book. THAT is what
      // earns the owner stamp — it is the only evidence this phone has that the
      // book and the signed-in agent are the same person. Stamping earlier (on
      // login, or before this check) would vouch for a book nothing had
      // verified, and would silence the repair above for the mixed books it
      // exists to rescue.
      await AppDatabase.instance
          .setBookOwner((await Credentials.load()).agentId);
      // A clean run ends the streak, so two refusals must be consecutive.
      await (await SharedPreferences.getInstance()).remove(_kRefusedRunsKey);
      // Rows the portal showed but this app could not read. The agent is being
      // shown fewer accounts than he has, and that must never be silent.
      final dropped = result.rejected == 0
          ? ''
          : ' ${result.rejected} row(s) could not be read and were skipped.';
      // Accounts that have reached their 60-month term: the portal still lists
      // them but leaves the due date blank, so they are not collectible and not
      // errors. Said separately from `dropped` because the two call for
      // completely different reactions — one is a month's maturities, the other
      // is the app failing to read his book.
      // Record the matured rows BEFORE composing the message, so what the
      // agent is told matches what he will find under Settings → Matured
      // Accounts. These used to be counted and discarded: the book held fewer
      // customers than the portal listed, and on a first sync they did not even
      // appear as closures, because there was nothing yet to close.
      final maturedStored = result.maturedRows.isEmpty
          ? 0
          : await widget.repo.recordMatured(result.maturedRows);
      // Point at Settings only when something was actually written there —
      // telling him to go and look at an empty list is worse than saying
      // nothing. `maturedStored` is 0 when every matured row was already
      // recorded on an earlier sync.
      final matured = result.matured == 0
          ? ''
          : maturedStored == 0
              ? ' ${result.matured} account(s) have reached term.'
              : ' ${result.matured} account(s) have reached term — '
                  'see Settings → Matured Accounts.';
      _snack(result.error ??
          'Synced ${result.accounts.length} accounts.$closedNote$matured$dropped'
              '${closed.isEmpty ? ' Run Deep Sync for last-deposit dates.' : ''}');
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
    // `DOP.` is common to every agent id on this portal, so it is already
    // there and he types only his own code after it.
    final idCtrl = TextEditingController(
        text: _creds.agentId.isEmpty
            ? Credentials.dopPrefix
            : _creds.agentId)
      ..selection = TextSelection.collapsed(
          offset: (_creds.agentId.isEmpty
                  ? Credentials.dopPrefix
                  : _creds.agentId)
              .length);
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
      _creds = Credentials(
          agentId: Credentials.normaliseAgentId(idCtrl.text),
          password: pwCtrl.text);
      await _creds.save();
      await _autofillIfLogin();
      _snack('Login saved.');
    }
  }

  /// Debug: copy the current WebView page's full HTML to the clipboard, so the
  /// exact portal DOM can be shared to fix navigation (e.g. the ASLAAS report
  /// link). Navigate the WebView to the page you want, then tap this.
  /// Which screen this capture came from, for the filename.
  String get _screenSlug => widget.isDetail
      ? 'account_detail'
      : widget.isBatch
          ? 'submit_lists'
          : widget.isSubmit
              ? 'submit_list'
              : widget.isPrepare
                  ? 'prepare_list'
                  : widget.isDeep
                      ? 'deep_sync'
                      : widget.isAslaas
                          ? 'aslaas'
                          : 'sync';

  /// What the page LOOKS like, so a capture is self-describing even if the
  /// person sending it does not know what they were on.
  static String _pageKind(String html) {
    if (html.contains('Session is Expired') ||
        html.contains('Session Expired')) {
      return 'session_expired';
    }
    if (html.contains('AuthenticationFG.ACCESS_CODE')) return 'login';
    if (RegExp(r'Page\s+\d+\s+of\s+\d+', caseSensitive: false).hasMatch(html)) {
      return 'account_list';
    }
    if (html.contains('Enquire')) return 'dashboard';
    return 'unknown';
  }

  /// Capture the page as a FILE and hand it to the share sheet.
  ///
  /// This used to copy to the clipboard only. A 47-page account listing runs to
  /// megabytes — too much for a clipboard to carry reliably and far too much to
  /// paste into a chat — so the one artefact that makes a scraping bug
  /// diagnosable in minutes instead of guesses was the one thing that could not
  /// be got off the phone. The clipboard copy stays as a fallback.
  /// Save the current page to the app cache without opening a share sheet.
  ///
  /// Called automatically when a sync fails to reach the list. Each attempt
  /// costs a real login against Finacle's ten-failed-attempt lockout, so a
  /// failure that leaves nothing behind to look at is an expensive way to
  /// learn nothing — which is most of this project's debugging history. The
  /// file stays in the app's private cache; nothing is uploaded or shared.
  Future<void> _autoCapture(String why) async {
    try {
      final html = _decode(await _controller
          .runJavaScriptReturningResult('document.documentElement.outerHTML'));
      if (html.isEmpty) return;
      final dir = await getTemporaryDirectory();
      final name = 'autocapture__${_pageKind(html)}__$why.html';
      await File('${dir.path}/$name').writeAsString(html);
      _t('captured the failing page: $name (${html.length} chars)');
    } catch (e) {
      _t('auto-capture failed: $e');
    }
  }

  /// Everything needed to diagnose a failed login, in one file, in one tap.
  ///
  /// The parts that matter are the trace (what the app decided, in order, with
  /// timings) and the page the portal is actually showing. Neither could be got
  /// off the handset before: `trace` was null in release, and the auto-captures
  /// written by [_autoCapture] sat in a private cache directory with no way to
  /// share them.
  ///
  /// Redacted on purpose. The password is never traced and never appears in
  /// `outerHTML` (it is set via `.value`, which does not serialise to an
  /// attribute), but this scrubs anything that looks like one anyway — a
  /// diagnostic that is risky to send is a diagnostic that does not get sent.
  Future<void> _shareDiagnostics() async {
    try {
      final buf = StringBuffer()
        ..writeln('DOP Collect — sync diagnostics')
        ..writeln('build: ${SupabaseConfig.buildVersion}')
        ..writeln('screen: $_screenSlug')
        ..writeln('when: ${DateTime.now().toIso8601String()}')
        ..writeln('awaiting human check: $_awaitingHuman')
        ..writeln()
        ..writeln('--- trace (${PortalSyncEngine.log.length} lines) ---');
      for (final line in PortalSyncEngine.log) {
        buf.writeln(line);
      }

      buf
        ..writeln()
        ..writeln('--- page on screen now ---');
      try {
        final html = _decode(await _controller.runJavaScriptReturningResult(
            'document.documentElement.outerHTML'));
        buf
          ..writeln('looks like: ${_pageKind(html)} (${html.length} chars)')
          ..writeln(_redact(html));
      } catch (e) {
        buf.writeln('(could not read the page: $e)');
      }

      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final file = File('${dir.path}/dop_sync_diagnostics__$stamp.txt');
      await file.writeAsString(buf.toString());

      // Send the pages [_autoCapture] kept, too.
      //
      // It has been writing the failing page to this directory on every login
      // rejection and every blocked navigation — and nothing ever picked them
      // up, so the one artifact that would have settled each of these questions
      // sat in a private cache until the OS deleted it. The share carries the
      // page on screen NOW; a failure three steps ago is only in these files.
      final captures = <XFile>[];
      try {
        for (final f in dir.listSync()) {
          if (f is File && f.path.contains('autocapture__')) {
            final html = await f.readAsString();
            final safe = File('${f.path}.txt');
            await safe.writeAsString(_redact(html));
            captures.add(XFile(safe.path));
          }
        }
      } catch (e) {
        buf.writeln('(could not attach the captured pages: $e)');
      }
      _t('diagnostics: ${captures.length} captured page(s) attached');

      await Share.shareXFiles([XFile(file.path), ...captures],
          subject: 'DOP Collect — sync diagnostics',
          text: 'Sync diagnostics from ${SupabaseConfig.buildVersion}.');
    } catch (e) {
      _snack('Could not build diagnostics: $e');
    }
  }

  /// Blank anything password-shaped before a capture leaves the phone.
  static String _redact(String html) => html
      .replaceAll(
          RegExp(r'(ACCESS_CODE[^>]*?value\s*=\s*")[^"]*"',
              caseSensitive: false),
          r'$1[redacted]"')
      .replaceAll(
          RegExp(r'(type\s*=\s*"password"[^>]*?value\s*=\s*")[^"]*"',
              caseSensitive: false),
          r'$1[redacted]"');

  Future<void> _copyHtml() async {
    try {
      final html = _decode(await _controller
          .runJavaScriptReturningResult('document.documentElement.outerHTML'));
      final kind = _pageKind(html);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final name = '${_screenSlug}__${kind}__$stamp.html';

      await Clipboard.setData(ClipboardData(text: html));
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsString(html);
      await Share.shareXFiles([XFile(file.path)],
          subject: 'DOP Collect page capture — $kind',
          text: 'Screen: $_screenSlug\nLooks like: $kind\n'
              'Size: ${html.length} chars');
      if (mounted) _snack('Captured $name (${html.length} chars).');
    } catch (e) {
      _snack('Capture failed: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(seconds: 3), content: Text(m)));
  }

  /// Ask whether the book on this phone belongs to someone else.
  ///
  /// Only ever reached from a refused closure, and then only when the book
  /// cannot vouch for itself. The refusal ALONE is too weak a trigger: it also
  /// fires on a walk that wrongly reported complete, a parser regression on the
  /// listing page, and a portal that served a short page — and offering to set
  /// aside a man's own book on any of those is precisely the outcome
  /// `AccountRepository.closureCeiling` exists to pay the most to avoid.
  ///
  /// So the owner stamp decides. A book that says it belongs to this agent is
  /// his, and a broken sync is the only remaining explanation. A book stamped
  /// for someone else, or one carrying no stamp at all (written before v13,
  /// which is the mixed case this repair exists for), is the one worth asking
  /// about.
  /// How many COMPLETE syncs in a row the closure guard has refused.
  ///
  /// Keyed per book, exactly like the sync cursors, because that is what it is
  /// a statement about: THIS book disagreed with the portal twice running. Left
  /// device-wide it would be one agent's streak carried onto another agent's
  /// book, and the thing it unlocks is an offer to set that book aside.
  ///
  /// The `foreign` gate above already blocks the obvious version of that — a
  /// book stamped for the signed-in agent never reaches the counter, and a book
  /// is stamped at login — so this is the narrow remainder rather than an open
  /// hole. It is still wrong to key a fact about a book to the device, and the
  /// suffix costs nothing.
  static String get _kRefusedRunsKey {
    final k = AppDatabase.instance.agentKey;
    return k.isEmpty ? 'sync_refused_runs' : 'sync_refused_runs_$k';
  }

  Future<void> _offerFreshBook(int refused) async {
    if (!mounted) return;
    const brokenSync =
        'Nothing was closed. Your book is as it was — run Sync again.';

    final id = (await Credentials.load()).agentId;
    // No id in hand means the Keystore would not open, not that the book is
    // foreign. Never offer to set a book aside on the strength of a failed
    // secure-storage read.
    if (id.isEmpty) return _snack(brokenSync);

    final owner = await AppDatabase.instance.bookOwner();
    final foreign = owner == null ||
        AppDatabase.agentKeyFor(owner) != AppDatabase.agentKeyFor(id);
    if (!foreign) return _snack(brokenSync);

    // An unstamped book is the mixed case OR an agent whose first sync since
    // the update happened to misread the portal, and on the strength of one
    // refusal those look identical. So wait for the second in a row.
    //
    // That is the difference itself, not a delay bolted on: a misread succeeds
    // when it is run again, while a book that belongs to someone else refuses
    // every time — its foreign rows are never in the listing, so the missing
    // set never shrinks. One retry separates them, and costs a wrong guess
    // nothing but a second Sync.
    final prefs = await SharedPreferences.getInstance();
    final inARow = (prefs.getInt(_kRefusedRunsKey) ?? 0) + 1;
    await prefs.setInt(_kRefusedRunsKey, inARow);
    if (inARow < 2) return _snack(brokenSync);

    if (!mounted) return;
    final fresh = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('This book may not be yours', style: AppTheme.display(18)),
        content: Text(
          'Sync found $refused accounts on this phone that your portal '
          'listing no longer has. Nothing was closed and nothing was lost.\n\n'
          'If this phone was last used with a different Agent ID, start a '
          'fresh book for $id. The old book is kept on the phone, not '
          'deleted, and you can put it back.\n\n'
          'Otherwise the sync misread the portal — just run it again.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Run Sync again')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start a fresh book'),
          ),
        ],
      ),
    );
    if (fresh != true) return _snack(brokenSync);

    await prefs.remove(_kRefusedRunsKey);
    await AppDatabase.instance.startFreshBook(id);
    if (!mounted) return;
    // Undo, and it has to be here rather than in a settings screen somewhere:
    // a set-aside book is invisible to the agent and reachable only over adb,
    // so "kept, not deleted" is a promise nothing could keep until now.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text('Started a fresh book for $id. Run Sync to fill it.'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          final ok = await AppDatabase.instance.restoreSetAsideBook();
          _snack(ok
              ? 'Your previous book is back.'
              : 'Could not put the previous book back.');
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // A BROWSER CANNOT DRIVE THE DOP PORTAL.
    //
    // Everything below this line is a WebView pointed at
    // dopagent.indiapost.gov.in, with JavaScript injected to read its DOM.
    // `webview_flutter` has no web implementation, and even if it did the
    // same-origin policy would stop it: the portal sends X-Frame-Options, and
    // a cross-origin frame's DOM cannot be read at all. This is a property of
    // the web, not a gap in the app.
    //
    // The guard is HERE rather than at the nine call sites that push this
    // screen, because the failure it prevents is a fully blank page — the
    // WebView renders nothing on web and the agent is left on an empty screen
    // with a back button. One of those call sites would eventually be added
    // without the check.
    if (kIsWeb) return const _PortalUnavailableOnWeb();

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
                            : widget.isAslaas
                                ? 'ASLAAS Numbers'
                                : 'Sync'),
        actions: [
          IconButton(
              tooltip: 'Share diagnostics',
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: _shareDiagnostics),
          IconButton(
              tooltip: 'Copy page HTML (debug)',
              icon: const Icon(Icons.code_rounded),
              onPressed: _copyHtml),
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
                    _loginProblem ??
                    (_awaitingHuman
                        ? 'The portal wants a human check — tap "I\'m not a '
                            'robot" on the page. Pinch to zoom in on it.'
                        : 'Log in and type the captcha — sync starts '
                            'automatically.'),
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
                        : widget.isAslaas
                            ? _aslaasSync
                            : _sync),
        icon: Icon(
            widget.isBatch
                ? Icons.cloud_upload_rounded
                : widget.isPrepare
                    ? Icons.playlist_add_check
                    : widget.isDeep
                        ? Icons.cloud_download_rounded
                        : widget.isAslaas
                            ? Icons.badge_outlined
                            : Icons.sync,
            size: 18),
        label: Text(widget.isBatch
            ? 'Submit all'
            : widget.isPrepare
                ? 'Prepare'
                : widget.isDeep
                    ? 'Deep Sync'
                    : widget.isAslaas
                        ? 'Get ASLAAS'
                        : 'Sync'),
      ),
    );
  }
}

/// Shown instead of the portal WebView in a browser.
///
/// It names the phone as the thing that does the portal work, because that is
/// the actual answer — not "unsupported", which reads as broken.
class _PortalUnavailableOnWeb extends StatelessWidget {
  const _PortalUnavailableOnWeb();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Portal')),
      body: Container(
        decoration: AppTheme.canvas,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.phone_iphone_rounded,
                      size: 34, color: AppTheme.inkMuted),
                  const SizedBox(height: 16),
                  Text('Use your phone for this',
                      style: AppTheme.display(20, weight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Text(
                    'The India Post agent portal cannot be opened from a '
                    'browser tab — it refuses to be embedded, and a web page '
                    'is not allowed to read another site. Your phone does the '
                    'portal work and uploads the result; this screen shows '
                    'whatever it has sent.',
                    style: AppTheme.body(14,
                        color: AppTheme.inkMuted, height: 1.45),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Sync on your phone, then press Sync here to pull it down.',
                    style: AppTheme.body(13.5, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
