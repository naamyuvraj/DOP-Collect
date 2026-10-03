import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// How the portal WebViews are configured — one place, because getting it
/// wrong is invisible in code review and obvious on a handset.
///
/// The DOP portal is a Finacle deployment from ~2017: fixed-width tables, no
/// `<meta name="viewport">` anywhere on the login page (verified against
/// `recon/live/01_login__before_submit.html`). A page like that has exactly two
/// rendering modes on a phone:
///
///   * **Desktop layout, zoomed out to fit** — the browser lays the page out at
///     a desktop width and scales the whole thing down. Everything stays where
///     the page author put it; the agent pinch-zooms to read a field. This is
///     what "Request desktop site" does in Chrome, and it is what every other
///     app that drives this portal looks like.
///   * **Reflowed to the phone's width** — the browser pretends the viewport is
///     ~360 CSS px. A 980 px table does not fit in 360 px, so cells collide,
///     columns clip off the right edge, and anything positioned relative to the
///     page ends up somewhere the agent cannot reach or tap.
///
/// We were shipping the second one, and not on purpose: a desktop User-Agent
/// was set (so the *server* sends desktop HTML) but nothing told the WebView to
/// *lay it out* at desktop width. `webview_flutter_android` 4.13.0 constructs
/// every controller with `setUseWideViewPort(false)` — see
/// `android_webview_controller.dart:151` — so the default is the reflow mode,
/// and `setLoadWithOverviewMode(true)`, which it also sets, does nothing
/// without it. Desktop HTML, phone layout: the worst of both.
///
/// That is not only cosmetic. A control the agent has to touch himself — the
/// reCAPTCHA checkbox the portal now raises after a rejected login — can land
/// off-screen or underneath another cell, which reads as "the reCAPTCHA doesn't
/// work". Nothing is wrong with the reCAPTCHA; it was never reachable.
class PortalWebView {
  PortalWebView._();

  /// The legacy portal serves its mobile-hostile pages to anything that does
  /// not look like a desktop browser, so this is not optional.
  static const desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /// Lay pages out at desktop width and zoom out to fit — the "mini desktop
  /// view".
  ///
  /// Safe to call before the first `loadRequest`, and cheap enough to call
  /// again later. Android is the whole fleet; the iOS branch exists so this
  /// does not silently become an Android-only behaviour if the app is ever
  /// built for it.
  static Future<void> applyDesktopViewport(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      // The one line that matters. With no viewport meta on the page, Android
      // then lays out at its 980 CSS px default and `loadWithOverviewMode`
      // (already true) scales that to the screen.
      await platform.setUseWideViewPort(true);
      // Honour the page's own font sizes. A phone set to a large system font
      // scales WebView text by up to 130%, which overflows a fixed-width table
      // just as badly as a narrow viewport does — a "broken layout" that only
      // reproduces on the handsets whose owners turned the text size up.
      await platform.setTextZoom(100);
      // Pinch to read the small print / hit the reCAPTCHA checkbox.
      await platform.enableZoom(true);
    }
  }

  /// iOS/WKWebView fallback: it has no `useWideViewPort`, so the layout width
  /// has to be asked for in the page itself. Injected only when the page does
  /// not already declare a viewport — overriding a page that made its own
  /// choice would be a regression, not a fix.
  ///
  /// A no-op on Android, where [applyDesktopViewport] has already done it
  /// properly and a meta tag would only fight the setting.
  static const wideViewportMetaJs = r'''
    (function(){
      if(document.querySelector('meta[name="viewport" i]')) return 'had-one';
      var m=document.createElement('meta');
      m.setAttribute('name','viewport');
      m.setAttribute('content','width=980, initial-scale='+
        (Math.min(1,(window.screen.width||360)/980)));
      (document.head||document.documentElement).appendChild(m);
      return 'added';
    })();
  ''';
}
