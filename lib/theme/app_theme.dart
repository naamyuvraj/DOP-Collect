import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Three-tone system, ported from the admin dashboard so one product reads as
/// one product: a stark ground, charcoal for type and structural blocks, and a
/// single neon lime that only ever answers "which one is the point".
///
/// The rules that make a dense screen calm:
///
///  * **Charcoal is the subject.** A charcoal-filled card is a solid object,
///    not a dark panel. At most one per screen.
///  * **Neon is the one number that moved.** Fill only — on white it is ~1.2:1
///    and can never carry text. It always ships with charcoal type (14.7:1),
///    and its drop face is tinted in its own shadow so the block reads as one
///    extruded solid rather than a sticker. At most one per row.
///  * **Everything else is quarantined.** Red/amber exist only for states the
///    three tones genuinely cannot express.
///
/// Deliberate deviations from the dashboard, all for the phone:
///
///  * **Radius 14, not 4.** 4px is spreadsheet language; 24 was the old
///    soft-UI. 14 reads flat and modern while staying thumb-affordance sized.
///  * **The face sits at ~13%, not 7%.** The dashboard is read on a desktop in
///    an office. A 7% hairline-and-face survives that; it does not survive
///    Ramesh-ji on a cheap LCD at half brightness in daylight.
///  * **Green stays.** #15A06A is genuine domain semantics in a collections
///    app across 40-odd sites, so it is kept — but demoted to type, dots and
///    pills, never a fill sitting next to the accent. That is the same
///    containment the dashboard applies to its own `positive`.
///  * **Hover depth is dropped.** `--ex: 8px` on hover is a mouse affordance
///    with no touch analogue; only the press state (face shrinks to 2px)
///    survives.
///
/// ## Dark mode
///
/// Every colour below is a *getter* over a swappable [_Palette], not a
/// `const`. That is deliberate: ~600 call sites across 42 files read
/// `AppTheme.ink` and friends directly, and almost nothing in this app reads
/// `Theme.of(context)`. Turning the tokens into context lookups would have
/// meant touching all 600; swapping the palette underneath them costs nothing
/// at the call site.
///
/// Dark is not an inversion. The ground drops below the charcoal so charcoal
/// becomes the *card*, the "subject" block flips to near-white, and the
/// extruded face flips from a shadow to a lit edge — a dark face on a dark
/// ground is simply invisible. The accent does not move: it is the one thing
/// that must mean the same in both.
///
/// The trade is that these can no longer appear in a `const` expression. Call
/// [applyBrightness] before building the widget tree, then rebuild the tree
/// when it changes — see `_DopCollectAppState`.
class AppTheme {
  // ---- Palettes -----------------------------------------------------------

  static _Palette _p = _light;

  /// Swap the token set. Call BEFORE building the tree; the caller is
  /// responsible for rebuilding so widgets re-read the new values.
  static void applyBrightness(Brightness b) =>
      _p = b == Brightness.dark ? _dark : _light;

  static bool get isDark => _p.brightness == Brightness.dark;

  /// The user's choice: light, dark, or follow the phone. The app root listens
  /// to this, so any screen can flip the theme without plumbing a callback.
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  // Ground — flat, no gradient. Whitespace separates, not tint.
  static Color get bg => _p.bg;
  static Color get bgTop => _p.bg; // kept: callers still name a gradient
  static Color get bgBottom => _p.bg;

  // Surfaces
  static Color get surface => _p.surface;
  static Color get surfaceSoft => _p.surfaceSoft; // nested wells
  static Color get line => _p.line;
  static Color get divider => _p.divider;

  // Ink — cool charcoal, but at the ratios the old green-tinted ramp was
  // tuned to (~17:1 / ~7:1 / ~4.6:1). The hue is the dashboard's; the
  // contrast is this app's, because this one gets read outdoors.
  static Color get ink => _p.ink;
  static Color get inkMuted => _p.inkMuted;
  static Color get inkFaint => _p.inkFaint;

  /// A nested block sitting *on* a charcoal card.
  static Color get inkWell => _p.inkWell;

  // Accent + the charcoal solid
  static Color get focal => _p.focal; // FILL ONLY — ~1.2:1 on white
  static Color get accentDim => _p.accentDim;
  static Color get black => _p.black; // charcoal: the subject / the CTA
  static Color get accent => _p.black;
  static Color get accentSoft => _p.accentSoft;

  /// Foreground that sits ON [black]. White on light, charcoal on dark — the
  /// solid block inverts wholesale, so its type inverts with it.
  static Color get onAccent => _p.onAccent;

  // Status — quarantined. Only for what the three tones cannot express.
  static Color get green => _p.green;
  static Color get greenSoft => _p.greenSoft;
  static Color get red => _p.red;
  static Color get redSoft => _p.redSoft;
  static Color get amber => _p.amber;
  static Color get amberSoft => _p.amberSoft;
  static Color get blueSoft => _p.blueSoft;

  // Chrome the widgets need but that never belonged in a call site
  static Color get cardShadow => _p.cardFace; // the extruded face
  static Color get cardBorder => _p.cardBorder;
  static Color get glassBorder => _p.cardBorder;
  static Color get navTop => _p.surface;
  static Color get navBottom => _p.surface;
  static Color get navBorder => _p.cardBorder;
  static Color get focalTop => _p.focal; // flat now, not a gradient
  static Color get focalBottom => _p.focal;
  static Color get focalEdge => _p.focalFace;
  static Color get scrim => _p.scrim;

  // Back-compat aliases
  static Color get textPrimary => _p.ink;
  static Color get textMuted => _p.inkMuted;
  static Color get danger => _p.red;
  static Color get success => _p.green;

  /// Charcoal type for the accent block. The neon stays neon in BOTH themes —
  /// it is the one token that must not move — so its foreground must never
  /// follow [ink], or it inverts out from under the lime.
  static const Color onFocal = Color(0xFF171C22);

  /// Ink for the few surfaces that stay light in both themes: the accent slabs
  /// and the PDF document viewer.
  static const Color onLight = Color(0xFF171C22);
  static const Color onLightMuted = Color(0xFF4F5863);

  /// Status colour for those always-light surfaces, which must not follow the
  /// canvas either.
  static Color get amberOnFocal => _light.amber;

  /// 14, not the dashboard's 4 and not the old 24 — see the class docs.
  static const cardRadius = 14.0;

  /// How far the extruded face is offset. Shrinks on press; there is no hover.
  static const faceOffset = 4.0;
  static const faceOffsetPressed = 2.0;

  /// Anything you can press stands further off the page than a card does. The
  /// card face says "this is a solid object"; this one says "and it will move
  /// when you push it" — the only depth cue left once hover is gone.
  static const buttonFace = 6.0;

  // ---- Typography (Plus Jakarta Sans, geometric sans) --------------------
  //
  // `color` is nullable rather than defaulting to `ink`: a default argument
  // must be const, and resolving it here is what makes the ~230 call sites
  // that omit a colour follow the theme instead of staying near-black.

  static TextStyle display(double size,
          {FontWeight weight = FontWeight.w700,
          Color? color,
          double spacing = -0.3,
          double? height}) =>
      GoogleFonts.plusJakartaSans(
          fontSize: size,
          fontWeight: weight,
          color: color ?? _p.ink,
          letterSpacing: spacing,
          height: height);

  static TextStyle body(double size,
          {FontWeight weight = FontWeight.w500,
          Color? color,
          double spacing = 0,
          double? height}) =>
      GoogleFonts.plusJakartaSans(
          fontSize: size,
          fontWeight: weight,
          color: color ?? _p.ink,
          letterSpacing: spacing,
          height: height);

  static TextStyle label(Color color) => GoogleFonts.plusJakartaSans(
      fontSize: 13, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.4);

  // ---- ThemeData ----------------------------------------------------------

  static ThemeData get light => _themeFrom(_light);
  static ThemeData get dark => _themeFrom(_dark);

  /// Status-bar and nav-bar icon colours for the live palette. Most screens
  /// here have a transparent AppBar or none at all, so without this the system
  /// icons keep their light-mode darkness and disappear into a dark ground.
  static SystemUiOverlayStyle get overlayStyle => _overlayFor(_p);

  static SystemUiOverlayStyle _overlayFor(_Palette p) {
    final dark = p.brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: p.bg,
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
    );
  }

  static ThemeData _themeFrom(_Palette p) {
    final base = p.brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: p.black,
        onPrimary: p.onAccent,
        secondary: p.black,
        surface: p.surface,
        onSurface: p.ink,
        error: p.red,
        brightness: p.brightness,
      ),
      textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme)
          .apply(bodyColor: p.ink, displayColor: p.ink),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: p.ink,
            letterSpacing: -0.3),
        iconTheme: IconThemeData(color: p.ink),
        systemOverlayStyle: _overlayFor(p),
      ),
      cardColor: p.surface,
      dividerColor: p.divider,
      // Dialog actions. Material's ButtonStyle has no hard-offset shadow
      // primitive, so these cannot carry the extruded face the app's own
      // buttons do — but they can at least share the palette and the geometry
      // instead of arriving as stock Material.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.black,
          foregroundColor: p.onAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius - 2)),
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.inkMuted,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius - 2)),
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink,
          side: BorderSide(color: p.cardBorder),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius - 2)),
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius + 4)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.black,
        foregroundColor: p.onAccent,
        elevation: 0,
      ),
      // Float snackbars with a bottom margin so they clear the floating nav
      // pill (screens with their own Scaffold anchored them under it before).
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        backgroundColor: p.snack,
        contentTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 13.5, fontWeight: FontWeight.w500, color: p.onSnack),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius)),
      ),
    );
  }

  /// A card: hairline edge and a hard, zero-blur extruded face. Never a
  /// blurred shadow — that would drag the whole panel back to the glass look
  /// this replaced.
  ///
  /// The face is picked from the fill, so an accent card is extruded in the
  /// accent's own shadow and a charcoal card in its own: each block reads as
  /// one solid, not a sticker on a grey slab.
  /// [translucent] frosts the fill so the well behind shows through, with a
  /// diagonal sheen and a bright rim. LIGHT MODE ONLY — on the black ground a
  /// see-through card would dissolve into it, and the whole point of the dark
  /// ladder is separation by lightness.
  ///
  /// No `BackdropFilter`: four live blurs on the scrolling dashboard janked
  /// badly on the ₹9,000 target phone, which is why the old glass panels were
  /// flat fills too. This is the same trade — a painted sheen, not a real one.
  static BoxDecoration card(
      {Color? fill,
      double radius = cardRadius,
      double offset = faceOffset,
      bool translucent = false}) {
    final f = fill ?? _p.surface;
    if (translucent && !isDark && f != _p.focal && f != _p.black) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            f.withValues(alpha: 0.95),
            f.withValues(alpha: 0.52),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1.2),
        boxShadow: [
          BoxShadow(
              color: _p.cardFace,
              offset: Offset(offset, offset),
              blurRadius: 0),
        ],
      );
    }
    final (Color face, Color edge) = f == _p.focal
        ? (_p.focalFace, _p.focalLine)
        : f == _p.black
            ? (_p.inkFace, _p.inkWell)
            : (_p.cardFace, _p.cardBorder);
    return BoxDecoration(
      color: f,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: edge, width: 1),
      boxShadow: [
        BoxShadow(color: face, offset: Offset(offset, offset), blurRadius: 0),
      ],
    );
  }

  /// The surface for a card at [rank] within its section — 0 is the card that
  /// carries the section, and each step recedes toward the well behind it.
  ///
  /// This palette has exactly TWO hues, so a card family cannot be built the
  /// way the old pastels were, by giving each one its own colour. It is built
  /// from the accent's own hue in light — a warm off-white reading against the
  /// cool grey well, which is a temperature contrast rather than a second
  /// colour — and from pure value steps in dark, where any hue wash over
  /// near-black turns to dirt rather than reading as colour.
  ///
  /// Status hues are deliberately NOT used here. Red, amber and green are
  /// quarantined to the dot: a colour that means "these accounts are in
  /// trouble" must not also be wallpaper, or it stops meaning anything.
  static Color cardSurface(int rank) {
    if (isDark) {
      const steps = [Color(0xFF181E25), Color(0xFF141A20), Color(0xFF101418)];
      return steps[rank.clamp(0, steps.length - 1)];
    }
    const alphas = [0.16, 0.07, 0.0];
    final a = alphas[rank.clamp(0, alphas.length - 1)];
    return a == 0
        ? _p.surface
        : Color.alphaBlend(_p.focal.withValues(alpha: a), _p.surface);
  }

  /// A flat nested well — no edge, no face. For insets inside a card.
  static BoxDecoration panel(Color fill, {double radius = 10}) =>
      BoxDecoration(color: fill, borderRadius: BorderRadius.circular(radius));

  /// The page ground. Flat: the mint gradient is gone.
  static BoxDecoration get canvas => BoxDecoration(color: _p.bg);
}

/// One complete token set. Everything the app can paint with lives here so a
/// theme is a single value swap rather than a scatter of `if (isDark)`.
class _Palette {
  const _Palette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceSoft,
    required this.line,
    required this.divider,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.inkWell,
    required this.inkFace,
    required this.focal,
    required this.accentDim,
    required this.focalFace,
    required this.focalLine,
    required this.black,
    required this.onAccent,
    required this.accentSoft,
    required this.green,
    required this.greenSoft,
    required this.red,
    required this.redSoft,
    required this.amber,
    required this.amberSoft,
    required this.blueSoft,
    required this.cardFace,
    required this.cardBorder,
    required this.scrim,
    required this.snack,
    required this.onSnack,
  });

  final Brightness brightness;
  final Color bg, surface, surfaceSoft, line, divider;
  final Color ink, inkMuted, inkFaint, inkWell, inkFace;
  final Color focal, accentDim, focalFace, focalLine;
  final Color black, onAccent, accentSoft;
  final Color green, greenSoft, red, redSoft, amber, amberSoft, blueSoft;
  final Color cardFace, cardBorder;
  final Color scrim, snack, onSnack;
}

/// Stark white ground, cool charcoal, one neon.
const _Palette _light = _Palette(
  brightness: Brightness.light,
  bg: Color(0xFFFFFFFF),
  surface: Color(0xFFFFFFFF),
  surfaceSoft: Color(0xFFF4F5F9),
  line: Color(0xFFE8EAEF),
  divider: Color(0xFFEEF0F4),
  ink: Color(0xFF171C22), // 17.3:1 on white
  inkMuted: Color(0xFF4F5863), // 7.2:1
  inkFaint: Color(0xFF6C7681), // 4.6:1
  inkWell: Color(0xFF292C2F), // nested block on a charcoal card
  inkFace: Color(0x38171C22), // a charcoal card's own face
  focal: Color(0xFFEDF751),
  accentDim: Color(0xFFE2ED3C),
  focalFace: Color(0xFF96A814), // the accent's own shadow, not grey
  focalLine: Color(0xFFC6D23E),
  black: Color(0xFF171C22),
  onAccent: Color(0xFFFFFFFF),
  accentSoft: Color(0xFFF6FAD4),
  green: Color(0xFF15A06A), // money-in. Type, dots and pills only.
  greenSoft: Color(0xFFE6F4EC),
  red: Color(0xFFD64545),
  redSoft: Color(0xFFFBE9E9),
  amber: Color(0xFF8A6100),
  amberSoft: Color(0xFFFBF1D2),
  blueSoft: Color(0xFFE8EEF9),
  cardFace: Color(0x21171C22), // ~13%, not the dashboard's 7% — sunlight
  cardBorder: Color(0xFFE8EAEF),
  scrim: Color(0x66000000),
  snack: Color(0xFF171C22),
  onSnack: Color(0xFFFFFFFF),
);

/// Not an inversion. The ground drops BELOW the charcoal, so charcoal becomes
/// the card; the "subject" block flips to near-white; and the extruded face
/// flips from a shadow to a lit edge, because a dark face on a dark ground is
/// invisible. The accent does not move.
const _Palette _dark = _Palette(
  brightness: Brightness.dark,
  // Pure black. On an OLED handset it is the most minimal ground there is —
  // unlit pixels — and it buys the card ladder above it more room to separate
  // by lightness alone, which is the only depth cue dark mode really has.
  bg: Color(0xFF000000),
  surface: Color(0xFF101418), // the card, one clear step off the ground
  surfaceSoft: Color(0xFF181D23), // nested wells, one step above that
  line: Color(0xFF232A32),
  divider: Color(0xFF1C222A),
  ink: Color(0xFFF8F9FB), // 16.5:1 on the card
  inkMuted: Color(0xFFA0AAB6), // 7.3:1
  inkFaint: Color(0xFF7E8894), // 4.8:1
  inkWell: Color(0xFFD5DAE1),
  inkFace: Color(0xFF6A737F), // the near-white block's lit edge
  focal: Color(0xFFEDF751),
  accentDim: Color(0xFFE2ED3C),
  focalFace: Color(0xFF96A814),
  focalLine: Color(0xFFC6D23E),
  black: Color(0xFFF8F9FB), // the solid object, inverted
  onAccent: Color(0xFF171C22),
  accentSoft: Color(0xFF262B12),
  green: Color(0xFF33C88D), // lifted: #15A06A is ~3.6:1 on a dark card
  greenSoft: Color(0xFF0E2A20),
  red: Color(0xFFFF6B5E),
  redSoft: Color(0xFF2E1A18),
  amber: Color(0xFFE0A63C),
  amberSoft: Color(0xFF2A2010),
  blueSoft: Color(0xFF121B29),
  cardFace: Color(0xFF2A323C), // a lit edge, not a shadow
  cardBorder: Color(0xFF232A32),
  scrim: Color(0xCC000000),
  snack: Color(0xFF1C222A),
  onSnack: Color(0xFFF8F9FB),
);
