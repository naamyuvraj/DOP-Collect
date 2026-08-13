import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/lot_repository.dart';
import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/screens/lists/list_builder_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('selecting accounts updates total and saves a lot',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final accounts = MemoryAccountRepository();
    final lots = MemoryLotRepository();
    await accounts.replaceAll([
      RdAccount(
        accountNumber: '020000000001',
        customerName: 'TEST ONE',
        denominationAmount: 2000,
        nextDueDate: DateTime(2026, 7, 30),
        monthsPaid: 10,
      ),
      RdAccount(
        accountNumber: '020000000002',
        customerName: 'TEST TWO',
        denominationAmount: 5000,
        nextDueDate: DateTime(2026, 7, 12),
        monthsPaid: 5,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: ListBuilderScreen(accounts: accounts, lots: lots),
    ));
    await tester.pumpAndSettle();

    // Add one installment to each account (order-independent: 2000 + 5000).
    final plus = find.byIcon(Icons.add);
    await tester.tap(plus.at(0));
    await tester.pump();
    await tester.tap(plus.at(1));
    await tester.pump();

    // Header Total should read ₹7,000.
    expect(find.textContaining('7,000'), findsWidgets);

    // Create the list — invoke the FAB callback directly (the list view
    // intercepts pointer hit-tests over the FAB in the test harness).
    // With 1 installment each and denominations 2000 + 5000, both fit the cap.
    final fab =
        tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    fab.onPressed!();
    await tester.pumpAndSettle();

    // Confirm the "Create this lot?" dialog.
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final saved = await lots.all();
    expect(saved.length, 1);
    expect(saved.first.count, 2);
    expect(saved.first.totalAmount, 7000);
    expect(saved.first.totalInstallments, 2);

    // The saved list itself is the "collected this cycle" record — no sticky
    // per-account flag is written (one that never reset used to make auto-build
    // skip these customers in every later month).
    final a2 = await accounts.byAccountNumber('020000000002');
    expect(a2!.status, CollectionStatus.pending);
    expect(
      LotPacking.listedThisCycle(saved, DateTime.now()),
      containsAll(<String>['020000000001', '020000000002']),
    );
  });
}
