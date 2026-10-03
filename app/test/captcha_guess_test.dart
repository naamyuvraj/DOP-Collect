import 'package:flutter_test/flutter_test.dart';

/// Mirrors `_SyncScreenState._looksLikeCaptcha`. Kept here because the rule is
/// the only thing standing between a bad OCR read and a spent login attempt —
/// the portal locks the agent out after ten.
bool looksLikeCaptcha(String s) => RegExp(r'^[A-Za-z0-9]{4,8}$').hasMatch(s);

void main() {
  group('a read good enough to submit', () {
    for (final good in ['A1B2C', '384756', 'xY9mQ', 'ABCD', '12345678']) {
      test('"$good" is accepted', () => expect(looksLikeCaptcha(good), isTrue));
    }
  });

  group('a read that must NOT be auto-submitted', () {
    // Each of these is a real shape ML Kit returns off a noisy captcha. Before
    // the plausibility gate every one of them was typed in and submitted.
    for (final bad in [
      '',           // nothing recognised
      '5',          // one stray glyph
      'AB',         // a fragment
      'ABC',        // still too short to be a code
      '123456789',  // nine — longer than any DOP code
      'ABCDEFGHIJKLMN', // a smear read as text
    ]) {
      test('"$bad" is rejected', () => expect(looksLikeCaptcha(bad), isFalse));
    }
  });

  test('punctuation and spaces never survive to a submit', () {
    // CaptchaSolver strips these before we see them; if that ever regresses,
    // the gate is the second line of defence.
    for (final s in ['AB 12', 'A1-B2', 'a.b.c', 'A1\nB2']) {
      expect(looksLikeCaptcha(s), isFalse, reason: s);
    }
  });

  test('the boundaries are exactly 4 and 8', () {
    expect(looksLikeCaptcha('abc'), isFalse);
    expect(looksLikeCaptcha('abcd'), isTrue);
    expect(looksLikeCaptcha('abcdefgh'), isTrue);
    expect(looksLikeCaptcha('abcdefghi'), isFalse);
  });
}
