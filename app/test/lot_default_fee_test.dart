import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_installment_portal.dart';

/// The default fee, on the document he hands across the counter.
///
/// The fee exists in exactly one place: the figure the portal states after
/// `Action.CALCULATE_REBATE` ("Get Rebate & Default Fee") is clicked on a row.
/// The app used to click it only for rows that differ from the portal's default
/// of one cash installment — advance deposits and cheques. Every ordinary row
/// was skipped, so:
///
///   * its `defaultFee` stayed null and the report printed a blank, and
///   * `LotItem.netAmount` reads a null fee as zero, so the row's total AND the
///     list total came out short of what the post office charged.
///
/// A list with one advance payer showed a fee on that one row and on no other,
/// which is how it was noticed. These tests pin that every row is asked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeInstallmentPortal portal;
  late PortalSyncEngine engine;

  void boot(List<FakeRow> rows) {
    portal = FakeInstallmentPortal(rows);
    WebViewPlatform.instance = FakeInstallmentPlatform(portal);
    engine = PortalSyncEngine(WebViewController());
    portal.onNavigated = () => engine.notifyPageFinished();
  }

  const fast = Duration(seconds: 2);

  test('a late customer paying one installment still gets his fee read',
      () async {
    boot([
      FakeRow(account: '020000000001', name: 'A', defaultFee: 60),
      FakeRow(account: '020000000002', name: 'B'),
      // The advance payer — the only row the old code would have keyed.
      FakeRow(account: '020000000003', name: 'C', rebate: 400),
    ]);

    final fill = await engine.enterInstallments(
      installmentsByAccount: const {
        '020000000001': 1,
        '020000000002': 1,
        '020000000003': 2,
      },
      timeout: fast,
    );

    expect(fill.ok, isTrue);
    expect(fill.total, 3, reason: 'every row is keyed, not just the advance');
    expect(fill.saved, 3);

    // The whole point: the single-installment defaulter's fee is there.
    expect(fill.rebates['020000000001']?.defaultFee, 60);
    // And a paid-up row answers a real zero, which is different from a blank.
    expect(fill.rebates['020000000002']?.defaultFee, 0);
    expect(fill.rebates['020000000002']?.defaultFee, isNotNull);
    expect(fill.rebates['020000000003']?.rebate, 400);

    // Asked once per account, and the advance row keyed with its 2.
    expect(portal.calculated.toSet(), fill.rebates.keys.toSet());
    expect(portal.keyed['020000000003'], 2);
    expect(portal.keyed['020000000001'], 1);
  });

  test('every row reaches Modified=YES, so nothing rides on a default',
      () async {
    boot([
      for (var i = 1; i <= 5; i++)
        FakeRow(account: '02000000000$i', name: 'N$i', defaultFee: i * 10),
    ]);

    final fill = await engine.enterInstallments(
      installmentsByAccount: {
        for (var i = 1; i <= 5; i++) '02000000000$i': 1,
      },
      timeout: fast,
    );

    expect(fill.ok, isTrue);
    expect(portal.rows.every((r) => r.modified), isTrue);
    expect([for (var i = 1; i <= 5; i++) fill.rebates['02000000000$i']!.defaultFee],
        [10, 20, 30, 40, 50]);
  });

  test('a grid that re-renders on add cannot cross-assign a fee', () async {
    // The selected-row fields answer, so the grid is only a fallback — but when
    // it is used, the row index it was found at is stale by then.
    boot([
      FakeRow(account: '020000000001', name: 'A', defaultFee: 15),
      FakeRow(account: '020000000002', name: 'B', defaultFee: 900),
    ]..first.modified = false);
    portal.reorderOnAdd = true;

    final fill = await engine.enterInstallments(
      installmentsByAccount: const {
        '020000000001': 1,
        '020000000002': 1,
      },
      timeout: fast,
    );

    expect(fill.rebates['020000000001']?.defaultFee, 15);
    expect(fill.rebates['020000000002']?.defaultFee, 900);
  });

  test('an unkeyed row reads 0.00 in the grid — so the grid is never trusted',
      () async {
    // Faithful to recon/portal_02_installment_entry.html: every row there is
    // MODIFIED=NO and shows 0.00 in both money columns, whatever is owed. If a
    // future change reads the grid instead of calculating, this is the fixture
    // that will let it look correct — hence the assertion here rather than a
    // comment somewhere.
    final p = FakeInstallmentPortal([
      FakeRow(account: '020000000001', name: 'A', defaultFee: 60),
    ]);
    expect(p.respond('RD_DEFAUT_FEE_ARRAY[0]'), '"0.00"');
    p.rows[0].modified = true;
    expect(p.respond('RD_DEFAUT_FEE_ARRAY[0]'), '"60.00"');
  });
}
