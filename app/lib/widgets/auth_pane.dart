import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Frames the sign-in flows as a card on a desktop, and changes nothing on a
/// phone.
///
/// These screens are the worst offenders when a handset layout is handed a
/// desktop window, because every one of them is a single short form:
///
///   * a phone-number field stretched across 1,440 px, with the label at the
///     far left and the caret a hand's width away from it;
///   * a primary button pinned to the BOTTOM of the viewport — correct on a
///     handset, where the thumb lives there and the keyboard pushes up against
///     it, and absurd on a laptop, where it leaves half a metre of black
///     between the field being filled and the button that submits it;
///   * a tab bar spanning the whole window for two words.
///
/// A capped, centred card fixes all three at once, and it is the shape every
/// sign-in page on the web already uses — which matters here more than it
/// usually would, since this is the first screen a desktop user ever sees and
/// the only evidence they have that the app was built for the machine.
///
/// [maxHeight] bounds the card so a `ListView` inside it scrolls within the
/// card rather than demanding infinite height, and so a `Spacer` in the child
/// pushes to the foot of the CARD instead of the foot of the monitor.
class AuthPane extends StatelessWidget {
  const AuthPane({super.key, required this.child, this.maxHeight = 560});

  final Widget child;
  final double maxHeight;

  /// Comfortable for a phone number, an OTP, or a short form. Wider reads as a
  /// stretched page; narrower starts wrapping the helper text.
  static const double width = 420;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    if (size.width < kDesktopBreakpoint) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          // Never taller than the window, or a short laptop screen clips the
          // card instead of scrolling it.
          maxHeight: maxHeight > size.height - 48 ? size.height - 48 : maxHeight,
        ),
        child: DecoratedBox(
          decoration: AppTheme.card(radius: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: child,
          ),
        ),
      ),
    );
  }
}
