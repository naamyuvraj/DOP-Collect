import 'dart:io';

import 'package:dop_collect/data/portal/agent_list_parser.dart';
import 'package:dop_collect/data/portal/portal_dom.dart';
import 'package:flutter_test/flutter_test.dart';

/// The portal's print-preview of the listing returns the WHOLE book in one
/// document. `PortalSyncEngine` uses it to replace a 48-page walk with a single
/// request, so the parse has to be exactly as good as the walk's — a shortcut
/// that quietly drops accounts would be far worse than a slow sync, because a
/// COMPLETE sync closes every account it did not see.
///
/// The fixture lives in `recon/live/`, which is git-ignored because it holds a
/// real Agent ID and real customers. The test skips when it is absent, the same
/// convention the rest of the recon-backed tests use.
void main() {
  final fixture = File('recon/live/data.html');

  test('the full listing parses every account, with every field', () {
    if (!fixture.existsSync()) {
      markTestSkipped('recon/live/data.html not present — see its README');
      return;
    }
    final html = fixture.readAsStringSync();

    // It must be recognised as the full listing and NOT as the paginated one:
    // the walk's page-position guard keys off "Page X of N", which this page
    // does not have.
    expect(PortalDom.classify(html), PortalScreen.fullList);
    expect(PortalDom.pageOfRe.hasMatch(html), isFalse);

    final parsed = AgentListParser.parse(html);

    // Every row the portal rendered is accounted for — as an account, as a
    // maturity, or as an explicit reject. Nothing may vanish.
    final ids = RegExp(r'ACCOUNT_NUMBER_ALL_ARRAY\[(\d+)\]')
        .allMatches(html)
        .map((m) => m.group(1))
        .toSet();
    expect(parsed.rows, ids.length,
        reason: 'every rendered row must be classified, not dropped');

    expect(parsed.accounts, isNotEmpty);
    expect(parsed.rejected, 0, reason: 'this markup parses cleanly');
    // Blank "Next RD Installment Due Date" means the account reached term. It
    // is data, not corruption, and must be counted apart from a parse failure.
    expect(parsed.matured, greaterThan(0));

    for (final a in parsed.accounts) {
      expect(a.accountNumber.length, greaterThanOrEqualTo(9));
      expect(a.customerName, isNotEmpty);
      expect(a.denominationAmount, greaterThan(0));
      expect(a.monthsPaid, greaterThan(0));
    }
    expect(parsed.accounts.map((a) => a.accountNumber).toSet().length,
        parsed.accounts.length,
        reason: 'no account may appear twice');
  });

  test('every account carries its true row position in the book', () {
    if (!fixture.existsSync()) {
      markTestSkipped('recon/live/data.html not present — see its README');
      return;
    }
    final parsed = AgentListParser.parse(fixture.readAsStringSync());

    // The order the portal rendered, straight off its own row ids — the same
    // order the paginated listing pages through.
    final rendered = RegExp(
            r'ACCOUNT_NUMBER_ALL_ARRAY\[(\d+)\][^>]*>\s*([0-9]{6,})')
        .allMatches(fixture.readAsStringSync())
        .map((m) => m.group(2)!)
        .toList();

    for (final a in parsed.accounts) {
      expect(a.serial, rendered.indexOf(a.accountNumber) + 1,
          reason: 'short code ${a.serial} must be the portal row, so that '
              '(serial - 1) ~/ 10 + 1 is the page holding it');
    }

    // This book has maturities, so the positions are NOT 1..N with no gaps —
    // and that is the fix. Numbering only the kept rows is what put every
    // account after them on the wrong page.
    expect(parsed.matured, greaterThan(0));
    expect(parsed.accounts.last.serial,
        parsed.accounts.length + parsed.matured + parsed.rejected);
  });

  test('the book is in plain string order — what the probe searches by', () {
    if (!fixture.existsSync()) {
      markTestSkipped('recon/live/data.html not present — see its README');
      return;
    }
    final rendered = RegExp(
            r'ACCOUNT_NUMBER_ALL_ARRAY\[(\d+)\][^>]*>\s*([0-9]{6,})')
        .allMatches(fixture.readAsStringSync())
        .map((m) => m.group(2)!)
        .toList();

    // `prepareList` halves the listing when the index misses, which is only
    // sound while the portal renders it in ascending account-number order.
    // The engine checks that on every page it reads and stands down if it is
    // ever false — this pins that the real book normally satisfies it, so the
    // probe is not quietly switched off for good.
    for (var i = 1; i < rendered.length; i++) {
      expect(rendered[i - 1].compareTo(rendered[i]), lessThan(0),
          reason: 'row $i broke the order the probe searches by');
    }

    // And that the order really is TEXT order, not numeric or width-first: the
    // book ends with ten-digit accounts sorted after the twelve-digit ones.
    expect(rendered.map((a) => a.length).toSet().length, greaterThan(1),
        reason: 'this book mixes account-number widths — the case that broke '
            'a length-aware comparison');
  });
}
