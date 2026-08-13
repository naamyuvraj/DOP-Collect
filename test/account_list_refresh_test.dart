import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/screens/account_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RdAccount acc(String number) => RdAccount(
      accountNumber: number,
      customerName: 'Customer $number',
      denominationAmount: 5000,
      nextDueDate: DateTime(2026, 8, 10),
      monthsPaid: 12,
    );

/// The Accounts tab lives in the shell's IndexedStack, so it is built once and
/// kept alive — its query only re-runs when `revision` changes. Without that a
/// Sync started from Home (or a list / detail page) left the tab showing the
/// "No accounts yet" empty state until the app was cold-started.
void main() {
  testWidgets('re-reads the store when revision changes', (tester) async {
    final repo = MemoryAccountRepository();
    var revision = 0;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: Column(children: [
            TextButton(
              onPressed: () => setState(() => revision++),
              child: const Text('bump'),
            ),
            Expanded(
              child: AccountListScreen(repo: repo, revision: revision),
            ),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Opened on an empty store, exactly like a first run before any Sync.
    expect(find.textContaining('No accounts yet'), findsOneWidget);

    // A Sync elsewhere fills the store — the live screen knows nothing about it.
    await repo.replaceAll([acc('0200000000001'), acc('0200000000002')]);
    await tester.pumpAndSettle();
    expect(find.textContaining('No accounts yet'), findsOneWidget);

    // Entering the tab (or finishing a Sync) bumps the revision -> re-query.
    await tester.tap(find.text('bump'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No accounts yet'), findsNothing);
    expect(find.text('Customer 0200000000001'), findsOneWidget);
    expect(find.text('Customer 0200000000002'), findsOneWidget);
  });
}
