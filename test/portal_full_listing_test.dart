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
}
