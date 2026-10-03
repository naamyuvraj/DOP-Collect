import 'package:dop_collect/data/portal/saved_installments_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps account -> most recent deposit date', () {
    const html = '''
      <table>
        <tr><th>Sr</th><th>Account</th><th>Name</th><th>Amount</th><th>Date</th></tr>
        <tr><td>1</td><td>020002767521</td><td>PRADIP KUMAR SAH</td>
            <td>2,000.00</td><td>05-06-2026</td></tr>
        <tr><td>2</td><td>020002767521</td><td>PRADIP KUMAR SAH</td>
            <td>2,000.00</td><td>08-07-2026</td></tr>
        <tr><td>3</td><td>020002775442</td><td>SANTOSH SARRAF</td>
            <td>10,000.00</td><td>02-07-2026</td></tr>
      </table>
    ''';
    final map = SavedInstallmentsParser.parse(html);
    expect(map.length, 2);
    // Latest of the two rows wins.
    expect(map['020002767521'], DateTime(2026, 7, 8));
    expect(map['020002775442'], DateTime(2026, 7, 2));
  });

  test('handles dd-MMM-yyyy and does not mistake a date for an account', () {
    const html = '''
      <table><tr><td>020009716144</td><td>09-Aug-2026</td></tr></table>
    ''';
    final map = SavedInstallmentsParser.parse(html);
    expect(map['020009716144'], DateTime(2026, 8, 9));
    // "09-Aug-2026" must not have been read as the account number.
    expect(map.keys.single, '020009716144');
  });

  test('ignores rows without both an account and a date', () {
    const html = '''
      <table>
        <tr><td>Total</td><td>5,000.00</td></tr>
        <tr><td>020002767521</td><td>no date here</td></tr>
        <tr><td>short 123</td><td>05-06-2026</td></tr>
      </table>
    ''';
    expect(SavedInstallmentsParser.parse(html), isEmpty);
  });

  test('returns empty for an unrelated page rather than guessing', () {
    expect(SavedInstallmentsParser.parse('<html><p>hello</p></html>'), isEmpty);
    expect(SavedInstallmentsParser.parse(''), isEmpty);
  });
}
