import 'package:dop_collect/data/portal/agent_list_parser.dart';
import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixture modelled on the real "Agent Inquire and Update" page (columns and
/// value formats confirmed from a live capture): a Select checkbox column,
/// Finacle money like "2,000.00 Cr.", and dd-MM-yyyy dates. Values here are
/// synthetic — no session tokens — so it is safe to commit.
const _sampleHtml = '''
<html><body>
  <table><tr><td>Finacle menu / chrome table</td></tr></table>
  <div class="pageheadingcaps">Page 1 of 47</div>
  <table id="listTable" border="1">
    <tr>
      <th>Select</th><th>Account No</th><th>Account Name</th>
      <th>Denomination</th><th>Month Paid Upto</th>
      <th>Next RD Installment Due Date</th>
    </tr>
    <tr>
      <td><input type="checkbox"></td><td>020002767521</td>
      <td>PRADIP KUMAR SAH</td><td>2,000.00 Cr.</td><td>67</td>
      <td>30-08-2026</td>
    </tr>
    <tr>
      <td><input type="checkbox"></td><td>020002775442</td>
      <td>SANTOSH SARRAF</td><td>10,000.00 Cr.</td><td>66</td>
      <td>05-07-2026</td>
    </tr>
    <tr>
      <td></td><td>&nbsp;</td><td></td><td></td><td></td><td></td>
    </tr>
  </table>
</body></html>
''';

void main() {
  test('parses real-shape rows, handles Cr. money + dd-MM-yyyy', () {
    final rows = AgentListParser.parsePage(_sampleHtml);
    expect(rows.length, 2);

    final a = rows.firstWhere((r) => r.accountNumber == '020002767521');
    expect(a.customerName, 'PRADIP KUMAR SAH');
    expect(a.denominationAmount, 2000); // not 200000 — decimals dropped
    expect(a.monthsPaid, 67);
    expect(a.nextDueDate, DateTime(2026, 8, 30));
    expect(a.fortnight, Fortnight.second); // day 30 -> second fortnight
    expect(a.depositedAmount, 2000 * 67);

    final b = rows.firstWhere((r) => r.accountNumber == '020002775442');
    expect(b.denominationAmount, 10000);
    expect(b.fortnight, Fortnight.first); // day 5 -> first fortnight
  });

  test('reads total page count from the "Page X of N" label', () {
    expect(PortalSyncEngine.totalPages(_sampleHtml), 47);
    expect(PortalSyncEngine.totalPages('<html>no label</html>'), 1);
  });

  test('returns empty when no account table present', () {
    final rows =
        AgentListParser.parsePage('<html><body><p>hi</p></body></html>');
    expect(rows, isEmpty);
  });

  test('parses tables where row 0 is a title/banner row', () {
    const bannerHtml = '''
    <html><body>
      <table id="listTable">
        <tr><td colspan="6">Agent RD Accounts Summary List - Live</td></tr>
        <tr>
          <th>Select</th><th>Account</th><th>Account Name</th>
          <th>Denomination</th><th>Month Paid Upto</th>
          <th>Next RD Installment Due Date</th>
        </tr>
        <tr>
          <td><input type="checkbox"></td><td>020002767521</td>
          <td>PRADIP KUMAR SAH</td><td>2,000.00 Cr.</td><td>67</td>
          <td>30-08-2026</td>
        </tr>
      </table>
    </body></html>
    ''';
    final rows = AgentListParser.parsePage(bannerHtml);
    expect(rows.length, 1);
    expect(rows.first.accountNumber, '020002767521');
    expect(rows.first.customerName, 'PRADIP KUMAR SAH');
  });

  test('matches standalone "Account" column header without misidentifying "Account Name"', () {
    const aliasHtml = '''
    <html><body>
      <table>
        <tr>
          <th>Account Name</th><th>Account</th><th>Denomination</th>
          <th>Paid</th><th>Due</th>
        </tr>
        <tr>
          <td>SANTOSH SARRAF</td><td>020002775442</td><td>5,000.00</td>
          <td>12</td><td>15-09-2026</td>
        </tr>
      </table>
    </body></html>
    ''';
    final rows = AgentListParser.parsePage(aliasHtml);
    expect(rows.length, 1);
    expect(rows.first.accountNumber, '020002775442');
    expect(rows.first.customerName, 'SANTOSH SARRAF');
    expect(rows.first.denominationAmount, 5000);
  });
}
