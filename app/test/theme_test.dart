import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dop_collect/data/app_settings.dart';
import 'package:dop_collect/theme/app_theme.dart';

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// google_fonts has no bundled .ttf in a unit test, so it throws from a
/// fire-and-forget load. The TextStyle it hands back is still fully formed —
/// and its colour is the whole point here — so run those calls in a zone that
/// swallows that one background failure.
T _ignoringFontLoad<T>(T Function() body) {
  late T out;
  runZonedGuarded(() => out = body(), (_, __) {});
  return out;
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(() {
    // GoogleFonts reaches for the asset bundle; keep it off the network too,
    // since only the resolved colour matters here.
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // The palette is global mutable state — never leave a test's mode behind.
  tearDown(() => AppTheme.applyBrightness(Brightness.light));

  group('the palette actually swaps', () {
    test('ink and surface invert with the mode', () {
      AppTheme.applyBrightness(Brightness.light);
      final lightInk = AppTheme.ink, lightSurface = AppTheme.surface;
      expect(AppTheme.isDark, isFalse);

      AppTheme.applyBrightness(Brightness.dark);
      expect(AppTheme.isDark, isTrue);
      expect(AppTheme.ink, isNot(lightInk));
      expect(AppTheme.surface, isNot(lightSurface));
      // Ink is dark-on-light and light-on-dark, not merely "different".
      expect(_luminance(AppTheme.ink),
          greaterThan(_luminance(AppTheme.surface)));
    });

    test('the ground drops below the charcoal on dark', () {
      // Dark is not an inversion: the card IS the dashboard's charcoal, and
      // the ground goes under it so nesting still reads.
      AppTheme.applyBrightness(Brightness.dark);
      expect(_luminance(AppTheme.surface), greaterThan(_luminance(AppTheme.bg)));
      expect(_luminance(AppTheme.surfaceSoft),
          greaterThan(_luminance(AppTheme.surface)));
    });

    test('the solid object inverts with the mode', () {
      // Charcoal is the subject on light; on dark that block has to flip to
      // near-white or it vanishes into the ground it is meant to sit on.
      AppTheme.applyBrightness(Brightness.light);
      expect(_luminance(AppTheme.black), lessThan(_luminance(AppTheme.bg)));
      AppTheme.applyBrightness(Brightness.dark);
      expect(_luminance(AppTheme.black), greaterThan(_luminance(AppTheme.bg)));
    });
  });

  group('the accent is scarce and load-bearing', () {
    test('it does not move between themes', () {
      // The one token that must mean the same thing in both, and the same
      // thing the dashboard means by it.
      AppTheme.applyBrightness(Brightness.light);
      final lightAccent = AppTheme.focal;
      AppTheme.applyBrightness(Brightness.dark);
      expect(AppTheme.focal, lightAccent);
      expect(AppTheme.focal, const Color(0xFFEDF751));
    });

    test('it is a FILL, never type', () {
      // ~1.2:1 on white. This asserts the rule that keeps it honest: anything
      // that tried to set text in the accent would be unreadable.
      AppTheme.applyBrightness(Brightness.light);
      expect(_contrast(AppTheme.focal, AppTheme.surface), lessThan(1.5));
      // ...and that the pairing it always ships with does work.
      expect(_contrast(AppTheme.onFocal, AppTheme.focal), greaterThan(13.0));
    });
  });

  group('light mode holds the outdoor ratios', () {
    setUp(() => AppTheme.applyBrightness(Brightness.light));

    test('the ink ramp is cool but still AA', () {
      // Hue retuned to the dashboard's charcoal; ratios kept from the ramp
      // that was chosen for reading in sunlight.
      expect(AppTheme.ink, const Color(0xFF171C22));
      expect(_contrast(AppTheme.ink, AppTheme.surface), greaterThan(15.0));
      expect(_contrast(AppTheme.inkMuted, AppTheme.surface), greaterThan(7.0));
      expect(_contrast(AppTheme.inkFaint, AppTheme.surface), greaterThan(4.5));
    });
  });

  group('text that omits a colour still follows the theme', () {
    // ~230 of the app's ~390 body()/display() calls pass no colour. If the
    // default were a const it would stay near-black and vanish on dark.
    test('body() and display() default to the live ink', () {
      AppTheme.applyBrightness(Brightness.light);
      expect(_ignoringFontLoad(() => AppTheme.body(14)).color, AppTheme.ink);
      expect(_ignoringFontLoad(() => AppTheme.display(20)).color, AppTheme.ink);
      final lightDefault = _ignoringFontLoad(() => AppTheme.body(14)).color;

      AppTheme.applyBrightness(Brightness.dark);
      expect(_ignoringFontLoad(() => AppTheme.body(14)).color, AppTheme.ink);
      expect(_ignoringFontLoad(() => AppTheme.display(20)).color, AppTheme.ink);
      expect(_ignoringFontLoad(() => AppTheme.body(14)).color,
          isNot(lightDefault));
    });

    test('an explicit colour is still honoured', () {
      AppTheme.applyBrightness(Brightness.dark);
      expect(_ignoringFontLoad(() => AppTheme.body(14, color: AppTheme.red)).color,
          AppTheme.red);
    });
  });

  group('dark mode clears WCAG AA', () {
    setUp(() => AppTheme.applyBrightness(Brightness.dark));

    test('the ink ramp holds its ratios against the card', () {
      expect(_contrast(AppTheme.ink, AppTheme.surface), greaterThan(7.0));
      expect(_contrast(AppTheme.inkMuted, AppTheme.surface), greaterThan(7.0));
      // The faintest step is body-text minimum, not decoration.
      expect(_contrast(AppTheme.inkFaint, AppTheme.surface), greaterThan(4.5));
    });

    test('status colours are lifted off the light values', () {
      // #15A06A only reaches ~3.6:1 on a dark card, which is why these differ.
      for (final c in [AppTheme.green, AppTheme.red, AppTheme.amber]) {
        expect(_contrast(c, AppTheme.surface), greaterThan(4.5));
      }
    });

    test('a CTA label reads against its own fill', () {
      expect(_contrast(AppTheme.onAccent, AppTheme.black), greaterThan(4.5));
    });
  });

  test('a CTA label reads against its fill on light too', () {
    AppTheme.applyBrightness(Brightness.light);
    expect(_contrast(AppTheme.onAccent, AppTheme.black), greaterThan(4.5));
  });

  test('the lime hero keeps dark lettering in BOTH themes', () {
    // The focal card stays lime whatever the mode, so its text must not follow
    // ink — near-white on lime would be unreadable.
    for (final b in [Brightness.light, Brightness.dark]) {
      AppTheme.applyBrightness(b);
      expect(_contrast(AppTheme.onFocal, AppTheme.focalTop), greaterThan(4.5));
      expect(
          _contrast(AppTheme.onFocal, AppTheme.focalBottom), greaterThan(4.5));
    }
  });

  test('ThemeData carries the matching brightness', () {
    expect(_ignoringFontLoad(() => AppTheme.light).colorScheme.brightness,
        Brightness.light);
    expect(_ignoringFontLoad(() => AppTheme.dark).colorScheme.brightness,
        Brightness.dark);
    // Building one must not disturb the live palette.
    AppTheme.applyBrightness(Brightness.light);
    _ignoringFontLoad(() => AppTheme.dark);
    expect(AppTheme.isDark, isFalse);
  });

  group('the choice survives a restart', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to following the phone', () async {
      expect(await AppSettings.themeMode(), ThemeMode.system);
    });

    test('every mode round-trips', () async {
      for (final m in ThemeMode.values) {
        await AppSettings.setThemeMode(m);
        expect(await AppSettings.themeMode(), m);
      }
    });
  });
}
