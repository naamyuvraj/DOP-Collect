import 'package:dop_collect/widgets/summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A figure the agent cannot read is worse than a small one.
///
/// The card showed "₹22,48,7…" on a real phone — the value was `maxLines: 1`
/// with `overflow: ellipsis` at 26px, in a cell given an EQUAL share of the
/// card with a three-digit account count. ₹22,48,700 and ₹22,48,799 render
/// identically that way, and this app is used to collect money door to door.
Future<void> _pump(WidgetTester tester, String amount, double width) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SummaryCard(
            title: 'Deposited',
            statusColor: const Color(0xFF34D399),
            count: '305',
            amount: amount,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Was this text actually ellipsized on screen?
///
/// NOT `find.text(...)`, and not searching for '…'. A `Text` keeps its full
/// string in `data` however it is painted, so both of those pass happily
/// against a figure the agent cannot read — the first version of this file
/// made exactly that mistake and proved nothing. `didExceedMaxLines` is the
/// renderer's own answer to the question.
bool _wasClipped(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

void main() {
  testWidgets('a seven-figure amount keeps every digit', (tester) async {
    // 360dp is the narrow end of the fleet; the card sits inside page padding.
    await _pump(tester, '₹22,48,700', 328);
    expect(find.text('₹22,48,700'), findsOneWidget);
    expect(_wasClipped(tester, '₹22,48,700'), isFalse,
        reason: 'money must scale down, never ellipsize');
  });

  testWidgets('an eight-figure amount still keeps every digit', (tester) async {
    await _pump(tester, '₹1,22,48,700', 328);
    expect(find.text('₹1,22,48,700'), findsOneWidget);
    expect(_wasClipped(tester, '₹1,22,48,700'), isFalse);
  });

  testWidgets('the account count is never clipped either', (tester) async {
    await _pump(tester, '₹1,22,48,700', 328);
    expect(_wasClipped(tester, '305'), isFalse);
  });

  testWidgets('the figure is scaled, not clipped', (tester) async {
    await _pump(tester, '₹1,22,48,700', 328);
    // A FittedBox between the cell column and the value is what does it.
    expect(
      find.ancestor(
        of: find.text('₹1,22,48,700'),
        matching: find.byType(FittedBox),
      ),
      findsWidgets,
    );
  });

  testWidgets('a short amount is not blown up to fill the cell',
      (tester) async {
    // BoxFit.scaleDown only ever shrinks — ₹0 must stay at its design size,
    // not stretch across 60% of the card.
    await _pump(tester, '₹0', 328);
    final box = tester.getSize(find.text('₹0'));
    expect(box.width, lessThan(120),
        reason: 'scaleDown must not enlarge a short figure');
  });

  testWidgets('the amount gets more room than the count', (tester) async {
    await _pump(tester, '₹22,48,700', 328);
    final amount = tester.getSize(find.text('₹22,48,700')).width;
    final count = tester.getSize(find.text('305')).width;
    expect(amount, greaterThan(count));
  });
}
