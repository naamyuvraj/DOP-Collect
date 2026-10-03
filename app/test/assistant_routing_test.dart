import 'package:dop_collect/assistant/assistant_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the bug where "9 lakh MIS me kitna milega" was answered by summing
/// the agent's OWN accounts (₹10,00,000) instead of calculating the scheme.
void main() {
  bool calc(String q) => AssistantService.looksLikeCalculation(q);

  group('routed to the calculator', () {
    for (final q in [
      '2000 ki rd 10 saal',
      '9 lakh mis me kitna milega',
      '1 lakh NSC maturity',
      'sukanya 150000 per year kitna milega',
      '5000 monthly RD for 5 years',
      '2 lakh KVP kitne saal me double hoga',
      'scss 10 lakh interest',
    ]) {
      test('"$q"', () => expect(calc(q), isTrue));
    }
  });

  group('stay database questions', () {
    for (final q in [
      'aaj ke defaulters',
      'is mahine pending',
      'kitne total accounts',
      'total rd',
      'Ramesh ka account',
      'second half dues',
      'about to freeze',
      // Mentions RD + a number, but is clearly about his customers.
      'is mahine 2000 wale RD customers ki list',
    ]) {
      test('"$q"', () => expect(calc(q), isFalse));
    }
  });

  group('not a calculation without all three cues', () {
    test('no number', () => expect(calc('rd maturity kitna'), isFalse));
    test('no scheme', () => expect(calc('5000 ka maturity kitna'), isFalse));
    test('no calc cue', () => expect(calc('rd 2000'), isFalse));
  });
}
