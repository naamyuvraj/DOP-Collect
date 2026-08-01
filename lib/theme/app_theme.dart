import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Soft-UI FinTech design system: a calm mint canvas, crisp white floating
/// cards with diffused shadows, one vibrant focal colour (lime-yellow) for the
/// hero number, stark-black CTAs, and a geometric sans (Plus Jakarta Sans) with
/// strong weight hierarchy. Green/red for money in/out.
class AppTheme {
  // Canvas (soft mint gradient)
  static const Color bg = Color(0xFFD2E2D2);
  static const Color bgTop = Color(0xFFDEEADB);
  static const Color bgBottom = Color(0xFFC4D8C6);

  // Surfaces
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSoft = Color(0xFFF3F6F1); // insets on white
  static const Color line = Color(0xFFEAEFE8);
  static const Color divider = Color(0xFFEEF2EC);

  // Ink — contrast-safe against white (WCAG AA). Old values (#6E7B72 / #A0ADA4)
  // failed body contrast; these clear ~7:1 and ~4.6:1 for Ramesh-ji in sunlight.
  static const Color ink = Color(0xFF141715); // near-black
  static const Color inkMuted = Color(0xFF4E5A53); // ~7:1
  static const Color inkFaint = Color(0xFF6B7770); // ~4.6:1

  // Focal + CTA
  static const Color focal = Color(0xFFE7EF5E); // vibrant lime-yellow hero
  static const Color black = Color(0xFF121412); // stark-black CTA / active
  static const Color accent = black; // links / active states are black now
  static const Color accentSoft = Color(0xFFEDF0E9);

  // Status
  static const Color green = Color(0xFF15A06A);
  static const Color greenSoft = Color(0xFFE3F3EA);
  static const Color red = Color(0xFFE1483D);
  static const Color redSoft = Color(0xFFFCE9E7);
  static const Color amber = Color(0xFFC98A16);
  static const Color amberSoft = Color(0xFFFBF0D6);
  static const Color blueSoft = Color(0xFFE7EFFA);

  // Back-compat aliases
  static const Color textPrimary = ink;
  static const Color textMuted = inkMuted;
  static const Color danger = red;
  static const Color success = green;

  static const cardRadius = 24.0;

  // ---- Typography (Plus Jakarta Sans, geometric sans) --------------------

  static TextStyle display(double size,
          {FontWeight weight = FontWeight.w700,
          Color color = ink,
          double spacing = -0.3,
          double? height}) =>
      GoogleFonts.plusJakartaSans(
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: spacing,
          height: height);

  static TextStyle body(double size,
          {FontWeight weight = FontWeight.w500,
          Color color = ink,
          double spacing = 0,
          double? height}) =>
      GoogleFonts.plusJakartaSans(
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: spacing,
          height: height);

  static TextStyle label(Color color) => GoogleFonts.plusJakartaSans(
      fontSize: 13, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.4);

  // ---- ThemeData ----------------------------------------------------------

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: black,
        secondary: black,
        surface: surface,
        brightness: Brightness.light,
      ),
      textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme)
          .apply(bodyColor: ink, displayColor: ink),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: display(19, weight: FontWeight.w700),
        iconTheme: const IconThemeData(color: ink),
      ),
      cardColor: surface,
      dividerColor: divider,
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: black,
        foregroundColor: Colors.white,
        elevation: 3,
      ),
      // Float snackbars with a bottom margin so they clear the floating nav pill
      // (screens with their own Scaffold anchored them under it before).
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        backgroundColor: ink,
        contentTextStyle: body(13.5, color: Colors.white),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  /// Crisp white floating card: big radius, soft diffused shadow, no border.
  static BoxDecoration card({Color? fill, double radius = cardRadius}) =>
      BoxDecoration(
        color: fill ?? surface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14101B12), blurRadius: 24, offset: Offset(0, 10)),
        ],
      );

  /// Soft tinted chip/panel (no shadow) for small status accents.
  static BoxDecoration panel(Color fill, {double radius = 14}) =>
      BoxDecoration(color: fill, borderRadius: BorderRadius.circular(radius));

  /// The mint canvas gradient (wrap page bodies for the airy backdrop).
  static const BoxDecoration canvas = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [bgTop, bgBottom],
    ),
  );
}
