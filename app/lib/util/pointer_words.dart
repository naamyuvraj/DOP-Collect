import '../theme/app_theme.dart';

/// Rewrites touch verbs for a device that is pointed at rather than touched.
///
/// WHY A REWRITER AND NOT 49 TERNARIES
/// -----------------------------------
/// "Tap" appears in about fifty user-facing strings. Branching at each one
/// would put a `MediaQuery` lookup and two copies of the sentence at every
/// site, and the day someone edits one copy and not the other the desktop and
/// the phone start giving different instructions. One function, applied where
/// the string is rendered, keeps a single sentence in the source.
///
/// WHAT IT DELIBERATELY DOES NOT DO
/// --------------------------------
/// **Swipe.** There is no pointer equivalent, so it is not a word swap — the
/// instruction has to be re-written for the gesture the device actually has
/// ("tick a customer off" rather than "swipe a customer right"). Those are
/// handled at their call sites, on purpose: a blind substitution would produce
/// "click a customer to the right", which is worse than leaving it wrong,
/// because it reads as though it should work.
///
/// Word boundaries matter. "Tapped", "tape" and "untap" must survive intact,
/// so the match requires the verb to be followed by a space or a quote.
String pointerWords(String s) {
  if (!AppTheme.pointerDevice) return s;
  return s.replaceAllMapped(
    RegExp(r'\b([Tt])ap(s|ped|ping)?\b'),
    (m) {
      final head = m.group(1) == 'T' ? 'Click' : 'click';
      // NOT a straight concatenation. "tap" doubles its consonant before a
      // suffix and "click" does not, so `tap + ped` has to become `click + ed`
      // — appending the matched suffix verbatim yields "clickped".
      final tail = switch (m.group(2)) {
        's' => 's',
        'ped' => 'ed',
        'ping' => 'ing',
        _ => '',
      };
      return '$head$tail';
    },
  );
}
