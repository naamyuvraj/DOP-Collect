import 'package:dop_collect/theme/app_theme.dart';
import 'package:dop_collect/util/pointer_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => AppTheme.pointerDevice = false);

  test('a touch device is left exactly as written', () {
    AppTheme.pointerDevice = false;
    expect(pointerWords('Tap "New" to make this month\'s lists'),
        'Tap "New" to make this month\'s lists');
  });

  test('tap becomes click, in both cases and all its forms', () {
    AppTheme.pointerDevice = true;
    expect(pointerWords('Tap "New" to start'), 'Click "New" to start');
    expect(pointerWords('then tap Login'), 'then click Login');
    expect(pointerWords('tap the eye to show'), 'click the eye to show');
    expect(pointerWords('Tap any "View" to open'), 'Click any "View" to open');
    expect(pointerWords('taps'), 'clicks');
    expect(pointerWords('tapped'), 'clicked');
  });

  test('words that merely CONTAIN tap are untouched', () {
    // The reason the match is anchored on word boundaries: a blind
    // replace turns "untapped" into "unclicked" and "tape" into "clicke".
    AppTheme.pointerDevice = true;
    for (final w in ['untapped', 'tape', 'adaptation', 'Tapas', 'bootstrap']) {
      expect(pointerWords(w), w, reason: w);
    }
  });

  test('swipe is deliberately NOT rewritten', () {
    // There is no pointer equivalent. "Click a customer to the right" reads as
    // though it should work, which is worse than leaving it visibly wrong —
    // these are re-written per site instead.
    AppTheme.pointerDevice = true;
    expect(pointerWords('Swipe a customer right'), 'Swipe a customer right');
  });
}
