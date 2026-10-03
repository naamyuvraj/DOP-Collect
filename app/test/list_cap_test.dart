import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/screens/lists/list_builder_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// The auto-packer and the manual builder must agree on how many accounts fit
/// in one list. If packing produced more than the builder accepts, the builder
/// would refuse the lists its own auto-fill had just made — which is a bug the
/// user only sees at the counter, and one no other test would catch.
void main() {
  test('the packer and the builder share one ceiling', () {
    expect(LotPacking.maxAccountsPerList, ListBuilderScreen.maxAccounts,
        reason: 'raise both together or neither');
  });

  test('the ceiling is 15, as observed on a real submitted report', () {
    // E-Banking ref C343193788, 26-Aug-2026: fifteen rows, every one Success,
    // totalling Rs 20,000. The previous nine was a guess about the portal
    // paginating at ten rows, which that report disproves.
    expect(ListBuilderScreen.maxAccounts, 15);
  });

  test('the rupee cap is unchanged and still binds cash lists', () {
    // 15 x Rs 100 is well under the cap; the report above hit it exactly.
    // Both constraints apply to a cash list, and neither replaces the other.
    expect(ListBuilderScreen.lotCap, 20000);
    expect(LotPacking.defaultCap, ListBuilderScreen.lotCap);
  });
}
