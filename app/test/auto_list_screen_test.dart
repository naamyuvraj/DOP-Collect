import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/collection_repository.dart';
import 'package:dop_collect/data/lot_repository.dart';
import 'package:dop_collect/models/collection.dart';
import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/screens/lists/auto_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// The auto path end to end: who gets offered, what they are priced at, and
/// that nothing reaches the database until the proposal is accepted.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  RdAccount acct(String n, int denom, {DateTime? due, bool closed = false}) =>
      RdAccount(
        accountNumber: n,
        customerName: 'CUST $n',
        denominationAmount: denom,
        nextDueDate: due ?? DateTime.now(),
        monthsPaid: 10,
        closedAt: closed ? DateTime(2026, 1, 1) : null,
      );

  Future<void> mount(
    WidgetTester tester, {
    required AccountRepository accounts,
    required LotRepository lots,
    required CollectionRepository collections,
  }) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AutoListScreen(
          accounts: accounts, lots: lots, collections: collections),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the pool arrives pre-selected — the "auto-select" half',
      (tester) async {
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll(
        [for (var i = 0; i < 4; i++) acct('0200000000$i', 1000)]);
    await mount(tester,
        accounts: accounts,
        lots: MemoryLotRepository(),
        collections: MemoryCollectionRepository());

    // All four are picked without the agent touching anything.
    expect(find.textContaining('Group 4 into lists'), findsOneWidget);
  });

  testWidgets('accounts already on this cycle\'s list are not offered again',
      (tester) async {
    // The one mistake an automatic path can make at scale: re-listing cash that
    // is already sitting on an unsubmitted list.
    final accounts = MemoryAccountRepository();
    await accounts
        .replaceAll([acct('020000000001', 1000), acct('020000000002', 1000)]);
    final lots = MemoryLotRepository();
    await lots.save(Lot(
      createdAt: DateTime.now(),
      mode: 'Cash',
      items: const [
        LotItem(
            accountNumber: '020000000001',
            customerName: 'CUST 020000000001',
            denomination: 1000,
            installments: 1),
      ],
    ));

    await mount(tester,
        accounts: accounts,
        lots: lots,
        collections: MemoryCollectionRepository());

    expect(find.textContaining('Group 1 into lists'), findsOneWidget);
    expect(find.text('1 already listed'), findsOneWidget);
    expect(find.textContaining('CUST 020000000001'), findsNothing);
  });

  testWidgets('a closed account is never offered', (tester) async {
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll([
      acct('020000000001', 1000),
      acct('020000000002', 1000, closed: true),
    ]);
    await mount(tester,
        accounts: accounts,
        lots: MemoryLotRepository(),
        collections: MemoryCollectionRepository());

    expect(find.textContaining('Group 1 into lists'), findsOneWidget);
  });

  testWidgets('the ledger prices the row, and the row says so', (tester) async {
    // The correction that makes the auto path trustworthy: this customer handed
    // over three months at the door, and the list must say three.
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll([acct('020000000001', 1000)]);
    final collections = MemoryCollectionRepository();
    await collections.add(Collection(
      accountNumber: '020000000001',
      amount: 3000,
      collectedAt: DateTime.now(),
      cycleYm: Collection.cycleOf(DateTime.now()),
      installments: 3,
    ));

    await mount(tester,
        accounts: accounts, lots: MemoryLotRepository(), collections: collections);

    expect(find.text('Collected 3 months'), findsOneWidget);
    expect(find.textContaining('3,000'), findsWidgets);
  });

  testWidgets('a part-paid customer is shown but left out of the selection',
      (tester) async {
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll([acct('020000000001', 1000)]);
    final collections = MemoryCollectionRepository();
    await collections.add(Collection(
      accountNumber: '020000000001',
      amount: 600, // not a whole month
      collectedAt: DateTime.now(),
      cycleYm: Collection.cycleOf(DateTime.now()),
      installments: 0,
    ));

    await mount(tester,
        accounts: accounts, lots: MemoryLotRepository(), collections: collections);

    // Visible — he can still add the customer if he knows better — but not
    // silently listed for a month that is still in the customer's pocket.
    expect(find.text('Part-paid — no full month collected yet'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('grouping proposes lists but saves nothing until accepted',
      (tester) async {
    // 30 accounts x ₹1,000: the 15-account ceiling binds before the cash one,
    // so this is two full lists.
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll([
      for (var i = 0; i < 30; i++)
        acct('02000000${i.toString().padLeft(4, '0')}', 1000)
    ]);
    final lots = MemoryLotRepository();
    await mount(tester,
        accounts: accounts,
        lots: lots,
        collections: MemoryCollectionRepository());

    tester
        .widget<FloatingActionButton>(find.byType(FloatingActionButton))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('Review lists'), findsOneWidget);
    expect(find.text('List 1'), findsOneWidget);
    expect(find.text('List 2'), findsOneWidget);
    expect(find.textContaining('2 lists · 30 accounts'), findsOneWidget);

    // Still nothing in the database — the proposal is not a filing.
    expect(await lots.all(), isEmpty);
  });

  testWidgets('accepting the proposal writes one lot per list', (tester) async {
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll([
      for (var i = 0; i < 20; i++)
        acct('02000000${i.toString().padLeft(4, '0')}', 1000)
    ]);
    final lots = MemoryLotRepository();
    await mount(tester,
        accounts: accounts,
        lots: lots,
        collections: MemoryCollectionRepository());

    tester
        .widget<FloatingActionButton>(find.byType(FloatingActionButton))
        .onPressed!();
    await tester.pumpAndSettle();

    tester
        .widget<FloatingActionButton>(find.byType(FloatingActionButton))
        .onPressed!();
    await tester.pumpAndSettle();

    // Fixtures carry no ASLAAS, so the shared prompt appears here too. Skipping
    // it must not stop the lists being written.
    expect(find.text('Fetch ASLAAS numbers?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final saved = await lots.all();
    expect(saved.length, 2, reason: '20 accounts at 15 a list is two lists');
    expect(saved.fold<int>(0, (s, l) => s + l.count), 20);
    expect(saved.fold<int>(0, (s, l) => s + l.totalAmount), 20000);
    for (final l in saved) {
      expect(l.count, lessThanOrEqualTo(LotPacking.maxAccountsPerList));
      expect(l.totalAmount, lessThanOrEqualTo(LotPacking.defaultCap));
      expect(l.mode, 'Cash');
    }
    // Every account is spoken for exactly once across the batch.
    expect(LotPacking.listedThisCycle(saved, DateTime.now()).length, 20);
  });

  testWidgets('backing out of the proposal saves nothing', (tester) async {
    final accounts = MemoryAccountRepository();
    await accounts.replaceAll(
        [for (var i = 0; i < 5; i++) acct('0200000000$i', 1000)]);
    final lots = MemoryLotRepository();
    await mount(tester,
        accounts: accounts,
        lots: lots,
        collections: MemoryCollectionRepository());

    tester
        .widget<FloatingActionButton>(find.byType(FloatingActionButton))
        .onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Review lists'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(await lots.all(), isEmpty);
    // And he lands back on the pool with his selection intact.
    expect(find.textContaining('Group 5 into lists'), findsOneWidget);
  });
}
