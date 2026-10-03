import 'package:dop_collect/data/portal/aslaas_report_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ASLAAS report is 692 rows over 70 pages, and the app walked all seventy.
/// It carries the same `#HREF_printPreview` link the account listing does, so
/// the whole thing comes back in one request — the same shortcut that replaced
/// the 48-page account walk.
///
/// Taking a shortcut on this data is only safe if a SHORT read is detectable.
/// It is not detectable from the map: the portal prints "APPLIED" for an
/// account whose number the post office has not issued yet, and those rows
/// yield nothing. A book with a hundred APPLIED rows returns 592 numbers on a
/// perfect read — so a check on map size would either reject good previews or,
/// tuned the other way, accept a truncated one and leave accounts holding a
/// stale ASLAAS that gets printed on a list at the counter.
///
/// Hence [AslaasReport.rows]: every account row seen, whatever its cell said.
String _report(List<(String, String)> rows) => '''
<html><body>
<table>
  <tr><th>RD Account Number</th><th>ASLAAS Number</th></tr>
  ${rows.map((r) => '<tr><td>${r.$1}</td><td>${r.$2}</td></tr>').join()}
</table>
</body></html>
''';

void main() {
  test('rows are counted even when they carry no number', () {
    final read = AslaasReportParser.read(_report([
      ('020002767521', '801357'),
      ('020002773691', 'APPLIED'),
      ('020002775442', ''),
      ('020002777833', '044363'),
    ]));

    expect(read.numbers, {
      '020002767521': '801357',
      '020002777833': '044363',
    });
    // Two numbers, but FOUR rows — this is the number the read is checked by.
    expect(read.rows, 4);
    expect(read.applied, 2);
  });

  test('a truncated preview is distinguishable from a complete one', () {
    // What the fast path compares against "Displaying 1 - 10 of 692 results".
    const advertised = 692;
    final full = AslaasReportParser.read(_report([
      for (var i = 0; i < advertised; i++)
        ('0200027675${i.toString().padLeft(2, '0')}',
            i.isEven ? 'APPLIED' : '8013${i.toString().padLeft(2, '0')}'),
    ]));
    expect(full.rows, advertised);
    expect(full.rows >= advertised, isTrue, reason: 'accepted');
    // Half the rows carry no number, so the map alone would look like a read
    // that lost 346 accounts.
    expect(full.numbers.length, lessThan(advertised ~/ 2 + 1));

    final short = AslaasReportParser.read(_report([
      for (var i = 0; i < 10; i++) ('02000276750$i', '80135$i'),
    ]));
    expect(short.rows < advertised, isTrue, reason: 'rejected');
  });

  test('APPLIED never overwrites a number the app already holds', () {
    // The map is what gets merged into the book. A row with no usable number
    // must be absent from it, not present-and-empty — an empty string would
    // wipe a good ASLAAS on merge.
    final read = AslaasReportParser.read(_report([
      ('020002767521', 'APPLIED'),
    ]));
    expect(read.numbers.containsKey('020002767521'), isFalse);
  });

  test('the old map-only entry point still answers the same', () {
    final html = _report([('020002767521', '801357')]);
    expect(AslaasReportParser.parse(html), AslaasReportParser.read(html).numbers);
  });
}
